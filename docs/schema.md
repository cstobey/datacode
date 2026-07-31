# Schema Model

## Design Philosophy

DataCode schemas are closer to TutorialD than SQL. The core shift:
- A **table** is a named collection of typed tuples (no row ordering, no implicit keys unless declared)
- A **field** has a precise type with associated validation functors
- A **query/view** is indistinguishable from a table definition — both are views over the transaction graph
- There is **no NULL** — absent values are expressed as typed ADTs with meaningful names
- Tables are organized in a **namespace tree** (see `namespaces.md`) — namespaces replace the SQL "database" concept
- **Traits** provide abstract base types for tables, encoding replication policy, shared fields, and shared functions

### Self-Hosting Principle

**DataCode should use DataCode to manage its own operational data wherever practical.**

Every system concern that can be expressed as a table, should be. This includes:

- **API route registrations** — rows in `system.api.generated_routes` and `system.api.custom_routes`
- **Connector configurations** — rows in `system.connectors.*`
- **Event queues** — rows in `system.events.items` (and user-defined queue tables in `app.*`)
- **Scheduler state** — rows in `system.events.*`
- **Auth tokens and sessions** — rows in `system.auth.*`
- **Schema version promotions** — rows in `system.branches` and `system.tags`
- **Operational metrics and logs** — rows in `system.logs.*` (logs shard, prunable)
- **HTTP request logs** — rows in `system.logs.http_requests` (per-server log shard; written regardless of transaction outcome — see HTTP Request Logging below)

The practical consequences:
- DataCode's own configuration is inspectable and queryable with standard DataCode tooling
- System operations (connector sync, event dispatch, shard maintenance) are auditable in the transaction log
- The IDE can show system state the same way it shows application state
- Bootstrapping is the only exception — the very first system tables must exist before DataCode can use DataCode to manage them

## Namespace Organization

Every table belongs to a namespace. Namespaces are dot-separated hierarchical paths:
- `app.commerce.orders` — user-defined application schema
- `connectors.mariadb.production.orders` — auto-generated connector shadow schema
- `system.auth.users` — DataCode self-management tables

Namespaces are created implicitly when a table is first defined in them — no explicit creation syntax. Full namespace documentation: see `namespaces.md`.

## Schema Visibility Layers

DataCode maintains multiple layers of schema simultaneously:

1. **Auto-generated connector shadow schemas** (`connectors.*`): created when a connector is added; updated automatically as the external schema changes; hidden from the default IDE view
2. **User-defined application schemas** (`app.*`): created by schema authors; may be views or extensions over connector schemas; visible by default
3. **System schemas** (`system.*`): DataCode internals; visible only to admin tokens

This layering enables data independence: the human-understood schema (`app.*`) can evolve independently of the physical/connector schema underneath it, with coercion handled by functors between the layers.

## Type System

### Primitive Types

Standard scalar types:

| Type | Description |
|---|---|
| `Text` | Unicode string |
| `Int` | Integer |
| `Decimal` | Arbitrary-precision decimal |
| `Bool` | Boolean |
| `Date` | Calendar date |
| `Timestamp` | Point in time |
| `DataId` | 12-byte globally unique identifier (see Globally Unique Identifiers) |

### Domain Types

Domain types are named subtypes of primitives. The `:` operator means "is a kind of" throughout DataCode. Domain types carry validation functors.

```
type Email  : Text    { validate: isValidEmail }
type Amount : Decimal { validate: \a -> a >= 0 }
type Zip    : Text    { validate: \z -> length z == 5 }
```

Note: the `{ validate: ... }` inline syntax is tentative and may change.

Domain types are reusable named types. When a field in a table references a domain type, it creates a new named subtype scoped to that field (`namespace.table.field`) — validations are inherited and can be extended. Two fields in different tables are always distinct types even if they share the same domain type as their parent.

### Sum Types (ADTs)

The `|` operator builds sum types. This is the same operator used for relational union — context (type-annotation position vs. query-expression position) disambiguates.

```
type CustomerStatus = Active | Suspended | Closed

-- Inline in a field declaration
status : Active | Suspended | Closed
```

### Product Types

Multiple fields in a record body form a product type. Tuple notation `(A, B)` is available for and-types used outside a named record.

### Absence Types

There is no `NULL`. Absent values are expressed as typed ADTs that extend the `Null` base type. This encodes the *reason* for absence, not just the fact of it.

Built-in absence types (all extend `Null`):

| Type | Meaning |
|---|---|
| `NotFound` | Row or value does not exist |
| `Redacted` | Present but access-controlled away |
| `Pending` | Not yet computed or arrived |
| `Deleted` | Tombstoned in history |

Custom absence types:

```
type MissingCustomer : Null
type NoActiveSubscription : Null
```

Using absence types in fields:

```
phone       : Phone | NotGiven         -- NotGiven extends Null; reason for absence is typed
billing_zip : Zip   | NotFound         -- built-in absence type
```

### The `is` Operator

`is` checks the outermost constructor of a sum type, regardless of any payload. Distinct from `=` which checks exact value equality including payload.

