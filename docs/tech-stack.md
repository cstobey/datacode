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

**Decided (OQ-001).** Two mechanisms for two questions.

Functors are terms in an **effect-indexed GADT DSL**, interpreted, with `Data.Dynamic` as
the type registry substrate. Zero runtime GHC dependency; 0.07–0.8 µs per application,
against an 11 µs LMDB read. Compiled-in Haskell — handlers, primitive types, the
interpreter itself — changes by **generation swap behind a stable router**. A schema
change touches only the first and needs no swap at all.

Confirmed in `spikes/functor-dsl/output.txt`, which supersedes
`spikes/dynamic-loading/output.txt` for every DSL claim. See
[dynamic-loading.md](dynamic-loading.md) for the process topology, build-then-merge, the
remaining ceilings, and the full list of options considered.

`Text.Regex.TDFA` is the settled engine for `=~` but is **unvalidated** — it cannot be
installed in the development sandbox, so the spike uses a stand-in matcher and validates
the primitive's provenance restriction and compiled-pattern cache instead.

## Process Topology

**Decided (OQ-001).** Four processes per host. The governor is per host and holds no data
authority; cluster role assignment stays with the range tree (OQ-007).

| Process | Restarts when |
|---|---|
| Router — route trie, generation table, version-token resolution | never, for a schema or handler change |
| Data workers — serve every live ref, functors interpreted | a new build lands |
| Handler workers — `Effect` only, HEAD only, separate pool | a new build lands |
| Governor — registers generations, sequences swaps, recycles on interval | host maintenance |

The handler pool is separate because the data plane serves N refs and a queue is processed
at exactly one, so the two have different versioning requirements. It also puts the
`Effect` boundary on a process boundary, which lets a `Configuration` capability grant be
enforced by the OS rather than by convention.

**Write authority handover needs no new mechanism**: LMDB's writer lock is cross-process
and OS-enforced, so the incoming generation blocks on it while the outgoing one finishes
its in-flight transaction. Reads never stall — LMDB is MVCC and multi-process. Recycling
on a `Configuration` interval is deliberate, to keep the swap path exercised.

Adding GHC to every node is accepted and has two costs worth recording: a node becomes a
provisioned host rather than a dropped binary, and the GHC version joins the compatibility
surface, so a generation artifact is valid only for its
`(schema node, DataCode version, GHC version, arch)` tuple. Content-addressing the
generation registry on that tuple makes cross-host artifact sharing a later cache lookup
rather than a redesign.

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

- **Graph layout library for the IDE** (OQ-021) — ELK.js client-side vs. `graphviz` server-side
- **Generation swap and build latency** — the mechanism is settled; the numbers are not. What is the write stall at writer-lock handover under load, what drain deadline avoids LMDB free-list growth from a long-lived reader, and what does a realistic handler build actually cost against the accepted 30 s budget?

Closed since the last revision:

- **Connector daemon architecture** (OQ-019) — there is no connector daemon. Connector polling is a scheduled event, so it is `every` on the connector's own table and runs under the one scheduler
- **Multi-daemon supervision** — replaced by the generation pool above. Schema changes need no restart, so the supervisor's job is registering artifacts and sequencing swaps rather than draining the schema daemon
- **`hint` as an escape hatch** — abandoned rather than deferred. The requirement was arbitrary Haskell for integrations; handlers get it from a compiled pool with no in-process GHC
