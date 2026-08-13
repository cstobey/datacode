# Transaction Graph

The append-only DAG that holds all data and all schema. This document covers its structure,
the version references that name points within it, shards, and the identifier types. For
the physical on-disk representation see [storage.md](storage.md); for the schema syntax
that produces graph nodes see [schema/evolution.md](schema/evolution.md).

## Structure

The transaction graph is an **immutable, append-only directed acyclic graph** (a git-like
commit DAG). Each node records:

- A `DataId` — globally unique 12-byte identifier; timestamp and server identity are encoded within it
- A sequence number within its shard
- A pointer to the schema graph node that was current at commit time
- The set of mutations applied (inserts, deletes — no in-place updates)

Records are **idempotent** — applying the same transaction twice produces the same state.
Records are **never mutated retroactively**.

## Schema Transaction Graph

The schema itself is stored in the same transaction graph structure (in the `system`
shard). Every schema change — adding a table, adding a field, defining a new functor — is a
commit in the schema graph. This means:

- Every data record implicitly references a schema graph node ("this data was valid under schema version X")
- The full history of schema evolution is queryable
- Rollback is reading from an earlier graph node, not undoing changes

## Branches, Tags, and Version Tokens

The transaction graph supports three kinds of named references, all of which are valid
version tokens in API paths (`/v{token}/records/...`) and in the query `at` clause:

| Token type | Moves? | Example | Resolves to |
|---|---|---|---|
| **Graph node hash prefix** | Never | `a3f9c2b` | Itself — canonical, content-addressed |
| **Tag** | Never | `v2.1.0`, `stable-2026-q2` | The specific node the tag was attached to |
| **Branch name** | Yes (HEAD advances) | `main`, `experiment-checkout` | Current HEAD of that branch |

All three resolve at dispatch time to a schema graph node hash, which then selects the route
set registered at that node. The hash prefix is the lowest-level escape hatch — it works
even when no tag or branch name has been declared.

**Branch policy**: All branches must be explicitly named. Anonymous DAG forks are not
permitted — creating a divergent commit requires naming the branch first. The `main` branch
cannot be deleted.

**Tag attachment**: Tags are rows in `system.VersionRef`, inserted as part of a
transaction. A tag, once written, is immutable — it permanently identifies the schema at a
specific point in time. Semantic names (`v1.2.0`, `stable`) are the expected primary UX; the
hash prefix exists as the canonical fallback.

**Version ref storage**: Branches and tags share a single system table. The `VersionRef` ADT
encodes the mutability difference directly in the type — no discriminator column needed:

```haskell
data VersionRef
  = Branch DataId    -- mutable: HEAD pointer advances as commits land on this branch
  | Tag    DataId    -- immutable: permanently pinned to one schema node
```

```
table system.VersionRef {
  name : Text unique,   -- unique across all branches and tags
  ref  : VersionRef     -- Branch DataId | Tag DataId
}
```

The `Tag` variant's immutability is enforced by a validation functor that rejects any update
to a row whose current `ref` is a `Tag`. The `Branch` variant has no such restriction — HEAD
advances freely. Deletion of the `main` branch is rejected by a separate validation functor.
Hash prefixes are implicit graph node identifiers and require no row in this table.

**Creating and merging branches**: A new branch forks from an existing node and accumulates
commits independently. When a branch is merged back, the merge commit records **two parent
pointers** — one to the prior HEAD on the target branch and one to the tip of the incoming
branch. The DAG permanently shows both lineages; there is no rebase and no history
rewriting.

**Conflict resolution on merge**: Merge conflicts in both the schema and data graphs are
resolved by defining a functor that reconciles the divergent schemas, then applying that
functor to the affected data. The goal is for transparent functors to handle this
automatically in the common case; manual resolution is reserved for cases the functor
cannot express. The resolution functor is itself committed as a node in the schema graph.

**Orphaned branches**: A branch is orphaned when it has never been merged to `main` (or any
branch that has been merged to `main`) and its continued development has been abandoned.
Orphaned branches are the only case where the transaction graph is editable: an orphaned
branch and all nodes exclusive to it may be deleted. A branch with any path to `main` (via
merge) cannot be deleted.

