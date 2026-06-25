# Open Questions and Deferred Decisions

Questions that need answers before or during implementation. Grouped by urgency.

## Must Resolve Before Writing Core Code

### OQ-001: Dynamic Loading Mechanism
**Question**: Which approach — typed DSL interpreter, `hint`/GHC API, multi-daemon, GHC dynamic linking, or a hybrid — is viable for runtime schema evolution?
**Why it's blocking**: The entire architecture of the schema daemon and query engine depends on this choice.
**Action**: Three feasibility spikes (see `dynamic-loading.md`). Estimate: 2–4 weeks of investigation.

### OQ-002: Servant + Dynamic Schema
**Question**: Can Servant's compile-time type-level API DSL accommodate DataCode's runtime-dynamic schema, or must the data plane use raw WAI?
**Why it's blocking**: Affects the entire networking layer design.
**Action**: Small prototype — a Servant app with a `Raw` fallthrough that dispatches on a runtime-defined schema. Estimate: 3–5 days.

### OQ-003: Binary Replication Format
**Question**: Cap'n Proto, MessagePack, or custom binary format for server-to-server and thick client replication?
**Criteria**: Must carry type provenance, schema version reference, sequence numbers, shard identity. Must support schema evolution without breaking existing receivers.
**Action**: Evaluate Cap'n Proto Haskell bindings for maturity and schema evolution support.

### OQ-004: Storage Engine
**Question**: LMDB, RocksDB, or custom storage for the transaction graph and query indexes?
**Criteria**: Transaction graph = append-only DAG (favors log-structured); query indexes = random access (favors B-tree).
**Action**: Prototype hybrid: custom append log for transaction graph + LMDB for indexes.

## Must Resolve During Core Development

### OQ-005: Schema DSL Syntax
**Question**: What does the DataCode schema definition language actually look like? TutorialD-inspired but Haskell-native.
**Notes**: Must express tables, field types, foreign key functors, path equivalence constraints, and access control functors. Should be parseable and round-trippable.
**Action**: Design and implement a parser for the DSL as one of the first core tasks.

### OQ-006: Failure Detection and Primary Elevation
**Question**: How does the cluster detect a failed primary and who initiates elevation of a secondary?
**Options**: Heartbeat with timeout, lease-based (primary must renew a lease), or external witness node.
**Constraint**: Must not split-brain — two secondaries must not both believe they are primary.

### OQ-007: Shard Split Trigger
**Question**: Are shard splits automatic (threshold-triggered) or operator-initiated (with threshold warnings)?
**Tradeoff**: Automatic splits are convenient but can cause disruption; manual splits are safer but require operator attention.

### OQ-008: Client Token Provisioning
**Question**: How are client tokens issued and distributed to thick client deployments?
**Notes**: Client tokens are long-lived and represent an application's identity. Must be rotatable without disrupting users.

### OQ-009: Weighted Cardinality Algorithm
**Question**: What is the exact function `f(element_count, element_size)` that determines relationship rendering level?
**Notes**: Thresholds and weights should be tunable per application and overridable per field. The initial defaults need empirical validation.
**Action**: Design algorithm; validate with real schema examples before first UI implementation.

### OQ-010: PageRank Parameters for Schema Linearization
**Question**: What are the damping factor, convergence criteria, and edge weighting rules for schema PageRank?
**Notes**: Edge types (foreign key, path equivalence) may warrant different weights. Should be tunable.

## Can Defer to Post-MVP

### OQ-011: FIDO2/WebAuthn for Long-Lived Credentials
**Question**: Should the identity provider support hardware security keys?
**Notes**: Strong security improvement but significant implementation complexity. Not required for initial deployment.

### OQ-012: Analytical Query Distribution Protocol
**Question**: How exactly are distributed materialized view computations coordinated between neighboring servers?
**Notes**: The BitTorrent-style propagation model handles transaction replication; the analytical distribution model is a separate protocol.

### OQ-013: Yesod Evaluation
**Question**: Does Yesod's type-safe routing and session management provide enough value for the thin-client HTML layer to justify its inclusion?
**Action**: Quick prototype (2–3 days) to validate or rule out.

### OQ-014: D3.js Integration
**Question**: How does the HTML rendering engine decide when to use D3.js visualizations vs. plain HTML?
**Notes**: Likely a theme-level decision (some themes include D3 components). Needs more design once base HTML rendering is working.

