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
