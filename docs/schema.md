# Schema Model

## Design Philosophy

DataCode schemas are closer to TutorialD than SQL. The core shift:
- A **table** is a named collection of typed tuples (no row ordering, no implicit keys unless declared)
- A **field** has a precise type with associated validation functors
- A **query/view** is indistinguishable from a table definition — both are views over the transaction graph
- There is **no NULL** — absent values are expressed as typed ADTs
- Tables are organized in a **namespace tree** (see namespaces.md) — namespaces replace the SQL "database" concept

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
  id        : DataId      [primary_key]
  email     : Email                       -- Email has a validation functor
  name      : Text
  status    : CustomerStatus              -- ADT: Active | Suspended | Closed
}

table Order {
  id          : DataId    [primary_key]
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

## Functor Types

DataCode has five functor kinds. All five are first-class schema objects — defined as rows in system tables, referenced by `FunctorRef`, and encoded in the GADT DSL (confirmed in `spikes/dynamic-loading/output.txt`).

| # | Kind | Signature | When it runs | Purpose |
|---|---|---|---|---|
| 1 | **Validation** | `a → Either Error a` | On commit | Rejects invalid field values (range checks, format checks, domain invariants) |
| 2 | **Foreign key** | `DataId → Either Error Row` | On commit | Referential integrity — resolves a DataId to a live row in the referenced table |
| 3 | **Path equivalence** | `(a, a) → Either Error ()` | On commit | Asserts that two schema-graph paths reach the same value (e.g. billing address matches order) |
| 4 | **Access control** | `(User, a) → Either Error a` | On read and write | Gates reads and writes based on the requesting user's identity and role; can redact individual fields |
| 5 | **Event** | `a → EventRef` | On commit | Schedules a deferred side effect — enqueues a work item in a DataCode queue table rather than executing immediately |

Functors 1–4 are synchronous and transactional: they run as part of the commit and can abort it. Functor 5 is asynchronous and decoupled: the commit always succeeds (inserting the queue row is the commit), and the side effect runs later under the event scheduler.

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

**Tag attachment**: Tags are attached to commits as part of a transaction (a tag is metadata on the commit node, not a side-table record). A tag, once written, is immutable — it permanently identifies the schema at a specific point in time. Semantic names (`v1.2.0`, `stable`) are the expected primary UX; the hash prefix exists as the canonical fallback.

**Creating and merging branches**: A new branch forks from an existing node and accumulates commits independently. When a branch is merged back, the merge commit records **two parent pointers** — one to the prior HEAD on the target branch and one to the tip of the incoming branch. The DAG permanently shows both lineages; there is no rebase and no history rewriting.

**Conflict resolution on merge**: Merge conflicts in both the schema and data graphs are resolved by defining a functor that reconciles the divergent schemas, then applying that functor to the affected data. The goal is for transparent functors to handle this automatically in the common case; manual resolution is reserved for cases the functor cannot express. The resolution functor is itself committed as a node in the schema graph.

**Orphaned branches**: A branch is orphaned when it has never been merged to `main` (or any branch that has been merged to `main`) and its continued development has been abandoned. Orphaned branches are the only case where the transaction graph is editable: an orphaned branch and all nodes exclusive to it may be deleted. A branch with any path to `main` (via merge) cannot be deleted.

**No-version routing**: Requests without a version token are routed to `main` HEAD by default. The server can also split unversioned traffic across named branches at a configurable rate for A/B testing; routing decisions persist via session affinity so the same client consistently receives the same branch. This makes local and A/B testing seamless without requiring clients to specify a version.

**Promoting a version**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch name the operator has promoted. The `/versions` discovery endpoint lists all live version tokens and marks the promoted one. Operators use this to signal "use this tag going forward" without requiring client code changes. Promotion state is stored in a system table and is itself versioned.

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

`DataId` replaces UUID as the primary key type for all DataCode-native tables and as the identity of transaction graph nodes.

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
- **User-visible**: the `DataId` primary key declared in the schema. Stable across mutations — same `DataId` throughout the row's lifetime.
- **Physical**: `RowId` — changes on every mutation, pointing to the newest version in the log.

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
  get_functor    : Maybe FunctorRef -- handler for GET, or NULL = method not allowed
  post_functor   : Maybe FunctorRef
  put_functor    : Maybe FunctorRef
  patch_functor  : Maybe FunctorRef
  delete_functor : Maybe FunctorRef
```

A `NULL` column means that HTTP method returns 405 on that route. A route with only `post_functor` set is a write-only endpoint.

Each referenced functor is an **API functor**: it receives the extracted path parameters and request body (if present), performs reads and/or writes within a single transaction, and returns a response value. Authentication and authorization apply automatically (see below).

Inserting or updating a row in `system.api.custom_routes` takes effect immediately — the WAI dispatch table is updated as part of committing the transaction, with no server restart.

### Authentication and Authorization

**Authentication** is always on. Every request to any route — auto-generated or custom — must carry a valid client token and user token. There is no mechanism to create an unauthenticated DataCode endpoint.

**Authorization** is automatic and derived from the access control functors on the tables the API functor accesses. No per-route permission declaration exists: if the functor reads `app.commerce.orders`, the same access control functors apply as if the caller had queried that table directly. A custom functor that reads multiple tables must satisfy the access control functors on all of them.

### HTTP Dispatch

All routes — auto-generated and custom — are materialized from the system tables into a runtime WAI dispatch table (an IORef-backed route trie, as confirmed by the Servant+Warp spike). The Servant frame handles the static URL structure; the dispatch table handles the versioned and dynamic portions. Route templates are compiled into path-matchers at registration time; path parameters are extracted at request time and passed to the functor.

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
  id          : DataId        [primary_key]
  recipient   : Email
  template    : EmailTemplate
  payload     : JsonObject
  [event_functor: system.connectors.email.SendFunctor]
}

table app.events.webhook_queue {
  id          : DataId        [primary_key]
  destination : URL
  body        : JsonObject
  [event_functor: system.connectors.http.PostFunctor]
}
```

The `event_functor` attribute links the queue table to the connector functor that knows how to process it. When the scheduler dequeues a row, it calls that functor with the row as input.

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
system.events.queues
  name         : Text         -- queue name (e.g. "app.events.email_queue")
  handler_ref  : FunctorRef   -- functor that processes items from this queue
  max_attempts : Int          -- retry limit before marking Failed
  backoff_base : Duration     -- base duration for exponential backoff

system.events.items
  id            : DataId      [primary_key]
  queue_name    : Text
  payload       : Bytes       -- serialized row snapshot at enqueue time
  scheduled_at  : Timestamp   -- not-before time (set by backoff logic)
  attempt_count : Int
  last_error    : Maybe Text
  status        : EventStatus -- Pending | InFlight | Failed | Done

system.events.backoff_state
  destination   : Text        -- endpoint or queue identifier
  failure_rate  : Decimal     -- rolling failure rate (recent window)
  volume_count  : Int         -- events dispatched in current window
  backoff_until : Timestamp   -- do not dispatch until this time
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

1. Polls `system.events.items` for rows with `status = Pending` and `scheduled_at ≤ now`
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
