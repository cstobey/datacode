# Schema Model

## Design Philosophy

DataCode schemas are closer to TutorialD than SQL. The core shift:
- A **table** is a named collection of typed tuples (no row ordering, no implicit keys unless declared)
- A **field** has a precise type with associated validation functors
- A **query/view** is indistinguishable from a table definition — both are views over the transaction graph
- There is **no NULL** — absent values are expressed as typed ADTs
- Tables are organized in a **namespace tree** (see namespaces.md) — namespaces replace the SQL "database" concept

## Namespace Organization

Every table belongs to a namespace. Namespaces are dot-separated hierarchical paths:
- `app.commerce.orders` — user-defined application schema
- `connectors.mariadb.production.orders` — auto-generated connector shadow schema
- `system.auth.users` — DataCode self-management tables

Full namespace documentation: see `namespaces.md`.

## Schema Visibility Layers

DataCode maintains multiple layers of schema simultaneously:

1. **Auto-generated connector shadow schemas** (`connectors.*`): created when a connector is added; updated automatically as the external schema changes; hidden from the default IDE view
2. **User-defined application schemas** (`app.*`): created by schema authors; may be views or extensions over connector schemas; visible by default
3. **System schemas** (`system.*`): DataCode internals; visible only to admin tokens

This layering enables data independence: the human-understood schema (`app.*`) can evolve independently of the physical/connector schema underneath it, with coercion handled by functors between the layers.

## Type System

### Primitive Types
Standard Haskell scalar types plus DataCode-defined domain types:
- `Text`, `Int`, `Decimal`, `Bool`, `Timestamp`, `UUID`, etc.
- Domain types are newtypes over primitives with validation functors attached

### Abstract Data Types for Absence
```haskell
-- The base absence type — inherits Maybe.Nothing behavior via typeclass
data NOT_FOUND a = NOT_FOUND

-- Outer join result: field is either present or not found
type Outer a = Maybe a  -- NOT_FOUND is Nothing, value is Just

-- Other typed absences can be defined similarly
data REDACTED a = REDACTED      -- present but access-controlled away
data PENDING a  = PENDING       -- not yet computed/arrived
data DELETED a  = DELETED       -- tombstoned in history
```

All absence types participate in the `Maybe` functor/monad chain so absent values compose correctly without special-casing.

### Table Definitions
```
-- TutorialD-style syntax (exact syntax TBD)
table Customer {
  id        : UUID        [primary_key]
  email     : Email                       -- Email has a validation functor
  name      : Text
  status    : CustomerStatus              -- ADT: Active | Suspended | Closed
}

table Order {
  id          : UUID      [primary_key]
  customer_id : -> Customer               -- foreign key functor
  placed_at   : Timestamp
  total       : Decimal
}
```

### The `all` Selector and Field Propagation

Views and connector shadow schema overlays can use an `all` (or `*`) selector to include all fields from a source table. The selector determines how new fields propagate when the source schema changes:

```
-- Wildcard: tracks source schema dynamically
-- When the source gains a new field, it automatically appears here
view app.commerce.order_summary {
  * FROM connectors.mariadb.production.orders   -- all fields from source
  status : OrderStatus                           -- explicit override: coerces Text -> ADT
}

-- Explicit field list: stable, change-resistant
-- New fields in the source do NOT propagate automatically
view app.commerce.order_detail {
  id     : UUID    FROM connectors.mariadb.production.orders
  total  : Amount  FROM connectors.mariadb.production.orders
  status : OrderStatus
}
```

**Propagation rules:**
- `* FROM <source>` — binds to the source's current schema at query time. New fields in the source appear in the view automatically. Explicit overrides (fields declared by name in the same view) take precedence over the wildcard for that field.
- Named fields — stable binding. The view only exposes the named fields regardless of what the source adds. Adding a new field requires an explicit schema change to the view.
- Mixed — a view can use `*` for the bulk of fields and override specific ones by name. The named overrides shadow the wildcard for those fields.

