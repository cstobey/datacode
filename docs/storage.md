# Physical Storage

How the transaction graph is represented on disk. The logical model is in
[transaction-graph.md](transaction-graph.md).

## Two Complementary Structures Per Shard

### 1. Append-only transaction log (Cap'n Proto frames)

Immutable, sequentially written. Each entry is a length-prefix-framed Cap'n Proto `TxNode`
message:

```
[4-byte big-endian length][Cap'n Proto TxNode bytes...]
```

Each `TxNode` carries: its own `PhysicalLocator`, schema version reference, timestamp, server
ID, parent locator list, and the list of mutations (inserts/deletes). Benchmark: encode
~0.15µs/tx, decode ~0.10µs/tx at 10 mutations/tx.

With Cap'n Proto + mmap, the bytes on disk **are** the runtime representation — field access
is pointer arithmetic, not deserialization. This is the Mnesia analogy: the disk format
evolves with the schema, not with the data.

### 2. Two LMDB databases per shard

| Database | Key | Value | Purpose |
|---|---|---|---|
| `log_index` | 14-byte PhysicalLocator | 12-byte `{offset: Word64, length: Word32}` | Random access to any row version in O(1) |
| `head_index` | 12-byte DataId (+ ordinals) | 14-byte PhysicalLocator | Resolve logical row to current physical version |

## Full Zero-Copy Read Path

```
DataId → head_index → PhysicalLocator
       → log_index  → (file_offset, length)
       → mmap[offset:length] → Cap'n Proto message
       → field access via pointer arithmetic (no copy)
```

## Component Subtrees Are One Range Scan