**No-version routing**: Requests without a version token are routed to `main` HEAD by
default. The server can also split unversioned traffic across named branches at a
configurable rate for A/B testing; routing decisions persist via session affinity so the
same client consistently receives the same branch. This makes local and A/B testing
seamless without requiring clients to specify a version.

**Promoting a version**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever
tag or branch name the operator has promoted. The `/versions` discovery endpoint lists all
live version tokens and marks the promoted one. Operators use this to signal "use this tag
going forward" without requiring client code changes. Promotion state is stored in a system
table and is itself versioned.

## Data Shards

A shard is a named slice of the schema containing related tables. A shard is identified by
the `DataId` of its root row. Four shard types, each corresponding to a built-in replication
trait (see [schema/traits.md](schema/traits.md)):

| Shard / Trait | Description | Cardinality | Replication |
|---|---|---|---|
| `Reference` | Code tables; treated as code, propagated everywhere | Low-medium | All servers |
| `Configuration` | Tuning tables managed by operators | Medium | All servers |
| `UserData` | Scales with user count | High | Shard-local |
| `LogData` | Massive cardinality; prunable | Very high | Server-local, time-bounded |

A fifth replication trait, `Component`, does not name a shard type of its own — a component
table's rows live in whatever shard holds their parent. See
[schema/traits.md](schema/traits.md).

**`system` is a namespace, not a replication class.** It was previously listed as a fifth
shard type here, which does not survive contact with the tables in it:
`system.integrity.Violation` and every queue under `system.events` carry `LogData`, and
`system.logs` is per-server and prunable ([namespaces.md](namespaces.md)). A table in the
`system` namespace carries whichever replication trait fits it, exactly as an `app` table
does. The namespace says whose a table is and who may see it; the trait says how it
propagates. Neither implies the other.

`LogData`-type shards are **server-local by default**: each server is authoritative for its
own log data and does not replicate it to peers. This is a deliberate tradeoff — log volume
makes cross-server replication expensive, and per-server logs are sufficient for
auditability (query each server's log shard independently, or aggregate via a materialized
view). The HTTP request log shard is a specific instance of this pattern (see
[api.md](api.md)).

As data volume crosses configurable thresholds, a shard splits. The split is recorded as a
special node in the transaction graph so the history of which data lived in which shard is
always recoverable. The replication mechanics of a split are in
[distribution.md](distribution.md).

### Shard Roots

A shard is rooted at a **row**, not at a table. `DataId 'Shard` is defined above as the
`DataId 'Row` of the shard's root row, and `shardOf` is partial for exactly that reason — it
returns `Just` only for a root row. A name like `user.commerce` designates the shard
*family*: which tables participate. The concrete shards within it are one per root row.

This is what makes `UserData` mean what its cardinality column says. Each `Customer` row roots
a shard holding that customer's orders, lines, and addresses; a split redistributes customers
across servers, which is why `split shard … at key` takes a key (see
[schema/railroad.md](schema/railroad.md#administration)).

**Which table roots a shard is declared by its candidate key, not by a separate keyword.** A
`UserData` table whose key contains no foreign key to another table in the same family is a
root; one whose key does contain such a foreign key is a dependent, rooted transitively
through it. Since keys are mandatory
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) and must reach the root,
one declaration does both jobs, and it cannot drift out of agreement with itself — adding a
foreign key to a table changes nothing unless it is put in the key.

The asymmetry that follows is worth stating, because it inverts the obvious expectation:

| | Root table's key | Every other key in the shard |
|---|---|---|
| Scope | Cluster-wide | Within the one shard |
| Cost | None extra — this index *is* the shard directory (`username → DataId → shard`), which is the lookup that routes a request to the right server | None — the shard primary linearizes its own writes |

So the one key that must be globally unique is also the one the system already needs a global
index for. Every other uniqueness check is local, and no candidate key requires the
cross-shard lock that a distributed transaction would (see OQ-027).

`Component` is the degenerate case of the same rule: the parent supplies placement and the
`Ordinal` supplies uniqueness within it, which is why component tables need no declared key at
all.

### Placement Keys Are Not Identity Keys

A candidate key answers *which row is this*. Placement answers *where does it go*, and needs
strictly less — a **total order over the rows of the shard family**. The two jobs read as one
while `UserData` was the only case considered, because there the root's candidate key happens
to serve both.

> **A placement key needs only a total order. `DataId` is always one.**

`DataId` is deliberately excluded from satisfying the candidate-key rule
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) — counting the surrogate
would make that rule vacuous. It is nonetheless monotone, total, and present on every row, so
it is a perfectly good placement key. The consequence is worth stating plainly:

> **Every shard can be split, always.** A declared partition space chooses *where* the cut
> falls; it never decides *whether* a cut is possible.

| Shard family | Placement order | Cut point |
|---|---|---|
| `UserData` root | the root table's candidate key | key range |
| `UserData` dependent | inherited from its root through the FK chain | none — it follows its root |
| `LogData` | the retention time source (`created_at`, or `using`) | segment boundary |
| anything, last resort | `DataId` | any row boundary |

Cutting at a `DataId` boundary never splits a component subtree, because every descendant
shares the parent's byte prefix (see [Component Ordinals](#component-ordinals)). A
row-boundary cut is a prefix-boundary cut.

### `LogData` Shard Roots

`LogData` declares no candidate key, so it has no root key to partition on. The root is
supplied instead:

```
table system.shards.LogSegment : LogData {
  server       :> system.shards.Node,
  period_start : Timestamp,
  branch       : Int,
  unique segmentRef { server, period_start, branch }
}
```

`system.shards.Node` is the server registry `show servers` reads — `Configuration`, one row per
registered server, carrying the 2-byte node id assigned at registration (see
[Globally Unique Identifiers](#globally-unique-identifiers)).

One row per (server, period, retention branch); each roots the shard holding that segment's
log rows. `LogData` exempts a table from *needing* a key and does not forbid one — the same
point that lets a rollup level declare one
([schema/aggregates.md](schema/aggregates.md#what-gets-generated)). The root row lives in the
segment it roots and is pruned with it, exactly as a `Customer` row lives in the shard it
roots.

Four properties earn the shape:

- **The log table stays keyless and the family still has a key.** A log row is an occurrence
  with no identity beyond its occurrence; a segment is an entity and has one. The
  root-key-is-the-shard-directory invariant above is restored without weakening the exemption.
- **Routing costs zero stored bytes.** `server` is bytes 6–7 of the row's own `DataId` and
  `period_start` is bytes 0–5 truncated to the period. A row's segment is computed from the
  identifier it already carries — no lookup, no stored parent reference. `server` is a foreign
  key to a `Configuration` table, which does not participate in placement rooting
  ([schema/tables.md](schema/tables.md#keys-must-be-rooted)), so `LogSegment` is a root rather
  than a dependent; and because the key contains the server id, its cluster-wide uniqueness
  holds with no cluster-wide index.
- **Locality where it is used.** The identifier is time-major then server, so a segment is a
  strided set globally but a *contiguous range* on the server that wrote it — the only place
  it is ever scanned, since `LogData` is server-local ([distribution.md](distribution.md)).
- **Retention aligns to segments.** A closed segment is a whole retention unit, which turns
  pruning into an unlink rather than a row scan (below).

`period` is a `Configuration` value, not syntax — day by default. It has to be tunable,
because a retention chain whose raw step is shorter than the period would not align, and
because a low-volume server should not accumulate a million near-empty segments.

`branch` is the index of the matching `retain` branch, or `0` where the table has no `retain`
statement or an unbranched one. It belongs in the key because branch predicates may reference
only group fields and the time source
([schema/aggregates.md](schema/aggregates.md#branches)), so the branch is decidable when the
row is written. Without it a segment could hold rows with two different expiries and would not
be prunable as a unit.

The current segment accepts writes; when its period closes it is **sealed** and a new one
starts. Sealing moves no data, which is why it can be automatic where a `UserData` split
cannot ([distribution.md](distribution.md#shard-splits)).

### Extents Are Not Shards

A **shard** is a unit of authority: one primary, two secondaries, one sequence space. An
**extent** is a unit of storage: a run of the append-only log on one server, sized from
`system.shards.ExtentPolicy`. A shard is made of extents. The distinction is load-bearing, and
the `PhysicalLocator` already draws it:

| Move | What changes | Cost |
|---|---|---|
| A row moves between extents of its own shard | the `log_index` *value* (`offset`, `length`) | Nothing. The locator is unchanged, so `head_index` is unchanged, `updated_at` is unchanged, no graph node is written, and nothing replicates |
| A row moves to another shard | `plShard`, hence the locator, hence `head_index` | A logical event, recorded as a split node |

The byte offset lives in the *value* of `log_index` and not in the locator
([storage.md](storage.md)), which is what makes the first row of that table free. That is why
background repartitioning can run continuously and automatically: below the shard boundary it
is invisible to the graph and to every other server, exactly like the compaction it shares a
queue with.

The word is **extent** rather than *page* because LMDB has pages of its own, at a lower level
and a different size.

Sizing is a `Configuration` row, not syntax and not a trait parameter
([schema/traits.md](schema/traits.md#traits-are-not-configuration)):

```
table system.shards.ExtentPolicy : Configuration {
  table_path  : Text unique,        -- default for every server
  extent_size : Int,                -- unit is OQ-035
  period      : Duration = day      -- LogData segment period; ignored otherwise
}

table system.shards.ExtentOverride : Configuration {
  table_path  : Text,
  server     :> system.shards.Node,
  extent_size : Int,
  period      : Duration,
  unique overrideRef { table_path, server }
}
```

Two tables rather than one keyed by `{ table_path, server }` with an "all servers" variant,
because a `Null`-derived variant in a key is rejected
([schema/tables.md](schema/tables.md#ineligible-key-fields)). Resolution is
most-specific-first. `table_path` rather than `table`, which is a reserved word — the same
reason `system.integrity.Violation` spells it `subject_table`.

### Splitting a Shard With One Root Row

The partition function ranges over root rows, so a shard whose root set is a single row — one
customer with a hundred million orders — has nothing to cut on. It splits by descending the
placement chain to `DataId`, as any shard can. What that cannot do is move authority:

> **The extents of one shard may spread across disks and volumes freely. Across *servers* only
> if they share a primary.**

Three things are defined as holding within one shard: non-root uniqueness checks, `assert`
evaluation, and `Ordinal` assignment linearized by the shard primary. Sub-shards of one root
therefore form a **shard group** with a single primary — splitting a whale splits storage and
read capacity, never write authority.

`LogData` needs no group. It has no candidate keys, no cross-row asserts, and nothing to
linearize beyond the append itself, which is why its segments are independently placeable and
a `UserData` whale's extents are not.

## Pruning

`LogData` shards and old materialized views may be pruned. Pruning is recorded in the
transaction graph as a special node, so the system always knows that historical data before a
certain point has been discarded.

**Pruning log data is never a manual act.** It happens only as the consequence of a `retain`
chain declared on the table, and a `LogData` table with no such chain is never pruned at all
(see [schema/aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence)). This is
what turns "analytical summary metrics are computed before pruning to preserve aggregate
history" from an intention into a checked property: the summary is the next step of the chain,
and the prune node cannot be written before it exists.

A rollup is **two appends, never a rewrite**: one transaction writing the aggregate rows, then
a prune node covering the source range. The transaction being summarized is not edited to hold
the summary in place of its rows — transaction nodes are immutable, and rewriting one is the
history mutation this entire structure exists to prevent. The history therefore remains
readable as "these rows existed, then were summarized, then were discarded, and when."

It follows that rollup levels are ordinary tables with their own log entries, not materialized
views. A materialized view is recomputable from its source by definition; once the source is
pruned that no longer holds.

Because a `LogData` shard is rooted at a segment whose key carries the retention branch, an
expiring step usually covers a **whole sealed segment**. Pruning it is then an unlink of that
segment's extents plus one prune node, rather than a row scan. Row-level pruning remains the
fallback for a segment written before a branch was added or the period changed: routing is
decided when a row is written and is never revised, which is the same forward-only rule that
governs every other retention edit.

## Globally Unique Identifiers

Both transaction graph nodes and logical rows use a unified 12-byte `DataId`:

```
Bytes 0–5:  Unix timestamp in milliseconds (big-endian, 6 bytes) — valid through year ~10 890
Bytes 6–7:  Server node ID                 (big-endian, 2 bytes) — up to 65 535 servers
Bytes 8–11: Sequence counter               (big-endian, 4 bytes) — up to ~4.29 billion per server per millisecond
────────────────────────────────────────────────────────────────────────────────────────
Total: 12 bytes
```

- **Timestamp**: Unix epoch milliseconds. 2^48 ms ≈ 8 925 years from the epoch.
- **Server node ID**: assigned sequentially at server registration; coordination is required only at registration time, not at ID generation time.
- **Sequence**: monotonically increasing counter per `(server, millisecond)`, reset each millisecond. 4 bytes = 2^32 ≈ 4.29 billion increments per millisecond per server, or ~4.3 × 10^12/second.

Big-endian encoding means lexicographic order approximates chronological order — now at
millisecond rather than second granularity — which benefits LMDB range scans. `DataId` is
globally unique without per-ID coordination.

`DataId` is the primary key type for all DataCode-native tables and the identity of
transaction graph nodes.

### Clock Regression

Millisecond resolution makes the generator sensitive to wall-clock steps. An NTP correction
that moves the clock backwards would otherwise let a server re-issue a `(timestamp, server,
sequence)` triple it has already used, breaking the uniqueness guarantee above.

**The generator clamps.** It retains the last timestamp it emitted and never emits a lower
one; if the wall clock regresses, the timestamp is held at the last emitted value and the
sequence counter continues from where it was. With 4.29 billion sequence values per
millisecond there is ample room to absorb a regression of any realistic magnitude, so no
stall and no coordination is required. The generator emits an operational warning when it is
clamping, because a persistently regressing clock is a host problem.

### Identifier Roles

The same 12 bytes are used in three roles. They share one encoding, one generator, and one
sort order, and are distinguished by a phantom type parameter rather than by three separate
newtypes:

```haskell
data IdRole = Tx | Row | Shard

newtype DataId (r :: IdRole) = DataId ByteString   -- always 12 bytes
```

| Role | What it identifies |
|---|---|
| `DataId 'Tx` | a transaction graph node |
| `DataId 'Row` | a logical row, stable for the row's whole lifetime |
| `DataId 'Shard` | a shard — **this is the `DataId 'Row` of the shard's root row** |

The roles cost nothing at runtime and are erased on the wire. They exist so that a shard
identifier cannot be passed where a row identifier is expected. Because a shard is named by
its root row, the coercion is one-directional and partial:

```haskell
shardOf :: DataId 'Row -> Maybe (DataId 'Shard)   -- Just only for a shard root row
```

In the schema DSL the type is written `DataId` with no role — the role is inferred from
position. See [schema/types.md](schema/types.md).

### Rendering

A `DataId` renders as 20 characters of Crockford base32 (upper case, no padding), which is
what appears in CLI output, API paths, and the IDE:

```
05KG3N0000ZQ8V4T1H7C
```

Base32 was chosen over hex because it is shorter, and over base64 because it is
case-insensitive and free of characters that require escaping in a URL path segment.
Lexicographic order over the rendered form matches lexicographic order over the bytes, so
sorting rendered ids sorts them chronologically.

## Component Ordinals

Rows of a table carrying the `Component` replication trait do not get their own `DataId`.
They are identified **relative to their parent** by a 4-byte `Ordinal`:

```
<parent DataId> . <Ordinal>          -- 12 bytes + 4 bytes, logically
<Ordinal>                            -- 4 bytes, physically stored
```

Only the `Ordinal` is stored. The timestamp, server node, and sequence are inherited from
the parent through the containment link, which is also the reason the parent reference costs
no bytes at all — the parent *is* the identifier prefix.

Ordinals are assigned per parent, monotonically, starting at 1, and are never reused. The
assignment is a read-modify-write against the parent's current maximum, which is safe
without coordination because a component always lives in its parent's shard and the shard
primary linearizes writes. Components therefore cannot cross shards, and this is what makes
the whole scheme sound rather than merely compact.

Nesting appends another ordinal per level, so a component identifier is variable-length. That
is not a problem for LMDB, which sorts keys as bytes, and it buys a property the rest of the
design leans on heavily: **a parent's entire component subtree is one contiguous range
scan**, because every descendant shares the parent's byte prefix.

Rendered form is the base32 parent id followed by dot-separated decimal ordinals:

```
05KG3N0000ZQ8V4T1H7C.7
05KG3N0000ZQ8V4T1H7C.7.2
```

See [schema/traits.md](schema/traits.md) for the `Component` trait and the invariants it
enforces, and [schema/documents.md](schema/documents.md) for its principal use.

## Physical Locators

`DataId` names a row. It does not say where any particular *version* of that row lives. That
is the job of the **`PhysicalLocator`** — a composite address into the append-only log:

```haskell
data PhysicalLocator = PhysicalLocator
  { plShard  :: ShardIndex  -- server-local shard index (4 bytes)
  , plTxSeq  :: Word64      -- monotonic tx sequence within shard (8 bytes)
  , plRowPos :: Word16      -- row position within transaction (2 bytes; max 65535 rows/tx)
  }
-- Encoded as 14 bytes, big-endian throughout
```

Big-endian encoding is critical: LMDB sorts keys lexicographically, and big-endian integer
encoding makes `lexicographic order == numeric order`. This means "all rows written by
transaction 42 in shard 1" is a single contiguous LMDB range scan with no scatter-gather.

Transaction nodes themselves use `plRowPos = 0` by convention
(`txNodeLocator shard txSeq = PhysicalLocator shard txSeq 0`). Rows within a transaction
occupy positions 1 through N.

**Two-tier identifier model:**

- **Logical, user-visible**: `DataId`. Stable across mutations — the same `DataId` for the row's whole lifetime. 12 bytes, globally unique, replicated as-is.
- **Physical, internal**: `PhysicalLocator`. Changes on every mutation, pointing at one specific version in the log. Never exposed in the schema DSL and never replicated — each server computes its own.

The LMDB `head_index` bridges the two: `DataId → current PhysicalLocator`. Following up
through `log_index` yields the location on disk. See [storage.md](storage.md).

**Relocation is not a version.** Moving a row between extents of its own shard rewrites the
`log_index` value and nothing else — the locator is unchanged, so no new row version exists,
`updated_at` does not move, and two servers cannot disagree about it. This is the property
background repartitioning rests on, and it is why `plShard` being *inside* the locator while
the byte offset is not is exactly what separates a free move from a recorded one.

**Sort order confirmed by spike** (`spikes/storage/output.txt`): ByteString lexicographic
sort of encoded locators produces the same ordering as Haskell's derived `Ord` instance.

### `ShardIndex`

`plShard` is a `Word32`, not a `DataId 'Shard`. Shards are named globally by their root row's
12-byte `DataId`, but embedding that in every LMDB key would take the key from 14 bytes to
22 for no gain — a locator is only ever meaningful on the server that computed it, and that
server knows its own shards.

`ShardIndex` is therefore a **server-local interning** of `DataId 'Shard`, with the mapping
held in `system.shards.Index`. The general rule, which applies beyond this case:

> Logical identifiers are wide and global. Physical identifiers are narrow and local.

A `ShardIndex` must never appear in a replication message, an API response, or an error
string. Two servers may legitimately assign different indexes to the same shard.

## Virtual Columns

Every table exposes two automatic virtual columns derived from these identifiers:

- `created_at` — timestamp extracted from the row's `DataId` (millisecond resolution)
- `updated_at` — timestamp of the most recent `PhysicalLocator` that mutated the row

Because `updated_at` is derived from the newest version of the row, anything that writes to a
row perturbs it. This is why nonconformance is recorded in separate rows that point *at* the
subject rather than as a flag on the subject — see [integrity.md](integrity.md).

For a `Component` row, `created_at` is inherited from the parent's `DataId`: ordinals carry
no time of their own. A component that must record its own creation time declares a
`Timestamp` field.