```
status is Active              -- constructor match (works with or without payload)
status is Suspended           -- matches any Suspended regardless of reason payload
status = Suspended "overdue"  -- exact equality including payload
phone is NotGiven             -- absence check
phone is not NotGiven         -- negation
```

## Table Definitions

### Basic Syntax

```
-- DataId primary key is always implicit — no declaration needed
-- Namespace created implicitly on first use
table app.commerce.Customer {
  email        : Email
  name         : Text
  status       : Active | Suspended | Closed
  phone        : Phone | NotGiven
  loyalty_tier : Tier = Bronze      -- field default with =
}
```

Every table has two automatic virtual columns:
- `created_at` — timestamp extracted from the row's `DataId`
- `updated_at` — timestamp of the most recent `RowId` that mutated the row

`RowId` (the physical row identifier) is internal only and not exposed in the schema DSL.

### Field Defaults

```
loyalty_tier : Tier = Bronze
name         : Text = "Unknown"
is_active    : Bool = True
```

### Uniqueness Constraints

```
-- Single-field: `unique` keyword suffix
email : Email unique

-- Multi-field: named constraint in table body
table Order {
  customer  : -> Customer
  order_num : Int
  unique orderRef { customer, order_num }
}

-- Standalone post-definition (add after table exists)
unique Order.orderRef { customer, order_num }
```

Multiple unique constraints per table are all enforced. `DataId` remains the primary key; unique constraints define natural keys used for fast lookup.

### Default Ordering

```
table Order {
  placed_at : Timestamp
  total     : Amount
  order by placed_at desc    -- default ordering for queries against this table
}
```

System default (if no `order by` declared): unique key ascending. Overridable per-query.

### Foreign Keys

The `->` arrow creates an FK field and automatically attaches an FK functor. The field gets its own named type (`namespace.table.field`) which wraps the referenced table's `DataId`.

```
table app.commerce.Order {
  customer  : -> Customer       -- FK to Customer; creates Order.customer type
  placed_at : Timestamp
  total     : Amount
}
```

### Inline Sub-Tables

Defining a table inline inside a field declaration automatically creates the sub-table as a sibling in the parent's namespace.

```
-- Creates app.commerce.Address as a sibling table
table app.commerce.Customer {
  address : Address {
    street : Text
    city   : Text
    zip    : Zip
  }
}
```

To place the sub-table in a different namespace, use a fully-qualified name in the inline definition.

### Schema Constraints and ACL

`assert` is the unified keyword for both path-equivalence constraints and access control rules. Both are path-equivalence assertions — ACL is simply a path-equivalence where one term is the requesting user token.

```
table Order {
  customer  : -> Customer
  bill_addr : Address

  -- Path-equivalence constraint: two paths must resolve to the same value
  assert billingMatch { customer.billing_address == bill_addr }

  -- ACL: requesting user must be reachable from this row via customer.user_id
  assert access { user.id == customer.user_id }
}
```

Both inline and standalone forms are supported:

```
-- Add after table is already defined
assert Order.billingMatch { customer.billing_address == bill_addr }
assert Order.access { user.id == customer.user_id }
```

`user` refers to the requesting user token inside `access` assertions.

## Traits

Traits are abstract table types. They cannot be instantiated directly — they are extended by concrete tables. A trait adds fields, functions, replication policy, and (optionally) UI template hints to every table that extends it.

### Declaring a Trait

```
trait Active {
  is_active : ActiveStatus | InactiveStatus

  -- Functions defined in a trait are available on any table extending it
  active   self = self where is_active is ActiveStatus
  inactive self = self where is_active is InactiveStatus
}
```

### Extending a Table from Traits

The `:` operator after the table name declares which traits the table extends. Same colon-as-"is a kind of" convention used throughout the type system.

```
table app.commerce.Customer : Active, UserData {
  email : Email
  name  : Text
}

-- active/inactive functions now work on Customer
active (app.commerce.Customer where email is not NotGiven)
```

### Multiple Inheritance

Tables may extend multiple traits. If two traits define a field with the same name, the concrete table must resolve the conflict explicitly:

```
trait A { name : Text { validate: isNotEmpty } }
trait B { name : Text { validate: maxLen 100 } }

-- Keep both fields separately: rename A's field
table Foo : A, B {
  a_name : Text from A.name   -- rename; keeps A's validations; B's name unchanged
}

-- Or merge into one field: inherits validations from both A and B
table Bar : A, B {
  name : Text   -- bare redeclaration; validations from A and B are both applied
}
```

### Replication Traits

The five shard types map to built-in traits. Tables declare their replication policy by extending one of these.

| Trait | Replication | Cardinality |
|---|---|---|
| `Reference` | All servers | Low–medium |
| `Configuration` | All servers | Medium |
| `UserData` | Shard-local | High |
| `LogData` | Server-local, prunable | Very high |

Built-in replication traits are regular traits — user-defined traits can extend them freely:

```
trait Catalog : Reference {
  is_visible : Bool = True
}

table app.commerce.Product : Catalog, Active {
  name  : Text
  price : Amount
}
-- Product replicates to all servers (inherits Reference via Catalog)
```

