# Connectors and external data ingestion

## Overview

DataCode ingests data from external sources and maintains bidirectional sync with them. The
connector system is the bridge between DataCode's category-theoretic internal model and the
messier reality of external databases, APIs, and services.

**Design principles:**

- All connector configuration lives in DataCode system tables. There are no config files, and no
  restart for a configuration change.
- DataCode tends toward being the system of record — most information, all business rules encoded
  as functors — but authority is tunable per connector.
- Bidirectionality is enforced within DataCode. For replication and polling connectors the source
  needs no DataCode-specific configuration at all. Webhook and hybrid connectors require the source
  to be pointed at a DataCode endpoint, and nothing beyond that endpoint and its signing secret is
  DataCode-specific.
- A connector **kind** is a handler, and handlers are compiled-in Haskell. A new kind therefore
  ships as a new handler generation: a build, then a generation swap on the handler pool alone,
  with no restart and no interruption to the data workers. A new connector **instance** of an
  existing kind is a row. See [dynamic-loading.md](dynamic-loading.md#generation-swap).
- Auto-discovered external schemas live in their own namespace and can be layered over by
  human-managed schemas.

The fourth principle replaces "new connector types can be added without restart if no new Haskell
packages are required, and new packages require a server reboot". That was written under the
abandoned `hint` model, and both halves of it are wrong now: no connector kind is loadable at
runtime regardless of packages, and none of them needs a reboot either (OQ-001).

---

## Connector kinds

### MariaDB and MySQL

**Required replication source, row-based.** MariaDB is the required source; MySQL is supported
alongside it.

**One kind, not two.** Everything downstream of the replication position is identical between the
two products, so the difference is a per-connector **dialect** rather than a second connector kind.
A second kind would have duplicated the log, the conflict record, the shadow schema, and the
handler, to record one field.

**Library**: `mysql-haskell` 1.3.0 (`Database.MySQL.BinLog`) — actively maintained, pure Haskell,
no FFI. DataCode connects as a pseudo-replica and decodes each event into Write, Delete, and Update
variants. Only row-based replication is supported (`binlog_format=ROW` on the source).

`mysql-haskell` exposes **no GTID support**: `BinLogTracker` is filename-plus-offset and there is
no `COM_BINLOG_DUMP_GTID`. Neither dialect needs a fork. `Database.MySQL.Connection` is an exposed
module with `MySQLConn(..)`, `writeCommand` and `putToPacket`, so both handshakes are reachable
against the published API in roughly 150 lines.

#### Two GTID dialects, selected per connector

The two schemes are mutually unintelligible, and the difference is not cosmetic:

| | MariaDB | MySQL |
|---|---|---|
| Position | `domain_id-server_id-sequence`, one per domain | `source_uuid:interval-list`, a GTID **set** |
| Handshake | session variables (`@slave_connect_state`, `@mariadb_slave_capability`), then `COM_BINLOG_DUMP` | `COM_BINLOG_DUMP_GTID`, carrying the set in the packet body |
| Gaps | not representable — a domain has one high-water mark | representable, and normal |

**The stored position is a set of rows, not a scalar.** One row per source — a MariaDB `domain_id`
or a MySQL `source_uuid` — carrying that source's high-water mark:

```
table system.connectors.Position : Configuration {
  connector  :> Connector,
  source     : Text,
  high_water : Int,
  applied    :> AppliedRange : Component { first : Int, last : Int },
  unique positionRef { connector, source }
}
```

`applied` is table-valued, because a `:>` whose target carries `Component` denotes every one of
that parent's rows ([tables.md](schema/tables.md#a-component-reference-is-table-valued)). It is
empty under MariaDB, where a gap cannot be represented and the high-water mark says everything.
Under MySQL it carries the interval set, because a single high-water mark is lossy the moment a gap
exists — and that is the one place the dialect difference reaches past the position row.

The position is written **per processed batch**, never per event: every write appends a version,
and a per-event checkpoint would append one per source row.

#### Detect and verify the dialect, do not only configure it

`@@gtid_mode`, `@@gtid_current_pos` and `@@version_comment` distinguish the two dialects at connect
time. The `dialect` field on the connector row is `Detect` by default, which adopts what the source
reports. A named dialect is **checked** against it, and a mismatch refuses to stream. Configuring a
dialect and never checking it means a misconfiguration replicates from the wrong position silently,
which is the failure that is hardest to see from the outside.

#### GTID is an optimization, not a correctness prerequisite

GTID buys cheap resumption, failover to a different source without recomputing the position, gap
detection, and idempotent re-apply — a replica that has already applied a GTID ignores a repeat,
which is what makes a redelivered transaction a no-op rather than a duplicate. A (filename, offset)
pair buys none of that. It is meaningful only relative to one server's binlog sequence, so after a
source failover, a restore from backup, or a purge of rotated logs it names nothing on the new
source and resumption either fails or silently resumes in the wrong place.

**A source that cannot enable GTID is not disqualified.** It gets filename-plus-offset and a
re-seed whenever the position is in doubt. This reorders the work: build the re-seed path first —
it is needed for initial load regardless — and land GTID on top of it. It replaces the earlier
framing, under which GTID was a prerequisite and a non-GTID source was out of scope.

#### `binlog_row_image=FULL` is not required

Under `MINIMAL` an `INSERT` still logs every column, because the statement changes all of them; an
`UPDATE` logs the primary key plus the changed columns; a `DELETE` logs the primary key. That is
enough to locate and apply, **provided the shadow table keeps the source primary key as its
candidate key** — which [schema auto-discovery](#schema-auto-discovery) already requires, since a
candidate key is the lookup path. The only thing lost is the prior value of unchanged columns, and
DataCode already stores that.

This replaces the claim that `MINIMAL` forfeits the rooted-key shadow, which was wrong. It is
load-bearing, so confirm it against a real source before writing code against it.

#### Source setup

Source configuration is a file change and a restart, not `SET GLOBAL`. `binlog_format=ROW` does not
persist across a restart and has no effect unless `log_bin` is on, which is a restart-only option,
and a pseudo-replica cannot register without a distinct `server_id`.

```sql
-- my.cnf on the source, then restart
log_bin       = ON
binlog_format = ROW
server_id     = 1
-- MySQL only; MariaDB records GTIDs unconditionally
gtid_mode                 = ON
enforce_gtid_consistency  = ON
```

```sql
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'datacode'@'connector.example.com';
```

`REPLICATION CLIENT` (`BINLOG MONITOR` on MariaDB 10.5 and later) is what `SHOW MASTER STATUS`
needs, and position discovery issues it. Scope the grant to the connector host rather than `'%'`:
the credential can read every write on the server, so a host wildcard extends that to anyone who
obtains it.

#### A connector needs a seed

An empty arrival log yields no position at all, so without an explicit origin a connector cannot be
started, re-seeded, or recovered from a source purge. The `origin` field records which it was:

| Variant | Means |
|---|---|
| `Streamed` | The position came from the stream itself, from first connect onward. |
| `Snapshot` | The position came from the initial load. |
| `Reseeded Text` | The position came from a recovery re-seed; the payload records why. |

#### Re-seed from state is the recovery path

**Re-seeding from current state is sound**, and both products supply the consistent pair it needs
without a global lock: `START TRANSACTION WITH CONSISTENT SNAPSHOT` alongside `gtid_executed`
(MySQL) or `@@gtid_current_pos` (MariaDB) on InnoDB. After an outage the connector snapshots,
records the position it snapshotted at, and resumes — discarding the gap rather than replaying it.

Three properties the model needs, each easy to miss:

- **A re-seed is a diff-and-apply, not a rewrite.** Re-applying a snapshot blindly writes one new
  row version per source row into an append-only graph, including for rows that did not change.
  Compare each incoming row against the stored one and write a version only where they differ. The
  comparison is a keyed lookup on the shadow's candidate key, and it keeps the version chain an
  account of actual changes rather than an account of outages.
- **The snapshot must be complete per table, or deletes leak.** A row deleted at the source during
  the outage is absent from the snapshot, so present-locally-and-absent-from-the-snapshot is
  the only signal that it went. A snapshot may cover one table of many; within a table it is all
  rows or none.
- **A re-seed loses intervening event-functor firings**, which is a larger cost than "audit
  history" suggests. An order that went `Pending → Shipped → Delivered` during the gap re-seeds as
  `Delivered`, so `on status is Shipped emit` never fires and the shipping notifications never go
  out. "Send the notifications we missed" and "do not send four thousand emails" are both
  legitimate and only the deployment knows which, so a re-seed is a **distinguished transaction
  kind**, and whether it fires event functors is a per-queue `Configuration` choice on
  `system.events.QueuePolicy`.

### PostgreSQL

**Not doing.** Nice-to-have, deprioritized in favour of MariaDB and MySQL. The available library
(`postgresql-replicant`) was abandoned in 2021 and would need a fork or a rewrite, which is not
worth the investment for v1 given the company's predominant use of MariaDB and MySQL. Revisit
post-v1 if there is demand.

### Redis

**Not doing.** Nice-to-have, deprioritized. No Haskell library exists for the PSYNC replication
protocol, and the Redis Streams CDC approach requires changes on the Redis source side, so it is
not transparent. Not worth the complexity for v1. Revisit post-v1 if needed.

### Web API connectors

Web APIs have no change stream equivalent to a database binlog. Each API needs a custom connector,
and DataCode provides tooling to make that easier.

**Supported patterns:**

| Pattern | Mechanism | Bidirectionality |
|---|---|---|
| Webhook ingestion | The API calls DataCode; DataCode records the event | Inbound only; outbound through API calls |
| Polling | DataCode polls the API on a schedule | Both directions, through read and write calls |
| Hybrid (for example Stripe) | Webhooks for real time, plus batch reconciliation for drift detection | Full |

**Example — Stripe:**

- Inbound, real time: Stripe sends webhooks to DataCode's webhook endpoint. DataCode validates the
  signature, then records the event in the connector log.
- Outbound: DataCode calls the Stripe API when DataCode-side changes need to propagate.
- Drift detection: Stripe Sigma queries — themselves delayed by hours to days — run on the
  verification schedule and are compared against the connector log for the same window.
- Latency window: configurable per connector. Stripe Sigma wants 48 hours.

Web API connectors are not auto-generated; each API needs custom mapping work. Tooling to
accelerate that is out of scope for this document.

---

## Sync protocol

### Transaction log mapping

DataCode maintains a **connector log** alongside its own transaction graph, one entry per external
event:

```
table system.connectors.LogEntry : LogData {
  connector      :> Connector,
  external_seq   : Text,
  external_time  : Timestamp,
  operation      : Insert | Update | Delete | StateCheck,
  external_table : Text,
  external_key   : Text,
  payload        : Doc,
  signature      : Text | NotSigned = NotSigned,
  scrubbed       : Bool = False,
  outcome        : Applied | Held | Skipped,
  applied_txn    : DataId | NotApplied = NotApplied
}
```

`applied_txn` names the DataCode transaction node the event landed in. `external_seq` is the
source's own position — a GTID, a stream ID, a webhook delivery id — kept as `Text` because the
dialects disagree about its shape and this column is evidence rather than a lookup path.

**`LogEntry` is append-only, like every other `LogData` table.** `outcome` is written once, in the
transaction that applies or holds the event, and nothing later mutates it. The earlier draft
carried a mutable `sync_status` column, which would have made this a further exemption from
append-only where the design has exactly one: the `QueueState` field on a `Queue` table
([traits.md](schema/traits.md#queue-and-queuestate)). A held event's resolution is a **new** row in
the tables below, not an edit here.

These declarations were previously a pseudo-schema using `UUID`, `UUID?`, `Enum(...)` and
`latency_window_ms Int`. Each is replaced by the thing DataCode already has: `DataId` for an
identifier, an alternation with a typed absence variant for `?` — the nullable marker is exactly
what [No NULL](vision.md) abolishes — `A | B` for a sum type, and `Duration` for a length of time,
so a millisecond count is never smuggled into an `Int`.

`payload` is a `Doc` ([documents.md](schema/documents.md)) rather than an opaque blob or a JSON
column, so the shredded, queryable form is a materialized view over the stored bytes, requested per
field with `indexed`.

**Verification and storage are separate steps, and they have to be.** The HMAC is verified at
ingest against the **in-memory** body exactly as delivered, because that is what the signature
covers. What is *written* is the scrubbed form: the scrub matcher runs over document keys before
the frame is written, and for connector payloads and HTTP request logs that is the primary defence
rather than a backstop ([integrity.md](integrity.md#three-layers-in-order-of-preference)). The
signature header is recorded beside the payload and `scrubbed` records whether a rule matched.

> A stored payload is not byte-identical to the delivery whenever a scrub rule matched, so
> re-verifying a stored payload is impossible by design.

That replaces "the received bytes are stored verbatim", which governed the same bytes as the scrub
rule and demanded the opposite of them. A delivery whose signature does not verify is rejected at
the route and never reaches the log at all.

**Where the signing secret lives.** An HMAC secret must be reproduced, so it is `Encrypted`, and
`reveal` runs in `Effect` while the route functor that performs the insert runs in `Tx`. The
resolution is the arrangement [auth.md](auth.md#envelope-encryption-and-key-custody) already
describes: the server unwraps the data key **once at startup** in `Effect` and holds it in process
memory, so verification is a cached-key computation making no external call. The `Effect` rung is
on the `unwrap`, not on the HMAC. Inbound verification is therefore a **third** consumer of a
reversible secret where OQ-037 records two, and the one on the write path; its conclusion that no
cipher sits on the read path is unaffected. Recorded under OQ-020.

The two logs are mapped together through the shadow table's candidate key, which is the source's
primary key. `external_key` resolves to a shadow row by lookup, and to an application row through
the overlay binding over it. That gives full visibility into both sides' mutation history for one
entity without a separate mapping table.

### Conflict resolution

Conflicts arise when both DataCode and the external source have mutations for the same entity
between sync windows. Resolution priority, in order:

1. **Semantic resolution** (preferred). A connector mapping may declare a merge function per table,
   `Row t -> Row t -> Row t`, which must be **associative, commutative, and idempotent** — the same
   obligation [aggregates.md](schema/aggregates.md#aggregates-in-a-chain-must-merge) imposes on a
   chain merge, and for the same reason: the outcome must not depend on the order the two sides are
   compared, or on how many times a redelivered event is applied. It runs in `Effect`, in the
   handler pool. If DataCode and Stripe both carry "order status changed to `Shipped`" with
   different timestamps and identical semantics, the merge is idempotent on that field and there is
   no conflict to resolve. Naming the algebra is what makes this tier checkable; "the sequence of
   mutations is logically consistent" on its own has no interface, no signature, and no effect rung.

2. **Version-vector dominance.** Each side carries a vector: DataCode's is its per-shard
   transaction sequence, the source's is its GTID set. One side wins when its vector dominates the
   other componentwise. Where neither dominates, the writes are genuinely concurrent and this tier
   declines rather than guessing. This replaces "if one side's mutations are a strict prefix of the
   other side's, the longer sequence wins", which presupposed a common identity and ordering across
   two independently sequenced logs — the thing tier 1's own example defeats, since semantically
   identical events with different timestamps and payloads are not a syntactic prefix of anything.

3. **Timestamp last-write-wins** (last resort). Three things travel with it rather than being left
   implicit: it **loses a write**; `external_time` is the **source's** clock and is untrusted; and
   it is correct only within a clock-skew bound that the deployment states and nothing enforces. It
   is configurable and can be disabled in favour of alerting, which is the setting to choose for
   any table where losing a write matters. It does not breach *time is a parameter, never ambient*:
   it runs in `Effect` in the handler pool and compares two **stored** timestamps, so no functor
   samples a clock.

4. **Manual resolution.** What none of the above resolves is recorded as a conflict for operator
   review, and the event is held rather than applied.

The authority model is tunable per connector, on the `authority` field:

| Value | On an unresolvable conflict |
|---|---|
| `DataCode` | DataCode's version wins; the external system is updated |
| `External` | The external version wins; DataCode records the override |
| `Symmetric` | The full protocol above (default) |

`DataCode` and `External` are ordinary variant names. They were reserved words until the CLI's
`Resolution` production stopped naming them literally, which had made this very field unlexable —
see [railroad.md](schema/railroad.md#administration).

#### The checkpoint advances; a held event is a conflict row

**The checkpoint advances past a held event.** It has to: a connector that stops at the first
conflict is precisely the outage the `monitor` default exists to prevent, and the backlog would
grow until someone noticed. The held event stays in the log with `outcome = Held`, and a conflict
is recorded against it:

```
table system.connectors.WorkState : QueueState { }

table system.connectors.Conflict : LogData {
  connector     :> Connector,
  entry         :> LogEntry,
  local_subject : DataId | NotFound = NotFound,
  tier          : Semantic | Sequence | LastWrite | Unresolved
}

table system.connectors.Resolution : Queue {
  subject :> Conflict,
  choice  : DataCode | External | Merged,
  merged  : Doc | NotMerged = NotMerged,
  state   :> WorkState = Requested,

  handler system.connectors.applyResolution
}
```

`WorkState` inherits `name` and `disposition` from [`QueueState`](schema/traits.md#queue-and-queuestate)
and holds four rows — `Requested` (`Pending`), `Running` (`InFlight`), `Done` (`Done`), and
`Failed` (`Failed`). One state table serves every connector queue, because the dispositions are the
same four and a second would only repeat them.

`Resolution.subject` follows the naming `system.integrity.Violation` and `system.events.TriggerState`
already use for the row a record is about.

**A conflict carries no resolved flag**, because the flag is derivable: the open set is the
`Conflict` rows no `Resolution` names, which is an ordinary absence query. Storing the state on the
conflict row would mean either a second source of truth for a derivable fact, or a mutable column
on a `LogData` table — and the one append-only exemption in the design is the `QueueState` field on
a `Queue`, which `Resolution` is and `Conflict` is not.

`resolve conflict "…" using …` therefore **inserts** a `Resolution` row; the identifier it names is
a `Conflict` row's, and `show connector conflicts <connector>` reads the open set. The handler
applies the choice: it writes through the overlay in `Tx` and lets the outbound loop push the
result, so resolving a conflict uses the same propagation path as any other DataCode-side change.
A `merge { … }` resolution records the supplied row in `merged` and applies it the same way.

**The replay rule.** On resolution the event is applied as a **new mutation at the current graph
point**, never reinserted at its original position. Per-row ordering is therefore lost for held
events: three binlog events for one row, the second held and later resolved, apply in the order 1,
3, 2. Binlog events for one row are order-dependent, so this is a correctness question rather than
a tidiness one, and the answer is a per-connector choice on `conflict_action`:

| Value | Behaviour |
|---|---|
| `Auto` | Resolve without review wherever the tiers can; hold the rest |
| `Alert` | Hold and notify (default) |
| `Halt` | Stop the connector at the conflict, preserving per-row order at the cost of the backlog |

### Nonconforming external data

Conflicts are about two systems disagreeing. This is the separate problem of an external system
sending something that is internally valid *there* and invalid *here* — a malformed email, a
negative amount, a status code you have never seen. Data integrity problems in systems you do not
control are not an exceptional case; they are the normal case.

**Rules applied over connector-sourced data default to `monitor`, never to `enforce`.**

This is not a preference. A commit that fails on a MariaDB binlog event stops the connector at that
offset and it never advances — one malformed row halts replication for the entire connector, and
the backlog grows until someone notices. On the webhook side a rejected commit becomes a delivery
failure, then a retry, then a retry storm at the source, and eventually a disabled endpoint. In
both cases enforcement converts a data problem into an outage.

Under `monitor` the row lands, the violation is recorded against the functor it broke, and the pipe
keeps moving. See [integrity.md](integrity.md#ingestion-must-not-enforce).

Unknown code values are handled the same way and land in the same queue. If the target `Reference`
table carries the `Extensible` trait, the connector issues a schema transaction adding the variant
and records which connector and token did it; if it does not, the value is recorded as a violation.
See [traits.md](schema/traits.md#extensible).

The connector conflict queue and the integrity violation queue are one review surface; the argument
for that, and the operator-facing shape of it, are in
[integrity.md](integrity.md#reporting-and-administration).

### State verification

Replication channels break. DataCode verifies sync correctness by comparing live state against the
external system on a schedule, independently of the log:

1. **Verification schedule** — `verify_interval` on the connector row. Six hours for Stripe Sigma,
   five minutes for MariaDB.
2. **State snapshot** — DataCode fetches the current state of a sample or full set of entities from
   the source.
3. **Comparison** — against DataCode's current materialized state for the same entities. Each
   comparison is recorded as a `StateCheck` entry in the log.
4. **Discrepancy handling** — discrepancies younger than the connector's **latency window** are
   ignored, because the sync channel may be behind. Older ones raise a conflict.

### Latency windows

Every connector has a latency window: the expected maximum delay between a mutation at the source
and its appearance in DataCode, or the reverse. It is a `Duration` on the connector row, and its
only job is to suppress discrepancy handling — `latency_window = 48 hour` for Stripe, because Sigma
data can lag webhooks by up to two days.

**The window and the verification schedule are two knobs, not one.** An earlier draft drove
verification off `latency_window`, which verified Stripe twice a week instead of every six hours
and MariaDB every five seconds instead of every five minutes. They answer different questions —
"how stale may this be before I care" and "how often do I look" — so they are separate fields.

---

## Schema auto-discovery

When a connector is added, DataCode introspects the external source's schema:

1. **Auto-generated shadow schema.** Created in a dedicated namespace — `connectors.<kind>.<name>`,
   so a `mariadb` connector named `production` lands under `connectors.mariadb.production`. It
   holds DataCode table declarations mirroring the external schema, mapped by the table below.
2. **Schema change tracking.** The connector watches for external schema changes — new columns,
   type changes, dropped tables — and updates the shadow schema. Each change is a new node in the
   schema transaction graph.
3. **Human-managed overlay.** You declare your own namespace (`app.commerce`) with bindings over
   the generated one. That is where DataCode-native types, renamed fields, ADTs replacing nullable
   columns, and access control functors live.
4. **Visibility.** Generated schemas are `connector` visibility, which hides them from the default
   IDE view. See [evolution.md](schema/evolution.md#set-visibility) and [ide.md](ide.md).
5. **Backwards compatibility.** Because every schema version lives in the transaction graph, old
   queries against the generated schema keep working as the external schema evolves.

### The type mapping

"The closest DataCode equivalent" is not a specification, and this is the first thing an
implementer of the required v1 connector has to write:

| Source type | Shadow type | Notes |
|---|---|---|
| `TINYINT(1)`, `BOOLEAN` | `Bool` | |
| `TINYINT` … `BIGINT`, signed | `Int` | |
| unsigned integers | `Int where \n -> n >= 0` | `BIGINT UNSIGNED` exceeds a signed 64-bit range, so it maps to `Decimal` unless `Int` is confirmed wider |
| `DECIMAL(p,s)`, `NUMERIC` | `Decimal` | precision and scale ride as a `where` predicate, not as type arguments, for the reason [types.md](schema/types.md#length-is-a-predicate-not-a-type-argument) gives for length |
| `FLOAT`, `DOUBLE` | `Decimal` | converted through the source's textual rendering. A value that does not round-trip is a violation, not a silent approximation |
| `CHAR`, `VARCHAR(n)`, `TEXT` | `Text where maxLen n` | both count code points, so the cap means the same thing on both sides |
| a case-insensitive collation | `Canonical Text using system.text.Policy.<collation>` | folding is a storage transform, so `==` and `unique` stay ordinary. See [types.md](schema/types.md#canonical-types) |
| `BINARY`, `VARBINARY`, `BLOB` | `Bytes`, or `File` above the size cap | |
| `DATE` | `Date` | |
| `DATETIME`, `TIMESTAMP` | `Timestamp` | `DATETIME` carries no zone; the connector records the source's `time_zone` at connect and converts with it |
| zero dates (`0000-00-00`) | `Date \| NotGiven`, reading `NotGiven` | there is no such date. It is MySQL's NULL under another spelling |
| `ENUM` | a generated `Reference` table plus a `:>` | `Extensible` only where the source's value set is expected to grow; otherwise an unseen value is a violation |
| `SET` | a `Component` sub-table, one row per member | there is no list type |
| `JSON` | `Doc` | |
| a nullable column | `T \| NotGiven` | |
| no primary key | `Keyless`, plus a violation | see [integrity.md](integrity.md#connector-tables-without-a-source-key) |

Two rules travel with the table:

- **A nullable column maps to `T | NotGiven`**, with the base type as the head of the alternation
  ([types.md](schema/types.md#absence-types)). The shadow cannot say more than "the source did not
  supply this". The overlay is where `NotGiven` narrows to a domain-specific absence — `NotFound`,
  `Redacted`, `NotDispatched` — and that narrowing is a projection over the shadow column, so both
  types stay readable.
- **The shadow's candidate key is the source's primary key.** That is what makes the key
  declaration also the sharding declaration for the shadow, and it is the lookup path that
  `binlog_row_image=MINIMAL` and the re-seed diff both depend on. Where the source has no primary
  key there is nothing to declare, so the shadow carries [`Keyless`](schema/traits.md#keyless) and
  the connector writes a violation recording why.

### An added column is a generated add

A new column at the source is a field added to an existing table, so it obeys the added-field rule
in [evolution.md](schema/evolution.md#every-added-field-declares-a-default) — generators are bound
by it exactly as authors are, and a shadow namespace is not exempt.

**The connector reads the default off the source DDL**: the column's own `DEFAULT` where there is
one, else `| NotGiven = NotGiven`. A default chosen for tidiness rather than read off the source
turns one DDL statement into a full-table discrepancy at the next verification tick, because every
existing row then reads a value the source never had.

Whether an added shadow column propagates into an overlay binding that projects named columns is
the half of OQ-025 that is still open.

---

## Dynamic configuration

All connector configuration is stored in DataCode system tables. Adding or modifying a connector
does not require a restart:

- **A new connector instance** of an existing kind — a second MariaDB database, say — is an insert
  into `system.connectors.Connector`. The scheduler picks up its `every` declarations on the next
  tick.
- **A configuration change** — endpoint, latency window, authority model — is a row update, and
  takes effect on the next sync cycle.
- **A new connector kind** is a new handler: a build, then a generation swap on the handler pool
  alone. The data workers are untouched and nothing restarts. See
  [dynamic-loading.md](dynamic-loading.md#generation-swap).

### The connector row

```
table system.connectors.Connector : Configuration {
  name            : Text unique,
  kind            :> ConnectorKind,
  endpoint        : Text,
  identity        :> system.auth.ServiceAccount,
  dialect         : MariaDb | MySql | Detect = Detect,
  origin          : Streamed | Snapshot | Reseeded Text = Snapshot,
  poll_interval   : Duration = 10 second,
  push_interval   : Duration = 10 second,
  verify_interval : Duration = 5 minute,
  latency_window  : Duration = 5 minute,
  timeout         : Duration = 30 second,
  authority       : DataCode | External | Symmetric = Symmetric,
  conflict_action : Auto | Alert | Halt = Alert,
  enabled         : Bool = True,

  every poll_interval emit system.connectors.SyncQueue { connector = self, work = Sync }
    where enabled && kind.polls,
  every push_interval emit system.connectors.SyncQueue { connector = self, work = Push }
    where enabled && authority is not External,
  every verify_interval emit system.connectors.SyncQueue { connector = self, work = Verify }
    where enabled
}

table system.connectors.ConnectorKind : Reference {
  name   : Text unique,
  polls  : Bool,
  driver :> system.events.Handler
}
```

`ConnectorKind` is the `system.events.Handler` bridge reused: the row records a fact that
originates outside the schema graph — that a compiled-in handler by that name exists — which is
exactly when a `Reference` table is warranted ([events.md](events.md#system-tables)). Its `name` is
the namespace segment the shadow schema lands under, so `mariadb` and
`connectors.mariadb.production` are the same word by construction. `polls` is what tells a polling
kind from a streaming one, and it is read by the `every` declarations above.

**Retry policy is deliberately absent.** It is a `system.events.QueuePolicy` row, one place for
every queue, and a `max_retry_attempts` column here would have been a second authority for it.

**The credential is not on this row either.** `identity` names a service account — an ordinary
`system.auth.User` reached through the `ServiceAccount` binding (OQ-015) — and the secret is a
`Credential` row against that account: an `ApiKey`-method row for a token the source presents to
DataCode, an `Encrypted` type where the server must reproduce one (a replication password, a webhook
signing secret), reached by `reveal` in the handler pool. That replaces three incompatible homes —
an environment variable named by a `password_env` column, which is the config file the first design
principle rules out; a plain `Configuration` column; and OQ-019's "credentials come from a
`Configuration` row". The `Configuration` row names the identity, and the identity holds the
secret. See [auth.md](auth.md#service-accounts) and [types.md](schema/types.md#encrypted-types).

That foreign key crosses shards — the connector row is replicated everywhere, the account lives in
its user's shard — so it carries the ordinary cross-shard-edge warning at schema commit. See
[constraints.md](schema/constraints.md#anchoring).

### Polling is a scheduled event

A connector's loops are `every` declarations on the connector row, dispatched by the one event
scheduler ([events.md](events.md#one-scheduler)). There is no separate connector scheduler, and no
connector daemon in either sense (OQ-019).

`every`'s interval is an expression, so the three intervals above are ordinary fields of a
`Configuration` row — retuning any of them is a data write with no schema commit, which is what
this section already promised, now with nothing bespoke behind it. Two schedulers would have meant
two retry policies, two backoff states, and no way to reason about total outbound load.

The three loops share one queue rather than one queue each, because they share a handler, a retry
policy and a worker pool; `work` is what the handler dispatches on:

```
table system.connectors.SyncQueue : Queue {
  connector :> Connector,
  work      : Sync | Push | Verify | Reseed,
  state     :> WorkState = Requested,

  handler system.connectors.runSync
}
```

`Reseed` has no `every` behind it: it is enqueued by an operator, or by the supervisor when the
stored position is no longer resumable at the source.

`where enabled` here is a **row filter**, not a sampled condition: it restricts which connector
rows are sampled, and the trigger fires each interval for every matching row. Read as a sampled
condition it would fire once, at the first `False` → `True` transition of a field that is `True`
continuously, and the connector would poll exactly once and stop. The rule that tells the two
readings apart is in [events.md](events.md#every--sampling-for-a-transition).

Inbound webhook traffic is not scheduled at all. A webhook is a route whose functor inserts into a
landing table — see [events.md](events.md#the-event-system-is-outbound).

### Streaming is a supervised handler

A binlog fits neither shape above: there is nothing to poll, and nothing calls in. The connector
holds a socket open and consumes what arrives, so a **streaming** connector is a long-lived
supervised handler in the handler pool ([dynamic-loading.md](dynamic-loading.md#handler-workers-are-a-separate-pool)),
whose lifetime is the connection rather than one work item. Three rules follow, none of them new
machinery:

- The position is written **per processed batch**, so a restart replays at most one batch. Under
  GTID the re-apply is idempotent; without it the batch is a diff-and-apply against the shadow's
  candidate key, which is idempotent for the same reason a re-seed is.
- On a **generation swap** the new generation opens its own connection and resumes from the stored
  position while the old one drains and closes.
- Liveness is the connector's own concern. A stream that has delivered nothing for longer than the
  latency window raises a violation against the connector rather than idling silently.

`kind.polls` is what decides which shape a connector gets: a polling kind gets the `every` loops, a
streaming kind gets a supervisor.

### Outbound propagation is derived, not triggered

A DataCode-side change cannot call an external API inside the commit, because no external call
happens inside a commit. So propagation is work found *after* the fact, and the source for it
already exists: the transaction graph is the audit log
([events.md](events.md#internal-effects-are-derived-not-triggered)). The outbound worker asks what
changed in the mapped tables since its own cursor and pushes that. The cursor needs no new table —
it is a `system.connectors.Position` row per shard, with the shard as the `source` and its
transaction sequence as the high-water mark.

**`on … emit` is the wrong shape here**, and it is worth saying why, because it is the obvious
first idea. `on` fires on a `False` → `True` transition of a *condition*
([events.md](events.md#on--firing-is-a-false-to-true-transition)); "this row was written" is not a
condition, so "propagate every change to this table" has no `on` spelling at all. Generating one
`on … emit` per mapped table per connector would also put connector-specific declarations on every
user table, which every later redeclaration would then have to keep consistent.

---

## Known library status

| Source | Library | Status | Action |
|---|---|---|---|
| MariaDB / MySQL | `mysql-haskell` 1.3.0, `Database.MySQL.BinLog` | Active, Stackage Nightly. No GTID support. | **Required.** Use it for the row decode; speak both GTID handshakes through `Database.MySQL.Connection`, with no fork |
| PostgreSQL | `postgresql-replicant` 0.2.0.1 | Abandoned 2021 | **Not doing** (post-v1 if demand) |
| Redis | none | No PSYNC library exists | **Not doing** (post-v1 if demand) |
| Web APIs | custom per API | — | Build tooling; no universal library |

---

## Open questions

See [open-questions.md](open-questions.md):

- **OQ-019 — connector worker-pool topology.** Narrowed and answered in the large: there is no
  connector daemon, polling is a scheduled event, and the workers are the handler pool.
- **OQ-020 — webhook endpoint security.** Now carries the cached-key decision above.
- **OQ-025 — connector schema change propagation.** The shadow-side rule is settled here; overlay
  propagation for a binding that projects named columns is what remains.

OQ-017 (PostgreSQL) and OQ-018 (Redis) are not doing for v1.
