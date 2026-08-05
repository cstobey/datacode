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

Each `TxNode` carries: its own `RowId`, schema version reference, timestamp, server ID,
parent RowId list, and the list of mutations (inserts/deletes). Benchmark: encode ~0.15µs/tx,
decode ~0.10µs/tx at 10 mutations/tx.

With Cap'n Proto + mmap, the bytes on disk **are** the runtime representation — field access
is pointer arithmetic, not deserialization. This is the Mnesia analogy: the disk format
evolves with the schema, not with the data.

### 2. Two LMDB databases per shard

| Database | Key | Value | Purpose |
|---|---|---|---|
| `log_index` | 14-byte RowId | 12-byte `{offset: Word64, length: Word32}` | Random access to any row version in O(1) |
| `head_index` | 12-byte DataId | 14-byte RowId | Resolve logical row to current physical version |

## Full Zero-Copy Read Path

```
DataId → head_index → RowId
       → log_index  → (file_offset, length)
       → mmap[offset:length] → Cap'n Proto message
       → field access via pointer arithmetic (no copy)
```

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

Views are just table definitions — the distinction between a "live" table and a
"materialized view" is a storage hint, not a schema-level distinction. See
[schema/queries.md](schema/queries.md) for the syntax and
[distribution.md](distribution.md) for the cooperative computation protocol.