### OQ-015: Service Accounts
**Question**: Should there be a distinct "service account" token type for machine-to-machine calls (not associated with a human user)?
**Notes**: The current model requires a user token on every request. Service-to-service calls may need a different model.

### OQ-016: The Progression of Relationship Rendering Levels
**Question**: What is the full progression from radio buttons through "shopping cart" for relationship rendering?
**Notes**: Chris indicated he can provide the full list later.
**Action**: Get the full list and incorporate into `api-and-rendering.md`.

---

## Connector and Ingestion Questions

### OQ-017: PostgreSQL Logical Replication Spike
**Question**: Is `postgresql-replicant` forkable, or must we write a PostgreSQL logical replication client from scratch against `postgresql-libpq`?
**Why it matters**: `postgresql-replicant` was abandoned in 2021 and is self-described as experimental. PostgreSQL's `wal2json` protocol is well-documented, so a from-scratch implementation is feasible but is 2–4 weeks of work.
**Action**: Evaluate `postgresql-replicant` source; determine if a fork is faster than a rewrite. Also evaluate wrapping `pg_recvlogical` as a sidecar process as a short-term alternative.

### OQ-018: Redis CDC Approach
**Question**: Redis Streams (`XREAD`/`XREADGROUP`) as explicit CDC vs. implementing PSYNC replication protocol vs. wrapping an external tool (e.g., RedisShake)?
**Tradeoffs**: Streams = simple but requires Redis source to publish to a stream (not transparent). PSYNC = transparent but significant implementation work. External tool = fastest but adds an operational dependency.
**Action**: Determine whether "transparent to the source" is a hard requirement for Redis, or whether requiring Redis Streams is acceptable.

### OQ-019: Connector Daemon Architecture
**Question**: Is the connector daemon a separate process (separate daemon alongside the schema and data daemons) or a thread pool within the main DataCode server process?
**Notes**: Separate process allows independent restart; same process is simpler. Connector failures should not crash the main server.
**Action**: Decide during core architecture design; likely a separate supervised process.

### OQ-020: Webhook Endpoint Security
**Question**: How does DataCode authenticate incoming webhooks from external services (e.g., Stripe signature verification)?
**Notes**: Each API has its own webhook authentication mechanism (HMAC, shared secret, JWT). This needs to be configurable per connector without code changes.
**Action**: Design a webhook authentication plugin interface; configuration stored in system tables.

### OQ-021: IDE Graph Layout Library
**Question**: ELK.js (client-side WebWorker), `graphviz` (server-side process), or D3.js force-directed for ER diagram layout?
**Notes**: ELK.js handles large graphs well and supports Sugiyama layout. `graphviz` is more mature but requires a server-side process. D3.js force-directed is simpler but produces less readable hierarchical layouts.
**Recommendation**: ELK.js for interactive layout + `graphviz` for static export. Needs validation.

### OQ-022: IDE Bootstrapping
**Question**: Is the IDE a separate DataCode application (its own namespace/shard) or deeply integrated into the server?
**Tradeoff**: Separate is cleaner for upgrades and lets the IDE be updated independently. Integrated avoids the bootstrapping problem (the IDE needs to work before any application schema exists).
**Notes**: The IDE must work when the only schema is `system.*` — it must not depend on application schema to render.

### OQ-023: IDE Conflict Resolution UI
**Question**: What does the manual conflict resolution interface look like?
**Notes**: When functor-based and timestamp-based resolution both fail, an operator must review. The UI needs to show: both versions of the conflicting record, the mutation history from both transaction logs, and a way to choose or merge.
**Action**: Design after the connector sync protocol is implemented.

### OQ-024: Namespace Access Control Inheritance
**Question**: Does granting access to a namespace automatically grant access to all child namespaces and tables, or must each level be granted explicitly?
**Notes**: Implicit inheritance is more convenient; explicit grants are more secure. A default-deny model with explicit grants is safer for production, but more verbose for initial setup.

### OQ-025: Connector Schema Change Propagation
**Question**: When an external schema changes (new column added to MariaDB table), how does DataCode notify users whose application schema (`app.*`) references that connector table?
**Notes**: The shadow schema is updated automatically. But if `app.commerce.orders` is a view over the connector table and a new field appears in the connector, does it automatically appear in the view, or must the user explicitly add it?
**Action**: Design the schema change notification and propagation rules; likely a configurable policy per view.
