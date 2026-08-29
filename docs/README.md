# DataCode documentation

Start with [vision.md](vision.md), then [category-model.md](category-model.md).

This file indexes every document. [open-questions.md](open-questions.md) is the decision
record — check it before proposing a design change.

## Foundations

| Document | Covers |
|---|---|
| [vision.md](vision.md) | What DataCode is, why build it, differentiators, non-goals |
| [category-model.md](category-model.md) | The governing monad, the four functor kinds and why they are four, reified failure, denotative time in two coordinates, path equivalence (Spivak) and coercion as Δ, transparency, absence as a `Null`-rooted ADT family |

## Language

The schema language is specified in [schema/](schema/), one file per topic.
[schema/railroad.md](schema/railroad.md) is the single source of syntax truth: it holds the
full EBNF and renders to railroad diagrams.

| Document | Covers |
|---|---|
| [schema/README.md](schema/README.md) | Design philosophy, self-hosting, schema layers, notation conventions (`:` versus `:>`, clause order, backticks and `$`, layout, addressing validations) |
| [schema/railroad.md](schema/railroad.md) | The full EBNF for the schema language and the CLI, plus one-line bullets for the constraints the grammar cannot express |
| [schema/types.md](schema/types.md) | Primitives, domain types, sum and product types, `Moment` and `Behavior`, `Duration`/`Period`/`Grain`, absence types, canonical types, `File`, `is`, `Secret`, `Hashed`, `Encrypted` |
| [schema/tables.md](schema/tables.md) | Table bodies, field declarations, defaults, candidate keys and placement, changing a placement key, ordering, foreign keys and delete restriction, inline sub-tables, back-references (`:<`) |
| [schema/traits.md](schema/traits.md) | Trait declaration, multiple inheritance, replication traits, the marker traits `Component`, `Keyless`, `Personal` and `Extensible`, `Queue`/`QueueState`, `Reference` tables, UI hints |
| [schema/constraints.md](schema/constraints.md) | `assert`, the two varieties and how the body decides which, anchoring, redaction scope, schema-level access and bypass, the standalone form |
| [schema/documents.md](schema/documents.md) | The `Doc` type, storage before shredding, key interning and spill, key shape rules, demotion |
| [schema/aggregates.md](schema/aggregates.md) | Aggregate functions, mergeable aggregates, rollups as parameterized bindings, `retain` chains and the levels they generate, log retention |
| [schema/templates.md](schema/templates.md) | Templates as `Reference` rows, cardinality as control flow, `using`, escaping by type |
| [schema/evolution.md](schema/evolution.md) | Redeclaration and diff, rename, retype, the added-field default rule, deprecate and prune, split and merge, ADT extension, visibility, coercion between schema nodes |
| [schema/queries.md](schema/queries.md) | Filter, projection, joins, grouping, nesting, aggregates, ordering, `limit` and cursor pagination, derived tables, mutation, historical queries and `diff` |
| [schema/functions.md](schema/functions.md) | Scope, the effect ladder, Haskell functions and `import`, infix application, time as a parameter, function types, function-valued columns |
| [schema/functors.md](schema/functors.md) | The four functor kinds, order of operations for a write and for a read, enforcement modes |
| [namespaces.md](namespaces.md) | Namespace tree, name resolution, connector namespaces, visibility levels, namespace ACL |

## Engine

| Document | Covers |
|---|---|
| [transaction-graph.md](transaction-graph.md) | Append-only DAG, `system.graph.Transaction`, branches and tags (`system.schema.Branch`, `system.schema.Tag`), data shards, re-key records, `DataId`, component ordinals, `TxPosition` and `PhysicalLocator`, virtual columns |
| [storage.md](storage.md) | Append-only log and the per-shard indexes, version-chain and reverse-FK scans, extents, file chunks, Cap'n Proto frames, zero-copy reads and the reader fence, replication wire format, materialization, scrubbing |
| [distribution.md](distribution.md) | Server roles, the range tree, elevation and failback, push/fetch replication, schema and constraint shards, cross-shard transactions, bulk mutations, shard splits, durability classes, cold shards, geo-diversity |
| [tech-stack.md](tech-stack.md) | Library and format decisions, with the OQ and spike that settled each; the regex engine; GHC on every node |
| [dynamic-loading.md](dynamic-loading.md) | GADT DSL + `Data.Dynamic`, process topology, generation swap; full addendum of options considered |

## Interfaces

| Document | Covers |
|---|---|
| [cli.md](cli.md) | Invocation, REPL and transaction model, admin and disaster-recovery commands, output formats and paging, scripting |
| [ide.md](ide.md) | Admin IDE — ER diagram, sidebar, functor editor, schema visibility |
| [api.md](api.md) | Route registration, versioning, HTTP dispatch, transaction semantics, status codes, request logging |
| [api-and-rendering.md](api-and-rendering.md) | Content-type dispatch, octet-stream responses for `File`, the JSON API, HTML rendering, themes, information density |
| [auth.md](auth.md) | Token types, the `Client`/`Registration` split, device registration, credential storage, envelope encryption and key custody, challenge methods, login, access control functors |

## Integration and operations

| Document | Covers |
|---|---|
| [connectors.md](connectors.md) | External data ingestion, the two GTID dialects, sync protocol, re-seed from state, schema auto-discovery, conflict resolution |
| [events.md](events.md) | Event scheduler, the two trigger forms, queue tables, priority, handlers, volume-based backoff, repair queues, behavior-triggered scheduling |
| [integrity.md](integrity.md) | Nonconformance, enforcement modes, the violations table, admin reporting, erasure and scrubbing, retention |

## Status

[open-questions.md](open-questions.md) tracks answered and outstanding design decisions
(OQ-nnn), grouped by urgency. It is the decision record — answered entries carry the
reasoning and the spike that settled them.

## Spikes

Feasibility studies live in `spikes/`, outside this directory. Each is a self-contained
cabal project whose `output.txt` holds the recorded run cited by the answered OQs. Read
that file rather than rebuilding.

| Spike | Settles | Result |
|---|---|---|
| `spikes/functor-dsl` | OQ-001 | Effect-indexed GADT over the full current syntax; all four kinds, both event forms, the structural analyses |
| `spikes/dynamic-loading` | OQ-001 | Superseded for its DSL claims by `functor-dsl`. Remains the record for ruling out `hint` and for the option comparison |
| `spikes/servant-warp` | OQ-002 | Servant static frame + `Raw` delegating to a WAI dispatch table |
| `spikes/capnproto` | OQ-003, OQ-004 | Cap'n Proto wire format, mmap zero-copy, LMDB threading fix |
| `spikes/storage` | OQ-004 | Append-only log + two LMDB indexes; locator sort order |
| `spikes/route-trie` | OQ-029 | Hand-rolled trie at 0.2µs/request across 10k routes |