`head_index` keys are variable-length: a `DataId` for an ordinary row, and a `DataId`
followed by one 4-byte `Ordinal` per nesting level for a component row (see
[transaction-graph.md](transaction-graph.md#component-ordinals)).

Because LMDB sorts keys as bytes and every descendant shares its parent's byte prefix, a
parent's entire component subtree is a **single contiguous range scan** returning nodes in
document order — no scatter-gather, no per-node lookup, and no stored parent pointers to
follow. This is the property the document type is built on, and it is why a shredded document
of 200 nodes costs one seek to read rather than 200.

## Extents and Clustering

A shard's append-only log is written in **extents** — runs of the log allocated on one server
and sized from `system.shards.ExtentPolicy`. An extent is a unit of storage, not of authority;
the distinction and what rests on it are in
[transaction-graph.md](transaction-graph.md#extents-are-not-shards). *Extent* rather than
*page*, because LMDB has pages of its own at a lower level.

### Relocation Rewrites Offsets, Not Locators

`log_index` maps a 14-byte `PhysicalLocator` to `{offset, length}`. The offset is the
**value**, so moving a row between extents of its own shard rewrites that value and touches
nothing else: the locator is unchanged, `head_index` is unchanged, no new row version is
created, and `updated_at` does not move. Relocation therefore appends nothing to the
transaction graph and replicates nothing.

This is what makes repartitioning a background task rather than a maintenance window. It runs
under the event scheduler on `system.events.MaintenanceQueue` alongside compaction and view
refresh, pegged to a stable commit node the way a materialized view computation is.

### Compaction Is Lossless

Compaction shares the maintenance queue with repartitioning and shares its guarantee:

> **Compaction never discards a row version.** It changes where bytes live so they are stored
> more optimally as the schema evolves, and nothing else.

Superseded row versions are not garbage. They are the version chain, and the version chain is
the transaction graph's account of how a row reached its current value — the thing "nothing is
destroyed" is about. A compactor that collapsed old versions to reclaim space would be
rewriting history to save disk, which is the trade this design exists to refuse.

**Pruning is the sole way data is lost, and what it loses is granularity, on purpose.** It
happens only as the consequence of a declared `retain` chain, the coarser resolution is written
before the finer one is discarded, and a prune node records the boundary
([transaction-graph.md](transaction-graph.md#pruning)). The distinction is worth stating as a
pair, because both run on the same queue and only one of them may lose anything:

| Operation | Trigger | May lose |
|---|---|---|
| Relocation | volume, background | nothing — not even a locator |
| Compaction | schema change, background | nothing — every version survives |
| Pruning | a declared `retain` chain | granularity, deliberately, after the rollup exists |

The consequence relied on elsewhere: **anything derivable from a row's version chain stays
derivable for as long as the row exists.** That is what lets per-field timestamps be a cache
rather than a stored column ([transaction-graph.md](transaction-graph.md#per-field-timestamps)).

### Clustering Order

Rows are laid out within an extent in an order chosen per shard family:

| Family | Order |
|---|---|
| `LogData` | time, which is `DataId` order |
| `UserData` | containment — the root row, then its component subtrees, then dependents by foreign-key depth |

`UserData`'s order matters more than it looks. "A shredded document of 200 nodes costs one
seek" holds only because the log is clustered so that a component subtree is *physically*
adjacent, not merely adjacent in `head_index` — a contiguous key range still yields 200
locators, and they point somewhere. Any relocation that reorders rows without preserving
containment adjacency invalidates that claim. Containment is therefore the constraint, and
everything else is a tie-break inside it.

**Schema PageRank breaks the ties** — which dependent tables sit next to the root when they
cannot all fit. That score is computed over the *schema* graph ([ide.md](ide.md)), so the
ordering is a function of the schema and is recomputed only on schema commit. A data-dependent
ordering was rejected for three reasons: it relocates rows for reasons unrelated to any write,
it produces layouts that differ between replicas computing it independently, and per-row
importance is not what schema PageRank computes in the first place. The determinism
requirement this places on the computation is noted in OQ-010.

## Shredded Documents

A `Doc` field stores the received bytes in the row, and nothing else. When the field is
declared `indexed`, the shredded node tree is a **materialized view** over those bytes: pegged
to a commit node, computed in the background, rebuildable at any schema node, and droppable
without data loss.

The bytes stay authoritative rather than becoming a cache of the shredded form, for a reason
that has nothing to do with storage: webhook signature verification is an HMAC over the body
exactly as received, and no re-serialization of a shredded tree can reproduce key order,
duplicate keys, and number formatting reliably enough to verify against. See
[schema/documents.md](schema/documents.md).

LMDB properties that make this viable: memory-mapped (reads touch OS page cache, not a
copy), MVCC (readers never block writers), crash-safe by default (copy-on-write B-tree +
two root pages, no separate WAL), and sorted keys (range scans over all rows in a
transaction are contiguous).

## LMDB Threading

Requires `-threaded` in GHC options and a session-level `runInBoundThread` wrapping the
entire LMDB session (open → read/write → close). The `lmdb` Haskell package calls
`isCurrentThreadBound` before acquiring its write lock. Production pattern: one dedicated
OS-bound thread (`forkOS`) for writes, with a `TQueue`; reads are concurrent (LMDB MVCC).

See `spikes/capnproto/src/Spike/LmdbFixed.hs`.

## LMDB Latency

Confirmed in `spikes/capnproto/output.txt`: reads 11µs/op, writes 1,107µs/op. Write latency
is high because LMDB `fdatasync()`s on every transaction commit (durability guarantee).
This is not a concern: DataCode batches multiple mutations per transaction (10–100
mutations/tx → 11–110µs/mutation). Single-mutation micro-benchmarks are not representative
of production write patterns.

## Wire Format for Replication

Confirmed in `spikes/capnproto/output.txt`: use cereal during initial development; swap to
Cap'n Proto generated code before production. Wire framing (length-prefix + single-segment
message header) is identical — only the payload encoding changes.

Cap'n Proto provides automatic schema evolution: adding a new field to `TxNode` is always
backward and forward compatible, no decoder changes needed. Adding one field costs exactly 8
bytes per message (V1 = 112 bytes, V2 = 120 bytes). Encode and full decode both sub-µs.

Protobuf is **not** a substitute: Protobuf requires full parsing; Cap'n Proto mmaps the
bytes directly.

Requires the `capnp` C++ tool at compile time (`apt install capnproto`).

## Materialized Views

Materialized views are pegged to **specific commit nodes** in the transaction graph:

- They never block or slow down ongoing transactions (they reference a past, stable state)
- They are updated in the background or lazily when accessed
- Each server maintains its own materialized views
- Large analytical queries can be distributed across neighbouring servers
- The computation of a materialized view can be shared between neighbours (distribute the work, merge the results)

### Refresh Is Incremental Only If the View Has a Meaningful Key

A view's candidate key is derived from its sources rather than declared
([schema/queries.md](schema/queries.md#view-keys-are-computed-never-declared)), and which kind
of key it derives decides how the view can be maintained:

| Derived key | Refresh |
|---|---|
| Meaningful — a proper subset identifying an entity | **Incremental.** The key says which row a recomputed one replaces, so a refresh upserts only what changed. |
| Degenerate — all attributes | **Full only.** Nothing identifies a row across recomputations, so the extent is rebuilt. |

This is the same idempotence property that lets a retention rollup play catch-up without
duplicating buckets ([schema/aggregates.md](schema/aggregates.md#what-gets-generated)) — a
keyed derived table can be recomputed for any window and merged, an unkeyed one cannot.

It also decides whether a view can outlive its sources. An incrementally-maintainable view has
an existence independent of its sources' full extent and is a candidate to replace them, which
is what a rollup level does when it supersedes the raw table. A degenerate view can only be
rebuilt by rescanning, so it pins its sources in place and `deprecate` on them is rejected
until the view is altered or deprecated.

Views are just table definitions — the distinction between a "live" table and a
"materialized view" is a storage hint, not a schema-level distinction. See
[schema/queries.md](schema/queries.md) for the syntax and
[distribution.md](distribution.md) for the cooperative computation protocol.

**Retention rollups are not materialized views**, despite being computed in the background the
same way. A materialized view is recomputable from its source by definition, and a rollup's
source is pruned as soon as the rollup exists. Rollup levels are therefore real tables with
their own entries in the append-only log. See
[schema/aggregates.md](schema/aggregates.md#a-rollup-is-two-appends-not-a-rewrite).
