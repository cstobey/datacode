# Technology Stack

## Language

**Haskell** (GHC). Chosen for:
- Strong static type system — essential for encoding category-theoretic constraints
- Typeclasses as the mechanism for functor composition and inheritance
- Lazy evaluation — useful for streaming large query results
- Mature ecosystem for parsing, serialization, networking, and concurrency

## Network Layer

### Warp
`warp` is the de facto Haskell HTTP server. It is fast, well-maintained, and used in production by many Haskell web applications. DataCode will use Warp as the underlying HTTP engine.

### Servant
`servant` provides a type-level DSL for defining HTTP APIs in Haskell. Its primary appeal for DataCode:
- APIs are first-class types — the type system enforces that handlers match the declared API shape
- Content-type negotiation is built in — maps naturally to DataCode's multi-format dispatch
- Client generation is automatic — a Servant API definition can generate both server handlers and client stubs

**Critical open question**: Servant's API types are defined at compile time. DataCode's schema — and therefore its API — is dynamic. Can Servant accommodate this?

Options being evaluated:
1. **Static meta-API + dynamic `Raw` endpoints**: Servant defines the system-level API (auth, schema introspection, admin) as a static type; data endpoints fall through to a `Raw` WAI handler that dispatches dynamically based on the schema at request time.
2. **Servant for structure, WAI for data**: Use Servant for the static scaffolding and write the data plane as plain WAI middleware.
3. **Abandon Servant for data endpoints**: Use only Warp + WAI for the data plane; use Servant only if it provides clear value for the meta-API.

*Requires feasibility spike before committing.* See `open-questions.md`.

### Yesod
Evaluated and tentatively **not chosen**. Yesod is a full-stack web framework that provides routing, templating, session management, and form handling. For DataCode:
- DataCode is building its own data layer — Yesod's Persistent ORM is actively counterproductive
- Yesod's template system (Hamlet/Lucius/Julius) could be useful for HTML rendering, but DataCode needs programmatic schema-driven rendering, not template-driven rendering
- Yesod adds significant complexity without clear benefit given DataCode's requirements

*Worth a quick prototype to validate this assumption*, as Yesod's type-safe routing and session management might still be useful for the thin-client HTML layer.

## Serialization

### JSON
`aeson` — standard, well-optimized Haskell JSON library. Used for third-party JSON API.

### Binary (Replication Protocol)
TBD. Candidates:

| Library | Pros | Cons |
|---|---|---|
| `cereal` / `binary` | Simple, fast, Haskell-native | No schema evolution story; brittle across versions |
| Cap'n Proto (`capnproto-haskell`) | Schema evolution, zero-copy, fast | Complex, less mature Haskell bindings |
| MessagePack | Simple, fast, multi-language | No schema evolution |
| Custom format | Full control, carries provenance metadata | Significant implementation work |

DataCode's replication format must carry: type provenance, schema graph node reference, sequence numbers, and shard identity. This argues for either Cap'n Proto or a custom format. **Requires decision.**

## Storage

Storage engine is TBD. The transaction graph model (append-only DAG) maps well to:
- **LMDB**: memory-mapped B-tree, very fast reads, Haskell bindings available (`lmdb-simple`)
- **RocksDB**: LSM-tree, fast writes, compaction — better for write-heavy logs shards (`rocksdb-haskell`)
- **Custom append-only log**: simplest model for the transaction graph itself; B-tree index on top for query access

Likely: hybrid storage where the transaction graph is a custom append-only log, and query indexes are LMDB or RocksDB depending on shard type. **Requires investigation.**

## Concurrency

`stm` (Software Transactional Memory) for in-process concurrency. Haskell's STM is mature and well-suited for the coordination between incoming requests, background replication, and view materialization.

`async` for structured concurrency of background tasks (replication, view materialization, peer gossip).

## Testing

- `hspec` or `tasty` for unit and integration tests
- Property-based testing with `QuickCheck` or `hedgehog` is particularly important given the mathematical invariants (path equivalence, functor laws, idempotency)
- Feasibility spikes (see `dynamic-loading.md`) will each be small standalone Haskell projects

## Build System

`cabal` (with `cabal.project` for multi-package layout). `stack` is an option but cabal's solver has improved significantly and is preferred for new projects. The project will likely be a multi-package monorepo from the start:
- `datacode-core` — category model, types, transaction graph
- `datacode-server` — server daemons, replication, networking
- `datacode-client` — thick client library
- `datacode-schema-dsl` — schema definition language and interpreter
- `datacode-html` — HTML rendering engine

## Open Technology Decisions

- Binary replication format (Cap'n Proto vs. custom)
- Storage engine (LMDB vs. RocksDB vs. custom)
- Dynamic loading mechanism (see `dynamic-loading.md`)
- Servant viability for dynamic schema endpoints
- Yesod evaluation for thin-client HTML layer
