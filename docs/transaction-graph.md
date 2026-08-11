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

**Tag attachment**: Tags are rows in `system.version_refs`, inserted as part of a
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
table system.version_refs {
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
the `DataId` of its root row. Five shard types, each corresponding to a built-in replication
trait (see [schema/traits.md](schema/traits.md)):

| Shard / Trait | Description | Cardinality | Replication |
|---|---|---|---|
| `Reference` | Code tables; treated as code, propagated everywhere | Low-medium | All servers |
| `Configuration` | Tuning tables managed by operators | Medium | All servers |
| `UserData` | Scales with user count | High | Shard-local |
| `LogData` | Massive cardinality; prunable | Very high | Shard-local, time-bounded |
| `system` | DataCode self-management tables | Low | All servers |

A sixth replication trait, `Component`, does not name a shard type of its own — a component
table's rows live in whatever shard holds their parent. See
[schema/traits.md](schema/traits.md).

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

## Pruning

`LogData` shards and old materialized views may be pruned. Pruning is also recorded in the
transaction graph as a special node, so the system always knows that historical data before
a certain point has been discarded. Analytical summary metrics are computed before pruning
to preserve aggregate history.

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

**Sort order confirmed by spike** (`spikes/storage/output.txt`): ByteString lexicographic
sort of encoded locators produces the same ordering as Haskell's derived `Ord` instance.

### `ShardIndex`

`plShard` is a `Word32`, not a `DataId 'Shard`. Shards are named globally by their root row's
12-byte `DataId`, but embedding that in every LMDB key would take the key from 14 bytes to
22 for no gain — a locator is only ever meaningful on the server that computed it, and that
server knows its own shards.

`ShardIndex` is therefore a **server-local interning** of `DataId 'Shard`, with the mapping
held in `system.shards.index`. The general rule, which applies beyond this case:

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