Having multiple replication base traits in a single inheritance hierarchy is a compile-time error.

### UI Template Hints

Traits can declare UI hints that are stored in system tables and used by the HTML rendering engine:

```
trait Card {
  ui { template: "card", density: "compact" }
}
```

Exact syntax for UI hints is TBD.

## Schema Evolution

All previous versions of a table are always present in the transaction graph. "Evolution" means creating a new schema node, not modifying historical data.

### Redeclaring a Table

Redeclare the table body. The system diffs the new declaration against the last version:

- **Column added** → new column; uses field default if provided
- **Column omitted** → deprecated (hidden from queries; data stays in graph)
- **`rename from` hint** → rename (explicit because rename vs. add+remove is ambiguous)
- **Same name** → old type is auto-hidden in the current schema node; still reachable via version tokens
- **Type change** → requires a migration functor (syntax TBD)

```
-- Old Customer had: email, name, status, phone
-- New Customer: renames status, adds loyalty_tier, drops phone
table Customer {
  account_status : AccountStatus rename from status
  loyalty_tier   : Tier = Bronze
  -- phone omitted → deprecated
}
```

### Keeping Old Names

If the redeclaration uses a *different* name, both old and new stay visible. Deprecate old manually when ready.

```
table CustomerV2 { ... }   -- Customer still accessible by name
deprecate Customer          -- hide later when migration is complete
```

### Deprecation and Pruning

```
deprecate Customer          -- hides table; existing views stay alive; data stays in graph
deprecate Customer.phone    -- hide a single field
prune Customer              -- permanently remove data (only valid once no live references remain)
```

### Table Split and Merge

```
split Customer into {
  Person      { name : Text; birth_date : Date }
  ContactInfo { email : Email; phone : Phone | NotGiven }
}

merge Person, ContactInfo into Customer {
  name       : Text
  birth_date : Date
  email      : Email
  phone      : Phone | NotGiven
}
```

Source tables in a split/merge stay visible by default; deprecate them explicitly.

### ADT Extension

Sum types can gain or lose variants after the fact. Removing a variant that has existing data requires specifying how those rows are migrated.

```
extend Customer.status with Archived

shrink Customer.status removing Archived migrate (\_ -> Closed)
```

## Joins and Queries

### Join Operator

`><` (bowtie) is the natural join operator. It joins on matching FK columns by default.

```
-- Natural join: uses FK constraint between Order and Customer
Order >< Customer

-- Explicit FK path: required when multiple FKs exist between two tables
Order >< Customer via customer
```

### Outer Joins

Outer joins use guard semantics: the right side of `><` is a sum type written with `|`. The system tries each type left-to-right; the first that produces a matching row wins. Null-derived types always match and serve as the catch-all.

```
type MissingCustomer : Null

-- Left outer join equivalent
Order >< Customer | MissingCustomer

-- Chained fallback: try Customer, then HistoricalCustomer, then catch-all
Order >< Customer | HistoricalCustomer | MissingCustomer
```

The result row's customer field has type `Customer | MissingCustomer` — a sum type. Pattern matching and functor targeting can address each variant. `MissingCustomer` carries no fields; the absence IS the value.

### Filter, Projection, Alias

```
Order >< Customer
  where total > 100
  { customer.name as name, total as order_total }
```

- `where` — row filter
- `{ field, ... }` — projection (bare braces, no `select` keyword)
- `as` — alias

Field references: `TableName.field_name` or `alias.field_name`. Table aliases are encouraged when the full namespace path is in the name.

### Grouping

`group` puts the grouped field on the left; all other fields collapse into a nested table field. Aggregate functions operate on that nested table.

```
Order
  group customer
  { customer, orders.total sum as total_spend }
-- Result: { customer: DataId, total_spend: Amount }
-- The intermediate orders nested table is computed then projected away
```

### Ordering

```
-- Per-query ordering (overrides table default)
Order
  where total > 100
  order by total desc
  { customer, total }
```

### Views

Views are defined identically to tables — they are table definitions whose data is computed from the transaction graph rather than stored directly. The distinction is a storage hint, not a schema distinction.

```
view app.commerce.active_orders {
  customer : -> Customer
  total    : Amount
  where status is Active
}
```

### The `all` Selector and Field Propagation

Views and connector overlays can use `*` to include all fields from a source table:

```
-- Wildcard: tracks source schema dynamically
view app.commerce.order_summary {
  * from connectors.mariadb.production.orders
  status : OrderStatus    -- explicit override: coerces Text -> ADT
}

-- Explicit field list: stable, change-resistant
view app.commerce.order_detail {
  id     : DataId from connectors.mariadb.production.orders
  total  : Amount from connectors.mariadb.production.orders
  status : OrderStatus
}
```

`*` binds to the source's schema at query time — new fields in the source appear automatically. Named fields bind stably — new source fields don't propagate. Mixed views can use `*` for the bulk and override specific fields by name.

## Functions

### Scope