**Functor interaction:** Validation functors declared on the view apply to the specific fields named in the functor declaration. A wildcard-included field that has no explicit functor inherits any functors declared on the source field's type. A field declared explicitly in the view can add additional functors on top of the inherited ones.

**Schema transaction graph:** When a wildcard view resolves differently because the source gained a new field, that resolution is recorded in the query's provenance — the view's effective field set is always deterministic at any given schema transaction graph node. Pinning a query to a historical schema node pins both the view definition and the source schema snapshot it resolves against.

### Views and Queries
Views are defined identically to tables — they are just table definitions whose "data" is computed from the transaction graph rather than stored directly:
```
view ActiveOrders {
  customer_name : Text      -- from Customer.name
  order_id      : UUID      -- from Order.id
  total         : Decimal
  [where Order.customer_id -> Customer, Customer.status = Active]
}
```
The provenance of each field is tracked in the type, so the system always knows which underlying table a result field originated from.

## Transaction Graph

### Structure
The transaction graph is an **immutable, append-only directed acyclic graph** (a git-like commit DAG). Each node records:
- A unique content-addressed ID (hash of content)
- A sequence number within its shard
- A pointer to the schema graph node that was current at commit time
- The set of mutations applied (inserts, deletes — no in-place updates)
- A timestamp and the committing server's identity

Records are **idempotent** — applying the same transaction twice produces the same state. Records are **never mutated retroactively**.

### Schema Transaction Graph
The schema itself is stored in the same transaction graph structure (in the `system` shard). Every schema change — adding a table, adding a field, defining a new functor — is a commit in the schema graph. This means:
- Every data record implicitly references a schema graph node ("this data was valid under schema version X")
- The full history of schema evolution is queryable
- Rollback is reading from an earlier graph node, not undoing changes

### Schema Evolution and Coercion
Because all functors are transparent, the system can derive a **coercion path** between any two schema graph nodes:
- Adding a field: old records get `NOT_FOUND` for that field (handled by the `Maybe` monad)
- Removing a field: new records simply don't have it; old records still have it in the historical graph
- Changing a type: a migration functor must be provided that maps old values to new values; it is recorded in the schema graph as an edge

This enables:
- **Backwards compatibility**: old clients can read from historical schema nodes
- **A/B testing**: two schema variants can coexist at different graph nodes; data is coerced on the fly
- **Zero-downtime schema changes**: no `ALTER TABLE` locks

### Data Shards
A shard is a named slice of the schema containing related tables. Five shard types:

| Type | Description | Cardinality | Replication |
|---|---|---|---|
| `system` | DataCode self-management tables | Low | All servers |
| `reference` | Code tables; treated as code, propagated everywhere | Low-medium | All servers |
| `configuration` | Tuning tables managed by operators | Medium | All servers |
| `user` | Scales with user count | High | Shard-local |
| `logs` | Massive cardinality; prunable | Very high | Shard-local, time-bounded |

As data volume crosses configurable thresholds, a shard splits. The split is recorded as a special node in the transaction graph so the history of which data lived in which shard is always recoverable.

### Pruning
`logs` shards and old materialized views may be pruned. Pruning is also recorded in the transaction graph as a special node, so the system always knows that historical data before a certain point has been discarded. Analytical summary metrics are computed before pruning to preserve aggregate history.

## Materialized Views

Materialized views are pegged to **specific commit nodes** in the transaction graph. This means:
- They never block or slow down ongoing transactions (they reference a past, stable state)
- They are updated in the background or lazily when accessed
- Each server maintains its own materialized views
- Large analytical queries can be distributed across neighboring servers
- The computation of a materialized view can be shared between neighbors (distribute the work, merge the results)

Views are just table definitions — the distinction between a "live" table and a "materialized view" is a storage hint, not a schema-level distinction.
