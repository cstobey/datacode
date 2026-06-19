# DataCode — Vision

## What It Is

DataCode is a category-theoretic distributed database written in Haskell. Where relational databases are grounded in set theory and SQL, DataCode is grounded in category theory — specifically the intersection of set theory, graph theory, and type theory as formalized by researchers like David Spivak.

The core insight is that **a database schema is a category**, data elements are objects in that category, and the rules governing their relationships are functors. This makes the schema itself a first-class mathematical object with computable properties: composability, commutativity, path equivalence.

## Why Build It

- **No NULLs.** NULL is an ambiguous sentinel that conflates "not present," "unknown," "not applicable," and "error." DataCode replaces it with typed Abstract Data Types that make the reason for absence explicit and type-safe.
- **Data independence.** The conceptual model (what users query) is separated from the physical model (how data is stored). DataCode is free to optimize storage and access patterns transparently, using materialized views pegged to points in the transaction graph.
- **Schema as code.** Schemas, queries, views, and data are all nodes in the same transaction graph. A query is just a view; a view is just a table. The system manages versions, coercions, and backwards compatibility automatically.
- **Auto-generated APIs and UIs.** Because the schema is a well-defined mathematical object, DataCode can derive JSON APIs, binary replication protocols, and rendered HTML interfaces directly from the schema — without the user writing boilerplate.
- **Principled access control.** Authorization is not a bolt-on; it is a category of functors applied to the same schema graph as data relationships. Access rules compose and can be verified for consistency.

## Key Differentiators vs. Existing Databases

| Property | SQL databases | GraphQL + ORM | project-m36 | DataCode |
|---|---|---|---|---|
| Theoretical foundation | Relational / set theory | Ad hoc | Relational algebra | Category theory |
| NULL | Yes (ambiguous) | Yes | No (but limited) | No (typed ADTs) |
| Schema as first-class object | No | No | Partial | Yes |
| Auto-generated API | No | Manual schema | No | Yes (JSON / HTML / binary) |
| Built-in auth model | No | No | No | Yes (functor-based) |
| Data independence | Limited (indexes) | No | No | Yes (materialized views) |
| Dynamic schema evolution | Migrations | Migrations | Partial | Yes (transaction graph) |

## Non-Goals (for now)

- Full ACID compliance on geo-distributed writes (we use authoritative primary serialization, not distributed consensus like Paxos/Raft)
- Support for non-Haskell client runtimes (thick clients run Haskell; thin clients get HTML)
- OLAP-first design (DataCode is OLTP-primary with analytical materialized views as a secondary feature)