Top-level declarations are **global** — committed to the schema transaction graph. `let` is only for local bindings inside function bodies. There is no `def` keyword.

```
-- Top-level: stored in schema
isPositive a = a > 0

premiumFilter = Order where total > 1000

-- Local: inside a function body only
processOrder order =
  let discount = if order.total > 1000 then 0.1 else 0
  in order { total = order.total * (1 - discount) }
```

### REPL Transactions

The REPL operates in a transaction model: everything typed is staged but not committed until `:commit`. Use `:rollback` to discard. This prevents accidental schema changes from exploratory queries.

### Haskell Functions

Functions are written in Haskell style. Types are automatically threaded through the system monad.

Auto-wrapping rules:
- `a -> b` (pure) → lifted automatically
- `a -> Maybe b` → `Nothing` becomes a validation failure
- `a -> IO b` → **rejected** at schema commit; use an event functor queue instead

```
import Data.Time (UTCTime, diffUTCTime)

-- Standard library is auto-available; extra packages via import
validateEmail : Text -> Bool
validateEmail e = e =~ "^[^@]+@[^@]+\\.[^@]+"
```

Standard library always available (no import needed): `Data.Text`, `Data.Time`, `Data.Maybe`, `Data.List`, `Data.Map`, `Text.Regex.TDFA`, standard numeric packages.

Extra packages require `import` at the schema file level. The allowed package list is managed by admins in `system.config.allowed_packages`.

## Functor Types

DataCode has five functor kinds. All five are first-class schema objects — defined as rows in system tables, referenced by `FunctorRef`, and encoded in the GADT DSL (confirmed in `spikes/dynamic-loading/output.txt`).

| # | Kind | Signature | When it runs | Purpose |
|---|---|---|---|---|
| 1 | **Validation** | `a → Either Error a` | On commit | Rejects invalid field values (range checks, format checks, domain invariants) |
| 2 | **Foreign key** | `DataId → Either Error Row` | On commit | Referential integrity — resolves a DataId to a live row in the referenced table |
| 3 | **Path equivalence** | `(a, a) → Either Error ()` | On commit | Asserts that two schema-graph paths reach the same value; used for both data constraints and ACL |
| 4 | **Access control** | `(User, a) → Either Error a` | On read and write | Gates reads and writes based on the requesting user's identity and role; can redact individual fields |
| 5 | **Event** | `a → EventRef` | On commit | Schedules a deferred side effect — enqueues a work item in a DataCode queue table rather than executing immediately |

Functors 1–4 are synchronous and transactional: they run as part of the commit and can abort it. Functor 5 is asynchronous and decoupled: the commit always succeeds (inserting the queue row is the commit), and the side effect runs later under the event scheduler.

Path equivalence functors (kind 3) are the implementation backing of both `assert` constraints and `assert access` rules in the DSL. The difference is only in what the two path terms refer to — data paths vs. data path and requesting token.

### Event Functor

An event functor, when attached to a table, fires whenever a matching row is inserted or updated. It does not execute the side effect itself — it writes a work item into a designated DataCode queue table. This keeps the commit path fast and ensures external side effects are:

- **Durable** — the queue row survives a server crash
- **Observable** — queue depth, failure rates, and retry counts are queryable
- **Retryable** — the scheduler owns the retry policy; the functor just writes the payload
- **Rate-limited** — the scheduler applies volume-based backoff before dispatching

The queue table is a normal DataCode table (`app.events.email_queue`, `app.events.webhook_queue`, etc.) — inspectable in the IDE, filterable, and audited in the transaction log.

## Transaction Graph

### Structure
The transaction graph is an **immutable, append-only directed acyclic graph** (a git-like commit DAG). Each node records:
- A `DataId` — globally unique 12-byte identifier (see Globally Unique Identifiers below); timestamp and server identity are encoded within it
- A sequence number within its shard
- A pointer to the schema graph node that was current at commit time
- The set of mutations applied (inserts, deletes — no in-place updates)

Records are **idempotent** — applying the same transaction twice produces the same state. Records are **never mutated retroactively**.

### Schema Transaction Graph
The schema itself is stored in the same transaction graph structure (in the `system` shard). Every schema change — adding a table, adding a field, defining a new functor — is a commit in the schema graph. This means:
- Every data record implicitly references a schema graph node ("this data was valid under schema version X")
- The full history of schema evolution is queryable
- Rollback is reading from an earlier graph node, not undoing changes

### Branches, Tags, and Version Tokens

The transaction graph supports three kinds of named references, all of which are valid version tokens in API paths (`/v{token}/records/...`):

| Token type | Moves? | Example | Resolves to |
|---|---|---|---|
| **Graph node hash prefix** | Never | `a3f9c2b` | Itself — canonical, content-addressed |
| **Tag** | Never | `v2.1.0`, `stable-2026-q2` | The specific node the tag was attached to |
| **Branch name** | Yes (HEAD advances) | `main`, `experiment-checkout` | Current HEAD of that branch |

All three resolve at dispatch time to a schema graph node hash, which then selects the route set registered at that node. The hash prefix is the lowest-level escape hatch — it works even when no tag or branch name has been declared.

