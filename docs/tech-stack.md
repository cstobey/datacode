# Technology Stack

Decisions here are the resolved answers from [open-questions.md](open-questions.md);
each is cross-referenced to the OQ that settled it and the spike that validated it.

## Language

**Haskell** (GHC). Chosen for:

- Strong static type system — essential for encoding category-theoretic constraints
- Typeclasses as the mechanism for functor composition and inheritance
- Lazy evaluation — useful for streaming large query results
- Mature ecosystem for parsing, serialization, networking, and concurrency

GHC must be built with `-threaded`. This is not optional — the LMDB binding depends on it
(see Storage below).

## Network Layer

### Warp

`warp` is the de facto Haskell HTTP server. Fast, well-maintained, production-proven.
DataCode uses Warp as the underlying HTTP engine.

### Servant — confirmed for the static frame

**Decided (OQ-002).** Servant + Warp works. The open question was whether Servant's
compile-time API types could accommodate DataCode's runtime-dynamic schema. They can, using
the static-meta-API-plus-`Raw` pattern:

```haskell
"schema" :> Capture "ns" String :> Capture "name" String :> Raw
```

Servant handles the static URL structure; the `Raw` endpoint delegates to a runtime dispatch
table. Confirmed in `spikes/servant-warp/output.txt` at ~1µs/request overhead. No Yesod
needed for the data plane.

### Route trie — hand-rolled

**Decided (OQ-029).** The dispatch table behind `Raw` is a hand-rolled route trie held in an
`IORef`, not a `Map` and not an off-the-shelf router.

| Option | Result |
|---|---|
| **Hand-rolled trie** | **Chosen.** 0.2µs/request at 10k routes; `O(depth × log fanout)`, independent of route count |
| Linear scan | Ruled out — 1µs at 100 routes, 132µs at 10k. `O(n)` |
| `wai-routes` | Ruled out — Template Haskell compile-time route tables, incompatible with runtime registration |
| `path-piece` | Ruled out — a segment-parsing typeclass, not a router |

Schema changes rebuild the trie and atomically swap the `IORef` — zero request interruption.
Static segments beat captures at the same depth. Confirmed in `spikes/route-trie/output.txt`.
See [api.md](api.md).

### Yesod — not used

**Decided (OQ-013).** Not needed for the data plane. Servant + WAI covers all data plane
needs; Yesod would add session management and HTML templating irrelevant to a JSON/binary
API server, and its Persistent ORM is actively counterproductive given DataCode builds its
own data layer.

Revisit only for the thin-client HTML layer, which is post-MVP — Yesod's type-safe routing
and session management may still be worth having there.

## Serialization

### JSON

`aeson` — standard, well-optimized. Used for the third-party JSON API.

### Binary replication — Cap'n Proto

**Decided (OQ-003).** Cap'n Proto for production; `cereal` during initial development.

| Library | Verdict |
|---|---|
| **Cap'n Proto** | **Chosen for production.** Zero-copy via mmap, automatic schema evolution, sub-µs encode and decode |
| `cereal` | **Chosen for development.** Identical wire framing, no external toolchain. Ceiling: schema evolution needs an explicit version byte and branching decoder |
| Protobuf | Ruled out — requires full parsing; Cap'n Proto mmaps the bytes directly |
| MessagePack | Ruled out — no schema evolution story |

The migration path is cheap because the framing is identical (length prefix + single-segment
message header); only the payload encoding changes. Swap `Serialize` instances for
capnp-generated `Cerialize`/`Decerialize` before production.

Schema evolution confirmed by spike: a V1 message read by a V2 decoder defaults the new
field to 0; a V2 message read by a V1 decoder silently ignores the extra data word. No
version byte, no branching decoder, no migration step. One added field costs exactly 8 bytes
(V1 = 112 bytes, V2 = 120). Confirmed in `spikes/capnproto/output.txt`.

Requires the `capnp` C++ tool at compile time (`apt install capnproto`).

## Storage

**Decided (OQ-004).** Hybrid: a custom append-only log for the transaction graph plus two
LMDB databases per shard for indexing. RocksDB is not used.

| Component | Choice |
|---|---|
| Transaction graph | Append-only log of length-prefixed Cap'n Proto frames, mmap-readable without deserialization |
| `log_index` | LMDB: 14-byte `RowId` → `{offset: Word64, length: Word32}` |
| `head_index` | LMDB: 12-byte `DataId` → 14-byte `RowId` |

LMDB was chosen over RocksDB: memory-mapped reads touch the OS page cache rather than
copying, MVCC means readers never block writers, and it is crash-safe by default
(copy-on-write B-tree with two root pages, no separate WAL). The LSM-tree write advantage
RocksDB offers is not needed — the append-only log absorbs the write path.

**LMDB threading requirement**: `-threaded` in `ghc-options` **and** a session-level
`runInBoundThread` wrapping the entire LMDB session (open → read/write → close). The `lmdb`
package calls `isCurrentThreadBound` before acquiring its write lock; without `-threaded`
that always returns `False`. Production pattern: one dedicated `forkOS` thread for all
writes fed by a `TQueue`; reads run concurrently under MVCC. See
`spikes/capnproto/src/Spike/LmdbFixed.hs`.

**Latency**: reads 11µs/op, writes 1,107µs/op. Write cost is dominated by `fdatasync()` on
every commit. Not a concern — DataCode batches 10–100 mutations per transaction, giving
11–110µs/mutation. Single-mutation micro-benchmarks are unrepresentative.

Full detail in [storage.md](storage.md).

## Dynamic Loading

**Decided (OQ-001).** GADT DSL as the primary functor mechanism, with `Data.Dynamic` as the
type registry substrate. Zero runtime GHC dependency. See
[dynamic-loading.md](dynamic-loading.md) for the decision, the spike results, and the full
list of options considered.

## Concurrency

`stm` for in-process concurrency — coordination between incoming requests, background
replication, and view materialization.

`async` for structured concurrency of background tasks (replication, view materialization,
peer gossip).

`TQueue` plus a dedicated `forkOS` bound thread for the LMDB write path, as above.

## Testing

- `hspec` or `tasty` for unit and integration tests
- Property-based testing with `QuickCheck` or `hedgehog` is particularly important given the mathematical invariants (path equivalence, functor laws, idempotency)
- Feasibility spikes live in `spikes/` as small standalone Haskell projects

## Build System

`cabal` (with `cabal.project` for multi-package layout). `stack` is an option but cabal's
solver has improved significantly and is preferred for new projects. Multi-package monorepo
from the start:

- `datacode-core` — category model, types, transaction graph
- `datacode-server` — server daemons, replication, networking
- `datacode-client` — thick client library
- `datacode-schema-dsl` — schema definition language and interpreter
- `datacode-html` — HTML rendering engine

External build-time dependencies: `capnproto` (C++ tool, for the production wire format),
LMDB system library.

## Remaining Open Technology Decisions

The stack decisions above are settled. Still open:

- **Connector daemon architecture** (OQ-019) — separate supervised process vs. thread pool in the main server
- **Multi-daemon supervision** — the schema daemon must restart when compiled-in types change (see [dynamic-loading.md](dynamic-loading.md)); the supervisor design is not specified
- **Graph layout library for the IDE** (OQ-021) — ELK.js client-side vs. `graphviz` server-side
- **`hint` as an escape hatch** — failed to compile in the spike; revisit if user-defined functors outgrow the GADT DSL
