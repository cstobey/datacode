# DataCode — Vision

## What it is

DataCode is a category-theoretic distributed database written in Haskell. Where relational databases are grounded in set theory and SQL, DataCode is grounded in category theory as applied to databases by David Spivak.

The core insight is that **a database schema is a category** — tables are the objects, foreign keys are the morphisms, and path equations are commutative-diagram constraints. A database *instance* is a functor from that category into `Set`. The schema is therefore a first-class mathematical object with computable properties: composability, commutativity, path equivalence. See [category-model.md](category-model.md).

DataCode also uses *functor* as the name of a kind of declared rule — validation, foreign key, path constraint, event. [category-model.md](category-model.md) defines the term and says which of those are functors in the strict categorical sense.

## Why build it

- **No NULL.** NULL is an ambiguous sentinel that conflates "not present", "unknown", "not applicable", and "error". DataCode replaces it with an ADT family rooted at `Null` — `NotFound`, `Redacted`, `NotGiven`, and whatever else a schema author declares — so the *reason* for absence is in the type and the type system forces every consumer to handle it. See [schema/types.md](schema/types.md#absence-types).
- **Data independence.** The conceptual model (what you query) is separate from the physical model (how bytes are stored), so DataCode is free to optimize storage and access transparently. A materialized view is a derived table pegged to a commit node, proposed from observed load rather than declared by an author; there is no `create index`. See [storage.md](storage.md#materialization).
- **Schema as code.** Schemas, derived tables, routes, connector configuration, event queues, auth, and user data are all nodes in the same append-only transaction graph — the self-hosting principle in [schema/README.md](schema/README.md). A table declaration, a query, and a derived table are one kind of thing; `table` keeps its keyword only because it declares storage and constraints. Versions and the coercions between them are properties of the graph rather than of a migration script, and old schema versions stay queryable. See [schema/queries.md](schema/queries.md) and [schema/evolution.md](schema/evolution.md#coercion-between-schema-nodes).
- **Auto-generated APIs and UIs.** Every field's type, validation, and relationship is declared and inspectable, so DataCode derives JSON APIs, the binary replication protocol, and rendered HTML interfaces directly from the schema — without you writing boilerplate. See [api-and-rendering.md](api-and-rendering.md).
- **Principled access control.** Authorization is not a bolt-on. An access rule and a data constraint are the *same* functor kind over the *same* schema graph, differing only in whether the requesting token is one of the terms. Access rules therefore compose, and the checker reports contradictions before deployment, within the limits [category-model.md](category-model.md) states. See [schema/constraints.md](schema/constraints.md#the-variety-is-decided-by-the-body).

## Key differentiators vs. existing databases

| Property | SQL databases | GraphQL + ORM | project-m36 | CQL / FQL | DataCode |
|---|---|---|---|---|---|
| Theoretical foundation | Relational / set theory | Ad hoc | Relational algebra | Category theory (functorial data migration) | Category theory |
| NULL | Yes (ambiguous) | Yes | No (but limited) | No | No (ADT family rooted at `Null`) |
| Schema as first-class object | No | No | Partial | Yes | Yes |
| Logical data independence | Yes (views) | No | Partial | Yes (schema mappings) | Yes (derived tables; connector layering) |
| Physical data independence | Author-declared indexes and materialized views | No | No | Not a goal | Materialization proposed from observed load |
| Schema evolution | Migrations | Migrations | Partial | Schema mappings, re-migrated in batch | Transaction graph; old versions stay queryable |
| Auto-generated API | No | Manual schema | No | No | Yes (JSON / HTML / binary) |
| Built-in auth model | Yes (`GRANT`/`REVOKE`, roles, row-level security) | No | No | No | Yes — the same functor kind as data constraints |

Two rows are worth reading carefully, because the interesting comparison is not the one a scorecard invites:

- **Auth.** SQL has had an authorization model since SQL-86, and PostgreSQL row-level security reaches the same rows a DataCode access assert does. The difference is not capability but *placement*: a `GRANT` is a second system with its own vocabulary, while an access assert is a data constraint that happens to mention the token, so one analysis covers both.
- **Data independence.** SQL delivers the logical half through views, which is why that row says yes. What indexes and materialized views deliver is the physical half, and there the author is the optimizer — DataCode proposes the arrangement from observed load instead.

**The closest prior art is CQL** (Categorical Query Language, Wisnesky and Spivak), with its predecessor FQL: a working engine and IDE for functorial data migration over algebraic databases, with uniqueness and path constraints and a chase-based instance construction. It is the existence proof that this approach is implementable, and the honest reading of the table above is that DataCode's schema model belongs to that tradition rather than departing from it. CQL is batch and integration-oriented. What DataCode adds is an OLTP-primary, sharded, geo-replicated runtime over the same formalism, and a schema that is data in the same graph as the rows it governs. See Spivak and Wisnesky, "Relational Foundations for Functorial Data Migration" (DBPL 2015, arXiv:1212.5303), and <https://categoricaldata.net/CQL/>.

## Non-goals (for now)

- Strict serializability across geo-distributed shards. A cross-shard write is a prepared node per participant plus one commit node, validated optimistically rather than locked, so conflicting chains abort rather than wait. Serialization happens at an authoritative primary, not by distributed consensus — no Paxos, no Raft. See [distribution.md](distribution.md#cross-shard-transactions).
- Non-Haskell *thick* clients. The binary replication protocol and the schema-derived client types are Haskell-only. Any language can use the generated JSON API or the HTML surface.
- OLAP-first design. DataCode is OLTP-primary, with analytical materialized views and tertiary replicas as the secondary path.