**Branch policy**: All branches must be explicitly named. Anonymous DAG forks are not permitted — creating a divergent commit requires naming the branch first. The `main` branch cannot be deleted.

**Tag attachment**: Tags are rows in `system.version_refs` (see below), inserted as part of a transaction. A tag, once written, is immutable — it permanently identifies the schema at a specific point in time. Semantic names (`v1.2.0`, `stable`) are the expected primary UX; the hash prefix exists as the canonical fallback.

**Version ref storage**: Branches and tags share a single system table. The `VersionRef` ADT encodes the mutability difference directly in the type — no discriminator column needed:

```haskell
data VersionRef
  = Branch DataId    -- mutable: HEAD pointer advances as commits land on this branch
  | Tag    DataId    -- immutable: permanently pinned to one schema node
```

```
system.version_refs
  name : Text unique    -- unique across all branches and tags
  ref  : VersionRef     -- Branch DataId | Tag DataId
```

The `Tag` variant's immutability is enforced by a validation functor that rejects any update to a row whose current `ref` is a `Tag`. The `Branch` variant has no such restriction — HEAD advances freely. Deletion of the `main` branch is rejected by a separate validation functor. Hash prefixes are implicit graph node identifiers and require no row in this table.

**Creating and merging branches**: A new branch forks from an existing node and accumulates commits independently. When a branch is merged back, the merge commit records **two parent pointers** — one to the prior HEAD on the target branch and one to the tip of the incoming branch. The DAG permanently shows both lineages; there is no rebase and no history rewriting.

**Conflict resolution on merge**: Merge conflicts in both the schema and data graphs are resolved by defining a functor that reconciles the divergent schemas, then applying that functor to the affected data. The goal is for transparent functors to handle this automatically in the common case; manual resolution is reserved for cases the functor cannot express. The resolution functor is itself committed as a node in the schema graph.

**Orphaned branches**: A branch is orphaned when it has never been merged to `main` (or any branch that has been merged to `main`) and its continued development has been abandoned. Orphaned branches are the only case where the transaction graph is editable: an orphaned branch and all nodes exclusive to it may be deleted. A branch with any path to `main` (via merge) cannot be deleted.

**No-version routing**: Requests without a version token are routed to `main` HEAD by default. The server can also split unversioned traffic across named branches at a configurable rate for A/B testing; routing decisions persist via session affinity so the same client consistently receives the same branch. This makes local and A/B testing seamless without requiring clients to specify a version.

**Promoting a version**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch name the operator has promoted. The `/versions` discovery endpoint lists all live version tokens and marks the promoted one. Operators use this to signal "use this tag going forward" without requiring client code changes. Promotion state is stored in a system table and is itself versioned.

### Schema Evolution and Coercion
Because all functors are transparent, the system can derive a **coercion path** between any two schema graph nodes:
- Adding a field: old records get `NotFound` for that field
- Removing a field: new records simply don't have it; old records still have it in the historical graph
- Changing a type: a migration functor must be provided that maps old values to new values; it is recorded in the schema graph as an edge

This enables:
- **Backwards compatibility**: old clients can read from historical schema nodes
- **A/B testing**: two schema variants can coexist at different graph nodes; data is coerced on the fly
- **Zero-downtime schema changes**: no `ALTER TABLE` locks

### Data Shards
A shard is a named slice of the schema containing related tables. Five shard types, each corresponding to a built-in replication trait:

| Shard / Trait | Description | Cardinality | Replication |
|---|---|---|---|
| `Reference` | Code tables; treated as code, propagated everywhere | Low-medium | All servers |
| `Configuration` | Tuning tables managed by operators | Medium | All servers |
| `UserData` | Scales with user count | High | Shard-local |
| `LogData` | Massive cardinality; prunable | Very high | Shard-local, time-bounded |
| `system` | DataCode self-management tables | Low | All servers |

