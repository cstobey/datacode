# Cap'n Proto + LMDB Feasibility Spike

Answers the remaining open questions from the storage spike (OQ-003, OQ-004).

## What This Tests

The storage spike proved the **structure**: append-only log with length-prefix
framing, offset-based random access, and LMDB two-database indexing all work.
It used `cereal` as a stand-in for Cap'n Proto and ended with two open items:

1. **OQ-003**: The real question wasn't whether cereal works (it does), but
   whether Cap'n Proto's unique properties — zero-copy mmap reads and automatic
   schema evolution — are achievable in Haskell. This spike answers: yes.

2. **OQ-004 (threading)**: The storage spike hit `MDB_PANIC: must lock from
   bound thread` at runtime. This spike fixes it and confirms LMDB is viable.

## Four Properties Proved

| Property | Test |
|---|---|
| Cap'n Proto wire format | Manual implementation — encode/decode TxNode round-trip |
| mmap zero-copy reads | Write to file, mmap back, read fields at byte offsets (no decode) |
| Schema evolution | V1 bytes readable by V2 decoder (default); V2 bytes by V1 (ignored) |
| LMDB threading fix | `runInBoundThread` wrapping eliminates the bound-thread panic |

## Prerequisites

```bash
# LMDB C library (required)
apt install liblmdb-dev          # Debian/Ubuntu
brew install lmdb                # macOS

# mmap package on Hackage depends on the system mmap(2) call — no extra install
```

## Run

```bash
cd spikes/capnproto
cabal build
cabal run capnproto-spike
```

## What to Measure

### Part 1: Cap'n Proto Encoding
- [ ] Does encode → decode round-trip preserve all fields (timestamp, serverId, id, schemaVer, parents)?
- [ ] Message size in bytes (baseline: storage spike cereal txnode was ~220 bytes for 10 mutations)
- [ ] Encode latency µs/tx — target: < 1µs (cereal baseline: 0.15µs; Cap'n Proto manual may be higher)
- [ ] Full decode latency µs/tx — target: < 1µs (cereal baseline: 0.10µs)
- [ ] Zero-copy timestamp read latency µs — target: << full decode (should be ~0.01µs — single getWord64le)

### Part 2: mmap Zero-Copy
- [ ] Does mmapFileByteString return a ByteString backed by OS page cache? (verify: modify the file and re-read — the ByteString should see the change without re-mapping)
- [ ] Is the zero-copy timestamp read latency from mmap the same as from an in-memory ByteString? (should be: the first access touches the page; subsequent reads are L1/L2 cache)
- [ ] Speedup of zero-copy vs full decode for single-field access?

### Part 3: Schema Evolution
- [ ] Does a V2 reader reading V1 bytes get `schemaVersion = 0`? (must be exactly 0 — the default)
- [ ] Does a V1 reader reading V2 bytes get correct `timestamp` and `serverId`? (the extra data word must be silently ignored)
- [ ] Size delta: V2 TxNode vs V1 TxNode — should be exactly 8 bytes (one additional data word)

### Part 4: LMDB Threading Fix
- [ ] Does `runInBoundThread` eliminate the `MDB_PANIC` error?
- [ ] Write latency µs — compare with storage spike (which failed before measuring). Target: < 500µs per write.
- [ ] Read latency µs — target: < 50µs per read (LMDB reads from OS page cache).

## Key Decision Points

After running, answer:

1. **Is the encoding latency acceptable?**
   The manual implementation is expected to be faster than cereal because it
   computes fixed offsets rather than running a generic serialiser. If it's
   slower, that's unexpected — investigate.

2. **Is the zero-copy speedup real?**
   For queries that only need `timestamp` or `serverId` (e.g., a range scan to
   find all transactions in a time window), zero-copy avoids decoding `id`,
   `schemaVer`, `parents`, and `mutations` entirely. The speedup should be
   proportional to the amount of data skipped.

3. **Is the LMDB write latency acceptable?**
   `runInBoundThread` per-call is a stopgap. The production pattern is a
   single bound-thread worker with a `TQueue`. If the per-call latency is
   < 500µs, the stopgap is acceptable for development; if it's >> 500µs,
   the dedicated worker is needed sooner.

## Expected Architecture Decision

This spike confirms the storage layer design from OQ-003 / OQ-004:

```
Transaction write path:
  TxNode (Haskell value)
    → Cap'n Proto encode → ByteString (length-prefix framed)
    → append to log file (O(1) seek to end + write)
    → LMDB log_index: RowId → LogEntry{offset, len}  (via bound thread)
    → LMDB head_index: UUID → current RowId           (via bound thread)

Transaction read path (zero-copy):
  UUID (primary key)
    → LMDB head_index lookup → current RowId
    → LMDB log_index lookup  → LogEntry{offset, len}
    → mmap[offset : offset+len] → ByteString (OS page cache)
    → Cap'n Proto struct pointer → field access at byte offset
    → no heap allocation, no decode pass (for integer fields)
```

## Production Migration Path

Replace the `cereal` Serialize instances in the production storage module with
`capnp`-generated `Cerialize`/`Decerialize` instances:

```bash
# Install capnp tool:
apt install capnproto   # or brew install capnproto

# Generate Haskell types from schema:
capnp compile -ohaskell --src-prefix=schema schema/datacode.capnp

# Move generated files to src/Capnp/Gen/
# Import and use the generated types
```

The wire format produced by the generated code is byte-for-byte identical to
what this spike produces manually. The length-prefix framing, struct pointer
layout, and blob offsets are the same — only the Haskell interface changes
(from manual ByteString manipulation to type-safe generated accessors).

## Files

```
capnproto.cabal         — project definition
cabal.project           — workspace config
schema/
  datacode.capnp        — authoritative Cap'n Proto schema for all DataCode types
app/
  Main.hs               — orchestrates all four parts + prints summary
src/Spike/
  CapnProto.hs          — wire format implementation + encode/decode + zero-copy reads
  ZeroCopy.hs           — mmap zero-copy test from disk
  Evolution.hs          — V1/V2 schema evolution demonstration
  LmdbFixed.hs          — LMDB with runInBoundThread fix
```
