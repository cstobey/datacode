# Namespaces

## Concept

DataCode organizes tables, views, types, and functors into a **tree of namespaces**, analogous to Python's module system. Namespaces replace the SQL concept of "databases" and "schemas" (in the PostgreSQL sense). They are the primary organizational unit above the table level.

A fully-qualified name in DataCode looks like:
```
system.auth.User
app.commerce.Order
connectors.mariadb.production.Order
```

Namespaces are:
- Hierarchical (arbitrary depth)
- Stored as nodes in the system shard
- Subject to access control functors (a token may have access to `app.commerce` but not `system.auth`)
- Versioned in the schema transaction graph — renaming or moving a namespace creates a new graph node, old paths remain valid

## Namespace Tree Structure

```
(root)
├── system/              -- DataCode self-management tables
│   ├── auth/            -- users, tokens, sessions
│   ├── api/             -- generated_routes, custom_routes, format_functors
│   ├── connectors/      -- connector configuration and logs
│   ├── events/          -- queues, items, backoff_state, maintenance_queue
│   ├── logs/            -- http_requests and other operational logs (per-server, prunable)
│   ├── schema/          -- schema transaction graph metadata, branches, tags
│   ├── shards/          -- shard topology, server roles, log segments, extent policy
│   └── telemetry/       -- view materialization stats, replication lag
│
├── reference/           -- reference data shards (propagated everywhere)
│
├── connectors/          -- auto-generated shadow schemas from external sources
│   ├── mariadb/
│   │   └── production/
│   │       ├── orders
│   │       ├── customers
│   │       └── ...
│   ├── postgres/
│   │   └── analytics/
│   └── stripe/
│       ├── charges
│       └── subscriptions
│
└── app/                 -- application-defined namespaces (user-managed)
    ├── commerce/
    │   ├── Order        -- may be a view over connectors.mariadb.production.Order
    │   └── Customer
    └── reporting/
```

## Namespace Declarations

Namespaces are declared in the schema DSL (see [schema/](schema/)). Any name with dot-separated components implicitly declares all intermediate namespaces:

```
namespace app.commerce

table Order {
  customer  :> app.commerce.Customer,   -- DataId primary key is implicit
  order_num : Int,
  total     : Amount,
  unique orderRef { customer, order_num }
}
```

A table's fully-qualified name is `app.commerce.Order` — lowercase namespace segments,
capitalized table name. Within the same namespace, tables can refer to each other by short
name. See [schema/README.md](schema/README.md#capitalization).

## Relationship to Shards

Namespaces are a logical organization; shards are a physical one. A namespace does not map one-to-one to a shard — the shard assignment is determined by the table's replication trait (`Reference`, `Configuration`, `UserData`, `LogData`, `Component`) and data volume, not by namespace. The mapping between namespaces and shards is maintained in the system tables and is transparent to queries.

`system` is **not** among those traits: it is a namespace, and a table in it carries whichever replication trait fits. `system.integrity.Violation` is `LogData`; `system.shards.Node` is `Configuration`. The namespace says whose a table is and who may see it; the trait says how it propagates. See [schema/traits.md](schema/traits.md#replication-traits).

A namespace can span multiple shards. A shard can contain tables from multiple namespaces.

## Connector Namespaces

Auto-generated schemas from connectors are placed under `connectors.<type>.<instance>`. For example, a MariaDB connector named `production` would place its auto-discovered tables under `connectors.mariadb.production.*`.

These namespaces are:
- **Automatically managed** — updated when the external schema changes
- **Hidden by default** in the IDE (see ide.md)
- **Referenceable** in user-defined namespaces via views:
  ```
  -- app.commerce.Order is a refined view of the connector shadow schema
  view app.commerce.Order {
    customer :> app.commerce.Customer,
    total     : Amount,      -- coerced from connectors.mariadb.production.Order.total_cents / 100
    status    : OrderStatus  -- coerced from String to ADT
  }
  ```

## Schema Visibility Layers

Every table, view, and functor in DataCode has a **visibility level**:

| Level | Meaning | Default shown in IDE? |
|---|---|---|
| `system` | DataCode internals | No (admin override only) |
| `connector` | Auto-generated connector shadow schemas | No (opt-in per connector) |
| `internal` | User-defined but implementation-detail | No (opt-in) |
| `standard` | Normal application schema | Yes |
| `featured` | High-importance, shown prominently | Yes (weighted higher in PageRank) |

Visibility is stored as a field on the schema transaction graph node. It can be changed without affecting the underlying data or query behavior — it is purely a presentation hint for the IDE and schema PageRank calculation.

The human-managed application schema (`app.*`) is `standard` or `featured` by default. Connector shadow schemas (`connectors.*`) are `connector` by default. Users can override visibility per table.

## Namespace Access Control

Access control functors can be applied at the namespace level, not just the table level:
- A client token granted access to `app.commerce` automatically has access to all tables in that namespace and its children
- Access can be further restricted at the table or row level by additional functors
- A token with access to `app` does not automatically have access to `system` — namespace containment does not imply access containment

## Backwards Compatibility

Because all namespace and schema changes are recorded in the schema transaction graph:
- A table moved from `app.Order` to `app.commerce.Order` creates a new graph node; the old path `app.Order` remains queryable against the historical graph
- A renamed table keeps its old name accessible in the history
- External systems with hard-coded paths continue to work by pinning to a historical schema graph node

This is a core property of the data independence model: the physical and historical structure is never destroyed, only the active view changes.