`LogData`-type shards are **server-local by default**: each server is authoritative for its own log data and does not replicate it to peers. This is a deliberate tradeoff — log volume makes cross-server replication expensive, and per-server logs are sufficient for auditability (query each server's log shard independently, or aggregate via a materialized view). The HTTP request log shard is a specific instance of this pattern (see HTTP Request Logging below).

As data volume crosses configurable thresholds, a shard splits. The split is recorded as a special node in the transaction graph so the history of which data lived in which shard is always recoverable.

### Pruning
`LogData` shards and old materialized views may be pruned. Pruning is also recorded in the transaction graph as a special node, so the system always knows that historical data before a certain point has been discarded. Analytical summary metrics are computed before pruning to preserve aggregate history.

### Globally Unique Identifiers

Both transaction graph nodes and logical rows use a unified 12-byte `DataId`:

```
Bytes 0–4:  Unix timestamp in seconds  (big-endian, 5 bytes) — valid through year ~36 800
Bytes 5–6:  Server ID                  (big-endian, 2 bytes) — up to 65 535 servers
Bytes 7–11: Sequence counter           (big-endian, 5 bytes) — up to ~1.1 trillion per server per second
────────────────────────────────────────────────────────────────────────────────────────
Total: 12 bytes
```

- **Timestamp**: Unix epoch seconds. No sub-second precision needed — the sequence counter handles intra-second uniqueness.
- **Server ID**: assigned sequentially at server registration; coordination required only at registration time, not at ID generation time.
- **Sequence**: monotonically increasing counter per `(server, second)`, reset each second. 5 bytes = 2^40 ≈ 1.1 trillion increments/second/server.

Big-endian encoding means lexicographic order approximates chronological order, which benefits LMDB range scans. `DataId` is globally unique without per-ID coordination.

`DataId` is the primary key type for all DataCode-native tables and the identity of transaction graph nodes.

### Row Identifiers

Every row version in the transaction graph has a **composite physical row identifier**:

```haskell
data RowId = RowId
  { ridShard  :: Word32  -- shard index (4 bytes; supports ~4B shards)
  , ridTxSeq  :: Word64  -- monotonic tx sequence within shard (8 bytes)
  , ridRowPos :: Word16  -- row position within transaction (2 bytes; max 65535 rows/tx)
  }
-- Encoded as 14 bytes, big-endian throughout
```

Big-endian encoding is critical: LMDB sorts keys lexicographically, and big-endian integer encoding makes `lexicographic order == numeric order`. This means "all rows written by transaction 42 in shard 1" is a single contiguous LMDB range scan with no scatter-gather.

Transaction nodes themselves use `rowPos = 0` by convention (`txNodeId shard txSeq = RowId shard txSeq 0`). Rows within a transaction occupy positions 1 through N.

**Two-tier identifier model:**
- **User-visible**: the `DataId` primary key. Stable across mutations — same `DataId` throughout the row's lifetime.
- **Physical**: `RowId` — changes on every mutation, pointing to the newest version in the log. Internal only; not exposed in the schema DSL.

The LMDB `head_index` bridges the two: `DataId → current RowId`. Following up through `log_index` yields the physical location on disk.

**Sort order confirmed by spike** (`spikes/storage/output.txt`): ByteString lexicographic sort of encoded RowIds produces the same ordering as Haskell's derived `Ord` instance.

### Physical Storage Architecture

The transaction graph is persisted as two complementary structures per shard:

**1. Append-only transaction log (Cap'n Proto frames)**

Immutable, sequentially written. Each entry is a length-prefix-framed Cap'n Proto `TxNode` message:

```
[4-byte big-endian length][Cap'n Proto TxNode bytes...]
```

Each `TxNode` carries: its own `RowId`, schema version reference, timestamp, server ID, parent RowId list, and the list of mutations (inserts/deletes). Benchmark: encode ~0.15µs/tx, decode ~0.10µs/tx at 10 mutations/tx.

With Cap'n Proto + mmap, the bytes on disk **are** the runtime representation — field access is pointer arithmetic, not deserialization. This is the Mnesia analogy: the disk format evolves with the schema, not with the data.

**2. Two LMDB databases per shard**

| Database | Key | Value | Purpose |
|---|---|---|---|
| `log_index` | 14-byte RowId | 12-byte `{offset: Word64, length: Word32}` | Random access to any row version in O(1) |
| `head_index` | 12-byte DataId | 14-byte RowId | Resolve logical row to current physical version |

**Full zero-copy read path:**
```
DataId → head_index → RowId
       → log_index  → (file_offset, length)
       → mmap[offset:length] → Cap'n Proto message
       → field access via pointer arithmetic (no copy)
```

LMDB properties that make this viable: memory-mapped (reads touch OS page cache, not a copy), MVCC (readers never block writers), crash-safe by default (copy-on-write B-tree + two root pages, no separate WAL), and sorted keys (range scans over all rows in a transaction are contiguous).

**LMDB threading**: requires `-threaded` in GHC options and a session-level `runInBoundThread` wrapping the entire LMDB session (open → read/write → close). The `lmdb` Haskell package calls `isCurrentThreadBound` before acquiring its write lock. Production pattern: one dedicated OS-bound thread (`forkOS`) for writes, with a `TQueue`; reads are concurrent (LMDB MVCC).

**LMDB latency** (confirmed in `spikes/capnproto/output.txt`): reads 11µs/op. Writes 1,107µs/op — high because LMDB `fdatasync()`s on every transaction commit. This is not a concern: DataCode batches multiple mutations per transaction (10–100 mutations/tx → 11–110µs/mutation). Single-mutation micro-benchmarks are not representative.

**Wire format for replication** (confirmed in `spikes/capnproto/output.txt`): use cereal during initial development; swap to Cap'n Proto generated code before production. Wire framing (length-prefix + single-segment message header) is identical — only the payload encoding changes. Cap'n Proto provides automatic schema evolution: adding a new field to `TxNode` is always backward and forward compatible, no decoder changes needed. Adding one field costs exactly 8 bytes per message. Encode and full decode both sub-µs.

## Custom APIs

DataCode exposes data through two complementary API layers — auto-generated and user-defined — both managed as **rows in system tables**. Because API registrations live in the schema transaction graph, every change is automatically versioned. Version prefixes in every URL path mean no route is ever removed: old client integrations remain valid indefinitely.

### Versioning and Backwards Compatibility

Every route — auto-generated and custom — is prefixed with the schema version at which it was registered:

```
/v{N}/records/app.commerce.orders      -- auto-generated CRUD at version N
/v{N}/api/orders/{id}/ship             -- custom endpoint at version N
```

When a schema change is committed (a new transaction graph node), routes added at that node are registered under the new version prefix. Routes from all prior nodes remain in the dispatch table permanently — the table is append-only in practice. A client pinned to `/v3/...` continues working after the schema advances to version 10.

This gives:
- **No breaking changes** — clients stay on their version prefix until they explicitly migrate
- **Multiple live versions simultaneously** — a single server process serves all version prefixes at once
- **Trivial rollback** — clients repoint to an older prefix; the server already handles it

Version tokens may be a graph node hash prefix, a tag, or a branch name — all three are interchangeable in URL paths. See OQ-026 (answered) and the Branch and Tag lifecycle section above.

### Auto-Generated Routes

The auto-generated API is driven by a system table — one row per exposed table or view:

```
system.api.generated_routes
  table_ref   : TableRef     -- which table or view to expose
  methods     : [HttpMethod] -- which HTTP methods to expose (default: all)
  format_ref  : FormatRef    -- which format functor to use
  enabled     : Bool
```

The response format is determined by a second system table of **format functors** — pluggable representations of the same underlying data:

```
system.api.format_functors
  name        : Text         -- e.g. "json-flat", "graphql", "csv"
  functor_ref : FunctorRef   -- functor that transforms query results into the wire format
```

This decouples representation from schema: the same table can be served as JSON, GraphQL, or CSV from different route registrations without touching the underlying schema definition. New format functors can be registered at runtime.

### Custom Routes

User-defined endpoints are rows in a system table. Each row defines a URL template and the functor to invoke per HTTP method:

```
system.api.custom_routes
  route_template : Text             -- e.g. "/orders/{id}/ship"
  get_functor    : FunctorRef | NotAllowed
  post_functor   : FunctorRef | NotAllowed
  put_functor    : FunctorRef | NotAllowed
  patch_functor  : FunctorRef | NotAllowed
  delete_functor : FunctorRef | NotAllowed
```

`NotAllowed` means that HTTP method returns 405 on that route. A route with only `post_functor` set is a write-only endpoint.

Each referenced functor is an **API functor**: it receives the extracted path parameters and request body (if present), performs reads and/or writes within a single transaction, and returns a response value. Authentication and authorization apply automatically (see below).

Inserting or updating a row in `system.api.custom_routes` takes effect immediately — the WAI dispatch table is updated as part of committing the transaction, with no server restart.

### Route Conflict Resolution

Custom routes shadow auto-generated routes at the same path. If a custom route is registered at `/records/app.commerce.orders/{id}`, it handles all requests to that path — the auto-generated handler is bypassed for that schema version. Removing the custom route restores auto-generated behavior.

**Reserved `raw/` prefix**: `/v{N}/raw/<table-path>` always routes to the auto-generated handler. Custom routes whose template starts with `raw/` are rejected at insert time. This guarantees auto-generated CRUD is always reachable regardless of custom route registrations:

```
GET /v{N}/records/app.commerce.orders/{id}  -- custom handler if registered; auto-generated otherwise
GET /v{N}/raw/app.commerce.orders/{id}      -- always auto-generated
```

**Path validation**: A custom route registered under the `/records/` prefix must reference a table or view that exists in the current schema. Phantom overrides (custom routes for non-existent tables) are rejected at insert time.

**Version semantics**: Custom routes are schema objects — they are committed to the transaction graph and are naturally included or excluded based on which schema node a version token resolves to. No special routing-mode flag is needed on branches or tags; the schema graph already captures when a custom route existed.

### Authentication and Authorization

**Authentication** is always on. Every request to any route — auto-generated or custom — must carry a valid client token and user token. There is no mechanism to create an unauthenticated DataCode endpoint.

**Authorization** is automatic and derived from the access control functors on the tables the API functor accesses. No per-route permission declaration exists: if the functor reads `app.commerce.orders`, the same access control functors apply as if the caller had queried that table directly. A custom functor that reads multiple tables must satisfy the access control functors on all of them.

### HTTP Dispatch

All routes — auto-generated and custom — are materialized from the system tables into a runtime WAI dispatch table (an IORef-backed route trie, as confirmed by the Servant+Warp spike). The Servant frame handles the static URL structure; the dispatch table handles the versioned and dynamic portions. Route templates are compiled into path-matchers at registration time; path parameters are extracted at request time and passed to the functor.

### HTTP Request Logging

Every HTTP request to any DataCode endpoint is logged to `system.logs.http_requests` — a per-server `LogData`-type shard. This write is **independent of the main transaction**: it succeeds whether the transaction commits, is rejected, or errors. It is the only write that DataCode guarantees on every request path.

```
system.logs.http_requests {
  server_id     : ServerId
  received_at   : Timestamp
  method        : HttpMethod
  path          : Text
  version_token : Text
  status_code   : Int
  duration_ms   : Int
  client_token  : TokenId | NotFound
  user_token    : TokenId | NotFound
  tx_id         : DataId  | NotFound
  error         : Text    | NotFound
}
```

Key properties:
- **Always written** — a failed, rejected, or errored transaction still produces a log row
- **Per-server** — not cross-replicated; each server is authoritative for its own request history
- **Prunable** — subject to the same time-bounded retention as other `LogData` shards
- **Auditable** — inspectable in the IDE; queryable with standard DataCode tools

This log is the foundation for observability: correlating `tx_id` with the transaction graph gives the full audit trail from HTTP request through to committed mutations.

## Event System

The event scheduler is DataCode's mechanism for all deferred and external side effects — both system maintenance and user-triggered outbound calls. It is not a separate message broker; the queues are DataCode tables.

### Design Principle

**No external call may be made from within a commit transaction.** Any operation that touches an external system (send an email, call a webhook, update a third-party API endpoint) must go through a queue table. A transaction that needs to trigger an external effect inserts a row into a queue table; the commit completes; the scheduler picks it up later and executes the side effect. This means:

- Commits are never blocked by external latency
- Side effects are durable — a crash between commit and execution loses nothing
- The queue is inspectable and auditable with standard DataCode tools
- Retry logic and backoff are centralized in the scheduler, not scattered across application code

### User-Defined Queue Tables

Applications define their own queue tables for outbound side effects:

```
table app.events.email_queue {
  recipient : Email
  template  : EmailTemplate
  payload   : JsonObject
  assert event { system.connectors.email.SendFunctor }
}

table app.events.webhook_queue {
  destination : URL
  body        : JsonObject
  assert event { system.connectors.http.PostFunctor }
}
```

The `assert event` attribute links the queue table to the connector functor that knows how to process it. When the scheduler dequeues a row, it calls that functor with the row as input.

### System Queue Tables

The scheduler also drives internal DataCode maintenance through system-managed queues:

```
system.events.maintenance_queue
  -- log compaction, shard splits, materialized view refreshes,
  -- LMDB vacuum, index rebuilds, orphaned branch cleanup
  -- Populated by the server itself; not user-accessible
```

This means maintenance scheduling is itself observable through DataCode — operators can query `system.events.maintenance_queue` to see what maintenance is pending and when.

### System Tables

```
system.events.queues {
  name         : Text unique
  handler_ref  : FunctorRef
  max_attempts : Int
  backoff_base : Duration
}

system.events.items {
  queue_name    : Text
  payload       : Bytes
  scheduled_at  : Timestamp
  attempt_count : Int
  last_error    : Text | NotFound
  status        : Pending | InFlight | Failed | Done
}

system.events.backoff_state {
  destination   : Text unique
  failure_rate  : Decimal
  volume_count  : Int
  backoff_until : Timestamp
}
```

### Volume-Based Backoff

The scheduler uses **volume-based backoff**, not just time-based backoff. This matters because:

- A destination may be healthy but rate-limited — backing off by time alone starves other destinations sharing the same worker pool
- A destination may have started failing due to volume (the caller is overwhelming it) — the correct response is to reduce volume, not just delay

Backoff logic:
1. **Per-destination failure tracking**: rolling failure rate over a recent window. If the rate exceeds a threshold, enter backoff.
2. **Volume throttling**: if the queue depth for a destination exceeds a configured limit, throttle new dispatches to that destination regardless of failure rate.
3. **Exponential delay**: `backoff_duration = backoff_base × 2^(failure_count)`, capped at a maximum.
4. **Jitter**: randomized ±20% on the delay to prevent thundering-herd recovery.

Backoff state lives in `system.events.backoff_state` — observable and adjustable by operators without a server restart.

### Scheduler Architecture

The event scheduler is a dedicated DataCode process (similar to the connector daemon — see OQ-019). It:

1. Polls `system.events.items` for rows with `status is Pending` and `scheduled_at ≤ now`
2. Marks each item `InFlight` atomically (prevents double-dispatch)
3. Calls the queue's `handler_ref` functor with the payload
4. On success: marks `Done`, updates `system.events.backoff_state` (reset failure count)
5. On failure: increments `attempt_count`, logs `last_error`, computes next `scheduled_at` from backoff, marks `Pending` again (or `Failed` if `attempt_count ≥ max_attempts`)

The poll interval is adaptive — shorter when the queue is non-empty, longer when idle.

## Materialized Views

Materialized views are pegged to **specific commit nodes** in the transaction graph. This means:
- They never block or slow down ongoing transactions (they reference a past, stable state)
- They are updated in the background or lazily when accessed
- Each server maintains its own materialized views
- Large analytical queries can be distributed across neighboring servers
- The computation of a materialized view can be shared between neighbors (distribute the work, merge the results)

Views are just table definitions — the distinction between a "live" table and a "materialized view" is a storage hint, not a schema-level distinction.
