# Technology Stack

Decisions here are the resolved answers from [open-questions.md](open-questions.md);
each is cross-referenced to the OQ that settled it and the spike that validated it.

## Language

**Haskell** (GHC). Chosen for:

- Strong static type system — essential for encoding category-theoretic constraints
- GADTs plus `DataKinds`, which make the effect ladder a typing property of the interpreted
  term language, and `Data.Dynamic` for an O(1)-checked type registry. This replaces
  "typeclasses as the mechanism for functor composition", written before OQ-001: a functor is a
  DSL term walked as data, and typeclass dispatch is compiled and opaque, which the transparency
  requirement rules out. See
  [dynamic-loading.md](dynamic-loading.md#the-dsl-is-indexed-by-effect)
- Lazy evaluation — useful for streaming large query results
- Mature ecosystem for parsing, serialization, networking, and concurrency

Every DataCode executable is linked with `-threaded` (`ghc-options: -threaded`), which the LMDB
binding requires. It is a link-time option on the program, not a property of the GHC
installation — every stock GHC ships the threaded RTS, so no custom compiler build is a
prerequisite on a node. See [Storage](#storage).

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
| **Cap'n Proto** | **Chosen for production.** Zero-copy via mmap, additive schema evolution, encode and decode below timer resolution |
| `cereal` | **Chosen for development.** Identical wire framing, no external toolchain. Ceiling: schema evolution needs an explicit version byte and branching decoder |
| Protobuf | Ruled out — requires full parsing; Cap'n Proto mmaps the bytes directly |
| MessagePack | Ruled out — no schema evolution story |

The migration path is cheap because the framing is identical (length prefix + single-segment
message header); only the payload encoding changes. Swap `Serialize` instances for
capnp-generated `Cerialize`/`Decerialize` before production.

What the spike confirms, and what it does not. Framing and the zero-copy read are validated —
by a hand-written encoder, not by the `capnp` code generator the production path uses, so the
generated `Cerialize`/`Decerialize` instances are still untested. Schema evolution is confirmed
for **field addition in both directions**: a V1 message read by a V2 decoder reads 0 for the new
field; a V2 message read by a V1 decoder silently ignores the extra data word. No version byte,
no branching decoder, no migration step.

That is also the limit of Cap'n Proto's guarantee — *additive and ordinal-stable* — so removing
a field, changing its type, or reusing an ordinal still breaks readers, and `TxNode` is bound by
that discipline. The 8-byte figure is one added **data-section scalar** (V1 = 112 bytes,
V2 = 120). A **pointer** field is not that: it costs one pointer word on every message, forever,
plus its content, and no spike has measured one. Confirmed in `spikes/capnproto/output.txt`.

Encode and decode are both **below timer resolution** — a 10,000-iteration benchmark reported
0 ms, which is < 1 µs/tx and equally consistent with laziness eliding the work. OQ-003 carries
that caveat and it stands. Force the result before the next recorded run cites a number.

A decoder's implicit zero is not a value. A row written under an older schema node decodes
short, and the field reads its declared default, not 0 — see
[evolution.md](schema/evolution.md#redeclare-a-table).

Requires the `capnp` C++ tool at compile time (`apt install capnproto`).

## Storage

**Decided (OQ-004).** Hybrid: a custom append-only log for the transaction graph plus two
LMDB databases per shard for indexing. RocksDB is not used.

The transaction graph is an append-only log of length-prefixed Cap'n Proto frames, mmap-readable
without deserialization. `head_index` resolves a `DataId` to a `PhysicalLocator` and `log_index`
resolves a locator to a file offset and length. Key widths and the full read path are in
[storage.md](storage.md#2-two-lmdb-databases-per-shard). The physical address is a
`PhysicalLocator`; the spike code's `RowId` is the name OQ-004 retired, because "the id of a row"
is what `DataId` means.

LMDB was chosen over RocksDB: memory-mapped reads touch the OS page cache rather than
copying, MVCC means readers never block writers, and it is crash-safe by default
(copy-on-write B-tree with two root pages, no separate WAL). The LSM-tree write advantage
RocksDB offers is not needed — the append-only log absorbs the write path.

**LMDB needs a bound thread.** The `lmdb` package calls `isCurrentThreadBound` before acquiring
its write lock, and without `-threaded` that always returns `False`. The pattern — a
session-level `runInBoundThread`, one dedicated `forkOS` thread for writes fed by a `TQueue`,
reads concurrent under MVCC — is in [storage.md](storage.md#lmdb-threading); the working code is
`spikes/capnproto/src/Spike/LmdbFixed.hs`.

**Latency**: reads 11 µs/op, writes 1,107 µs/op, the write dominated by `fdatasync()` on every
commit. Not a concern — DataCode batches 10–100 mutations per transaction, giving 11–110
µs/mutation, so single-mutation micro-benchmarks are unrepresentative. Detail in
[storage.md](storage.md#lmdb-latency).

### No second engine for materialized views

**Decided.** No second storage engine backs a materialized view — not SQLite, not a separate
embedded store. A table, a query, and a derived table are one kind of thing, so a view's rows
*are* rows: they already have a format, an index, a locator indirection, a compactor, a scrubber,
a backup story, and a wire protocol. A second engine adds a second of each, plus a serialization
boundary that breaks the zero-copy read for that path. The two new physical concepts are a
derived extent and an arrangement — an arrangement being one LMDB sub-database per view and
order, in the shard's existing environment, which is also what an index is. Both live in
[storage.md](storage.md#materialization).

DuckDB is worth having as an Arrow or Parquet **export target** from a tertiary. It is never an
engine.

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

`Text.Regex.TDFA` is the engine behind `=~`. `spikes/functor-dsl` uses a stand-in matcher and
validates the primitive's provenance restriction and compiled-pattern cache rather than the
engine itself — see [The regex engine](#the-regex-engine) for what is measured and what is not.

## The regex engine

**Decided.** `Text.Regex.TDFA` (`regex-tdfa` 1.3.2.6) stays, and **POSIX character classes are
rejected at schema commit** rather than swapping to a Unicode-aware engine.
[railroad.md](schema/railroad.md#functions-and-expressions) owns the rejection rule and the
restriction on `=~`'s right operand; the reasoning is here because it is an engine choice.

**Why the classes go and the engine stays.** TDFA implements POSIX classes over ASCII only, so
`é` (U+00E9) does not match `^[[:alpha:]]$` under either the `String` or the `Text` instance, and
an internationalised validation silently rejects valid names. Fixing that inside TDFA is not
available: a class is enumerated into a `Set Char`, and a DFA state's transitions are an `IntMap`
keyed by code point, so a Unicode-correct `[[:alpha:]]` is roughly 132,000 transitions per DFA
state. The representation is per code point, not per range, so the choice is the engine or the
classes.

`regex-rure` is the only real contender and is technically superior — RE2 family, worst-case
O(mn) time, a bounded lazy-DFA cache that falls back to a PikeVM rather than growing, and
Unicode-aware by default. Against it:

- It is FFI to `librure`, built from the Rust `regex-capi` crate, so a Rust toolchain joins the
  build and a shared object joins every node.
- It sits at 0.1.2.1 with a *deprecated* 1.0.0.0 above it, which is not a maturity signal.
- Its syntax is Rust-regex, not POSIX ERE, so `=~`'s documented semantics change. **A pattern is
  schema**, so an engine swap after patterns are in the graph re-interprets stored schema. The
  window for a free swap closes at the first production cluster, not at the first pattern.

What staying buys: pure Haskell, no FFI, nothing to ship on every node, and a match that is
byte-reproducible across replicas — which matters because replicas must reach the same validation
verdict on the same row. TDFA also has no backreferences and no lookaround, so the two
catastrophic-backtracking vectors are absent.

**The escape is a predicate, not a class.** Named predicates are ordinary functions and
`Data.Char.isAlpha` is already Unicode-aware, so internationalised validation is written as a
predicate. Only an author-written regex class is exposed, and it fails at commit rather than
silently at read. Revisit `regex-rure` only if Unicode classes become a requirement of the
pattern language itself; performance is not the argument that would flip it.

### Engine properties the interpreter pins

Three, none of them inherited from the library defaults:

- **`multiline = False`.** The library default is `True`, which makes `^…$` a *line* anchor:
  `^[a-z]+$` matches `"abc\nDROP TABLE"`. Every anchored validation and access assert would be
  bypassable by an embedded newline.
- **Compile through `Text.Regex.TDFA.String.compile`**, which returns `Either String Regex`. `=~`
  and `makeRegex` are partial — a malformed pattern raises an impure `error` — so the interpreter
  never calls them, and `isValidRegex` is built on `compile`.
- **A commit-time pattern budget**, held in `system.config.PatternPolicy`: bounded-repetition
  product along any nesting path, expanded node count, and source length. TDFA is linear in
  *time* in the subject and unbounded in *memory*, because it builds its DFA lazily and caches
  states. Measured on 1.3.2.6 / GHC 9.10.3, the ten-character pattern `(a|b){800}` against a
  3,000-character subject exhausted a 3 GB heap in about 12 s, and a seventeen-character
  pattern's saturated cache held 38 MB. This replaces "TDFA is a DFA engine, so a pathological
  pattern costs no more than a linear scan", which is false — a DFA bounds backtracking, not the
  DFA.

`CompOption` also carries `caseSensitive`, which is what makes a pattern row's `case_sensitive`
field a library setting rather than a second matching mode.

**Validation status.** `regex-tdfa-1.3.2.6` and `regex-base-0.94.0.3` compile clean on GHC
9.10.3; `regex-base` is the only Hackage dependency and every other dependency ships with GHC.
The earlier record that the engine "cannot be installed in the development sandbox" was wrong:
what fails is `cabal` writing its build log under a read-only `$HOME`, before the compiler runs.
The measurements above come from a hand-built probe, so the engine is evidenced but is not yet
part of the recorded spike set.

## GHC on every node

The four-process topology, the generation swap, and build-then-merge are in
[dynamic-loading.md](dynamic-loading.md#process-topology). Write authority hands over with no new
mechanism, because LMDB's writer lock is cross-process and OS-enforced — see
[Generation swap](dynamic-loading.md#generation-swap).

One consequence is a stack decision and belongs here. **GHC runs on every data node**, which is
accepted and costs two things worth recording:

- A node becomes a provisioned host rather than a dropped binary.
- The GHC version joins the compatibility surface, so a generation artifact is valid only for its
  `(schema node, DataCode version, GHC version, arch)` tuple. Content-addressing the generation
  registry on that tuple makes cross-host artifact sharing a later cache lookup rather than a
  redesign.

## Concurrency

`stm` for in-process concurrency — coordination between incoming requests, background
replication, and view materialization.

`async` for structured concurrency of background tasks (replication, view materialization,
peer gossip).

`TQueue` plus a dedicated `forkOS` bound thread for the LMDB write path, as under
[Storage](#storage).

## Testing

- `hspec` or `tasty` for unit and integration tests
- Property-based testing with `QuickCheck` or `hedgehog`, which the design earns because it
  states invariants an implementation can be tested against: path-equivalence commutativity,
  `enforce forward` replay determinism, aggregate merge associativity and identity, `is`/`==`
  agreement, and interpreter determinism. "Functor laws" was in this list and is out — no
  document states a law for any of the four functor kinds, and by
  [category-model.md](category-model.md)'s own account foreign keys are the *arrows* of the
  schema category, so the phrase named an obligation an implementer cannot discharge
- Feasibility spikes live in `spikes/` as small standalone Haskell projects

## Build System

`cabal` (with `cabal.project` for multi-package layout). `stack` is an option but cabal's
solver has improved significantly and is preferred for new projects. Multi-package monorepo
from the start:

- `datacode-core` — category model, types, transaction graph
- `datacode-server` — shared server library, plus the router, data-worker, and governor
  executables
- `datacode-handlers` — the handler pool. A separate package because it is versioned and shipped
  independently of the data plane, which is what
  [dynamic-loading.md](dynamic-loading.md#handler-workers-are-a-separate-pool) argues for
- `datacode-client` — thick client library
- `datacode-schema-dsl` — schema definition language and interpreter
- `datacode-html` — HTML rendering engine

External build-time dependencies: `capnproto` (C++ tool, for the production wire format) and the
LMDB system library. Nothing else joins that list — keeping the regex engine pure Haskell is what
keeps a Rust toolchain out of it, and that is part of what the engine choice bought.

## Remaining Open Technology Decisions

The stack decisions above are settled. Still open:

- **Graph layout library for the IDE** (OQ-021) — ELK.js client-side vs. `graphviz` server-side
- **Unicode normalization library.** Case folding is `Data.Text.toCaseFold`, which ships with
  `text`, but NFC does not: it is `text-icu` (FFI to ICU, so the Unicode version tracks a system
  library) or `unicode-transforms` (pure Haskell, version pinned by the package). The choice is
  load-bearing because a canonicalizing type transform runs on the write path — two nodes on
  different normalization tables would store different bytes for one input, and the stored form is
  what `unique` and every index compare
- **Generation swap and build latency** — the mechanism is settled; the numbers are not. What is the write stall at writer-lock handover under load, what drain deadline avoids LMDB free-list growth from a long-lived reader, and what does a realistic handler build actually cost against the accepted 30 s budget?

Closed since the last revision:

- **Connector daemon architecture** (OQ-019) — there is no connector daemon. Connector polling is a scheduled event, so it is `every` on the connector's own table and runs under the one scheduler
- **Multi-daemon supervision** — replaced by the generation pool above. Schema changes need no restart, so the supervisor's job is registering artifacts and sequencing swaps rather than draining the schema daemon
- **`hint` as an escape hatch** — abandoned rather than deferred. The requirement was arbitrary Haskell for integrations; handlers get it from a compiled pool with no in-process GHC
