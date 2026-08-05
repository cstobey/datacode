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

A shard is a named slice of the schema containing related tables. Five shard types, each
corresponding to a built-in replication trait (see [schema/traits.md](schema/traits.md)):

| Shard / Trait | Description | Cardinality | Replication |
|---|---|---|---|
| `Reference` | Code tables; treated as code, propagated everywhere | Low-medium | All servers |
| `Configuration` | Tuning tables managed by operators | Medium | All servers |
| `UserData` | Scales with user count | High | Shard-local |
| `LogData` | Massive cardinality; prunable | Very high | Shard-local, time-bounded |
| `system` | DataCode self-management tables | Low | All servers |

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
Bytes 0–4:  Unix timestamp in seconds  (big-endian, 5 bytes) — valid through year ~36 800
Bytes 5–6:  Server ID                  (big-endian, 2 bytes) — up to 65 535 servers
Bytes 7–11: Sequence counter           (big-endian, 5 bytes) — up to ~1.1 trillion per server per second
────────────────────────────────────────────────────────────────────────────────────────
Total: 12 bytes
```

- **Timestamp**: Unix epoch seconds. No sub-second precision needed — the sequence counter handles intra-second uniqueness.
- **Server ID**: assigned sequentially at server registration; coordination required only at registration time, not at ID generation time.
- **Sequence**: monotonically increasing counter per `(server, second)`, reset each second. 5 bytes = 2^40 ≈ 1.1 trillion increments/second/server.

Big-endian encoding means lexicographic order approximates chronological order, which
benefits LMDB range scans. `DataId` is globally unique without per-ID coordination.

`DataId` is the primary key type for all DataCode-native tables and the identity of
transaction graph nodes.

## Row Identifiers

Every row version in the transaction graph has a **composite physical row identifier**:

```haskell
data RowId = RowId
  { ridShard  :: Word32  -- shard index (4 bytes; supports ~4B shards)
  , ridTxSeq  :: Word64  -- monotonic tx sequence within shard (8 bytes)
  , ridRowPos :: Word16  -- row position within transaction (2 bytes; max 65535 rows/tx)
  }
-- Encoded as 14 bytes, big-endian throughout
```

Big-endian encoding is critical: LMDB sorts keys lexicographically, and big-endian integer
encoding makes `lexicographic order == numeric order`. This means "all rows written by
transaction 42 in shard 1" is a single contiguous LMDB range scan with no scatter-gather.

Transaction nodes themselves use `rowPos = 0` by convention
(`txNodeId shard txSeq = RowId shard txSeq 0`). Rows within a transaction occupy positions 1
through N.

**Two-tier identifier model:**

- **User-visible**: the `DataId` primary key. Stable across mutations — same `DataId` throughout the row's lifetime.
- **Physical**: `RowId` — changes on every mutation, pointing to the newest version in the log. Internal only; not exposed in the schema DSL.

The LMDB `head_index` bridges the two: `DataId → current RowId`. Following up through
`log_index` yields the physical location on disk. See [storage.md](storage.md).

**Sort order confirmed by spike** (`spikes/storage/output.txt`): ByteString lexicographic
sort of encoded RowIds produces the same ordering as Haskell's derived `Ord` instance.

## Virtual Columns

Every table exposes two automatic virtual columns derived from these identifiers:

- `created_at` — timestamp extracted from the row's `DataId`
- `updated_at` — timestamp of the most recent `RowId` that mutated the row
