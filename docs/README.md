# DataCode Documentation

Start with [vision.md](vision.md), then [category-model.md](category-model.md).

## Foundations

| Document | Covers |
|---|---|
| [vision.md](vision.md) | What DataCode is, why build it, differentiators, non-goals |
| [category-model.md](category-model.md) | The governing monad, the four functor kinds and why they are four, path equivalence (Spivak), transparency, absence as a `Null`-rooted ADT family |

## Language

The schema language is specified in [schema/](schema/), one file per topic.
[schema/railroad.md](schema/railroad.md) holds the full EBNF and renders to railroad
diagrams.

| Document | Covers |
|---|---|
| [schema/README.md](schema/README.md) | Design philosophy, visibility layers, notation conventions (`:` vs `:>`, clause order, layout) |
| [schema/types.md](schema/types.md) | Primitives, domain types, sum types, `Moment` and `Behavior`, `Duration`/`Period`/`Grain`, absence types, `is`, `Secret` and `Hashed` |
| [schema/tables.md](schema/tables.md) | Table bodies, fields, defaults, candidate keys, ordering, foreign keys, sub-tables |
| [schema/traits.md](schema/traits.md) | Traits, multiple inheritance, replication traits, `Component`, `Keyless`, `Extensible`, `Queue`/`QueueState` |
| [schema/constraints.md](schema/constraints.md) | `assert`, path constraints, presence and absence, access control |
| [schema/documents.md](schema/documents.md) | The `Doc` type, shredding, key interning |
| [schema/aggregates.md](schema/aggregates.md) | Aggregate functions, mergeable aggregates, `retain` chains, log retention |
| [schema/templates.md](schema/templates.md) | Templates as text with holes, cardinality as control flow, `using`, escaping by type |
| [schema/evolution.md](schema/evolution.md) | Redeclare, rename, retype, deprecate, prune, split, merge, ADT extension |
| [schema/queries.md](schema/queries.md) | Filter, projection, joins, grouping, derived tables, mutation |
| [schema/functions.md](schema/functions.md) | Scope, the effect ladder, auto-wrapping, function types, function-valued columns |
| [schema/functors.md](schema/functors.md) | The four functor kinds, order of operations, enforcement modes |
| [namespaces.md](namespaces.md) | Namespace tree, visibility levels, namespace ACL |

## Engine

| Document | Covers |
|---|---|
| [transaction-graph.md](transaction-graph.md) | Append-only DAG, branches and tags, shards, `DataId`, component ordinals, `PhysicalLocator` |
| [storage.md](storage.md) | Append-only log, LMDB indexes, Cap'n Proto, zero-copy reads, materialization |
| [distribution.md](distribution.md) | Server roles, the range tree, push/fetch replication, schema and constraint shards, cross-shard transactions, bulk mutations, shard splits, geo-diversity |
| [tech-stack.md](tech-stack.md) | Library and format decisions, with the OQ and spike that settled each |
| [dynamic-loading.md](dynamic-loading.md) | GADT DSL + `Data.Dynamic`; full addendum of options considered |

## Interfaces

| Document | Covers |
|---|---|
| [cli.md](cli.md) | REPL, invocation, admin and disaster-recovery commands |
| [ide.md](ide.md) | Admin IDE — ER diagram, sidebar, functor editor |
| [api.md](api.md) | Route registration, versioning, HTTP dispatch, request logging |
| [api-and-rendering.md](api-and-rendering.md) | Content-type dispatch, HTML rendering, themes, information density |
| [auth.md](auth.md) | Token types, access control functors |

## Integration and Operations

| Document | Covers |
|---|---|
| [connectors.md](connectors.md) | External data ingestion, sync protocol, conflict resolution |
| [events.md](events.md) | Event scheduler, the two trigger forms, queue tables, priority, handlers, volume-based backoff, repair queues |
| [integrity.md](integrity.md) | Nonconformance, enforcement modes, the violations table, admin reporting |

## Status

[open-questions.md](open-questions.md) tracks answered and outstanding design decisions
(OQ-nnn), grouped by urgency. It is the decision record — answered entries carry the
reasoning and the spike that settled them.

## Spikes

Feasibility studies live in `spikes/`, outside this directory. Each is a self-contained
cabal project whose `output.txt` holds the recorded run cited by the answered OQs.

| Spike | Settles | Result |
|---|---|---|
| `spikes/functor-dsl` | OQ-001 | Effect-indexed GADT over the full current syntax; all four kinds, both event forms, the structural analyses |
| `spikes/dynamic-loading` | OQ-001 | Superseded for its DSL claims by `functor-dsl`. Remains the record for ruling out `hint` and for the option comparison |
| `spikes/servant-warp` | OQ-002 | Servant static frame + `Raw` delegating to a WAI dispatch table |
| `spikes/capnproto` | OQ-003, OQ-004 | Cap'n Proto wire format, mmap zero-copy, LMDB threading fix |
| `spikes/storage` | OQ-004 | Append-only log + two LMDB indexes; locator sort order |
| `spikes/route-trie` | OQ-029 | Hand-rolled trie at 0.2µs/request across 10k routes |
