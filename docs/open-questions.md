# Open Questions and Deferred Decisions

Questions that need answers before or during implementation. Grouped by urgency.

## Must Resolve Before Writing Core Code

### OQ-001: Dynamic Loading Mechanism ✓ ANSWERED
**Answer**: GADT DSL + Data.Dynamic hybrid. See `spikes/dynamic-loading/output.txt`.
- **GADT DSL** (Approach 2): primary functor mechanism. All five functor types must be encodable: validation, foreign key, path equivalence, access control, and event (the event functor enqueues a work item rather than executing immediately — see Event System in `schema.md`). Spike validated the first four; event functor requires a DSL extension that produces an `EventRef` (queue table row insert) instead of `Either Error a`. Zero runtime GHC dependency. ~0µs apply latency. Ceiling: regex and recursive types require DSL extensions; user-defined functions require new DSL constructors.
- **Data.Dynamic** (Approach 3): type registry substrate. TypeRep-based type checking is O(1). Serves as the "registered type library" that the DSL references by name.
- **hint** (Approach 1): failed to compile in the spike — GHC not on PATH or hint version mismatch. Revisit as an escape hatch for advanced user-defined functors; compile async and sandbox the result.
- **Multi-daemon**: needed when compiled-in types must change (requires server restart to load new Haskell modules); the schema daemon restarts are coordinated by a supervisor.

### OQ-002: Servant + Dynamic Schema ✓ ANSWERED
**Answer**: Servant + Warp works. The pattern is `"schema" :> Capture "ns" String :> Capture "name" String :> Raw`. Servant handles the static URL structure; the `Raw` endpoint delegates to an IORef-backed WAI dispatch table for runtime-dynamic routing. No Yesod needed for the data plane. See `spikes/servant-warp/output.txt`.

### OQ-003: Binary Replication Format ✓ ANSWERED
**Answer**: Cap'n Proto for production; cereal during initial development. See `spikes/capnproto/output.txt`.
- **cereal** (used in storage spike): same length-prefix framing as Cap'n Proto, no external toolchain, identical structural design. Ceiling: schema evolution requires an explicit version byte and branching decoder — adding a field to `TxNode` breaks old decoders without code.
- **Cap'n Proto confirmed** (capnproto spike): wire format implemented and validated. Encode/decode round-trip passes all fields including parent RowId lists. Encode and full decode both sub-µs (timer resolution of 10k-iteration benchmark insufficient to distinguish; confirmed < 1µs/tx).
- **mmap zero-copy confirmed**: 112-byte TxNode message written to disk, mmap'd back, fields read at fixed byte offsets (e.g. timestamp at message byte 16) with no decode pass. The OS page cache backs the ByteString — no heap allocation.
- **Schema evolution confirmed**: V1 message (dataWords=2) read by V2 decoder → new field defaults to 0. V2 message (dataWords=3) read by V1 decoder → extra data word silently ignored. No version byte, no branching decoder, no migration step. V1=112 bytes, V2=120 bytes (+8 bytes for one new field).
- **Protobuf is NOT a substitute**: Protobuf requires full parsing; Cap'n Proto mmaps the bytes directly.
- **Migration path**: use `cereal` in `Serialize` instances during development; swap to capnp-generated `Cerialize`/`Decerialize` instances before production. Wire framing is identical — only the payload encoding changes. Requires `capnp` C++ tool at compile time (`apt install capnproto`).

### OQ-004: Storage Engine ✓ ANSWERED
**Answer**: Hybrid architecture confirmed. See `spikes/storage/output.txt` and `spikes/capnproto/output.txt`.
- **Append-only log** (Cap'n Proto frames on disk): the transaction graph. Immutable, sequentially written, mmap-readable without deserialization. Random access by `LogEntry { offset :: Word64, length :: Word32 }` is O(1) seek+read.
- **LMDB `log_index`** (`RowId → LogEntry`): finds any row version in the append log by RowId. Keys are 14-byte big-endian RowIds; big-endian encoding means a range scan over all rows in a transaction is a single contiguous LMDB range.
- **LMDB `head_index`** (`DataId → current RowId`): resolves the user-visible primary key to the current head version.
- **Full zero-copy read path**: `DataId → head_index → RowId → log_index → (file_offset, len) → mmap[offset:len] → Cap'n Proto → pointer arithmetic`.
- **LMDB threading fix confirmed**: requires `-threaded` in ghc-options AND wrapping the LMDB session in `runInBoundThread` (session-level, not per-operation). The `lmdb` Haskell package calls `isCurrentThreadBound` before acquiring its write lock; without `-threaded`, this always returns False. See `spikes/capnproto/src/Spike/LmdbFixed.hs`.
- **LMDB latency**: read 11µs/op, write 1,107µs/op. Write latency is high because LMDB calls `fdatasync()` on every transaction commit by default (durability guarantee). **This is not a problem** — DataCode batches multiple mutations into a single transaction. At 10–100 mutations/tx, the per-mutation cost is 11–110µs, which is acceptable. Single-mutation micro-benchmarks are not representative of production write patterns.
- **Production LMDB pattern**: dedicate one OS-bound thread (via `forkOS`) for all LMDB writes, with a `TQueue` for serialization. Readers are concurrent (LMDB MVCC — readers never block writers).

### OQ-026: API Version Token Format ✓ ANSWERED
**Answer**: Three interchangeable version token types, all valid as the `{version}` segment in `/v{version}/...` API paths:

- **Graph node hash prefix** (canonical default): content-addressed, always deterministic. The underlying identity of every schema node. Guaranteed unambiguous across servers, shard splits, and merges.
- **Tag**: a fixed-point alias for a specific graph node. Tags do not move after creation. Techs attach tags to commits as part of a transaction; tags are the expected primary UX for human-readable version pinning (e.g. `v2.1.0`, `stable-2026-q2`).
- **Branch name**: a moving alias that always resolves to the current HEAD of a named branch (e.g. `main`, `experiment-checkout`). Advances automatically as new commits land on that branch.

All three resolve to the same thing at dispatch time: token → schema graph node hash → routes registered at that node. The hash prefix is the lowest-level escape hatch that works even when no tag or branch name has been declared.

**No-version behavior**: Requests without a version token are routed to the `main` branch HEAD by default. The server can also route unversioned requests across A/B test branches at a configurable rate; routing decisions persist via session affinity so the same client consistently receives the same branch across requests.

**Promoting a version going forward**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch is currently designated. The `/versions` discovery endpoint lists all live tokens and marks the promoted one. Together these allow operators to tell existing clients "use this tag from now on" without requiring client code changes.

**Policy**: All branches must be named — anonymous DAG forks are not permitted. The `main` branch cannot be deleted. See the Branch and Tag lifecycle documentation in `schema.md`.

### OQ-027: API Functor Type and Transaction Semantics
**Question**: How is an API functor typed, and what are its transaction guarantees when it both reads and writes?
**Details**:
- A validation functor is `a -> Either Error a`. An API functor needs: path parameters + optional request body as input; response body + HTTP status as output
- If a functor both reads and writes, does the read reflect the committed write (same transaction) or the pre-write snapshot?
- How does the functor signal HTTP-level errors (404, 409, 422) vs. internal errors (500)?
- Can an API functor trigger connector side effects (e.g., send an email via a connector functor as part of the same transaction)?
**Action**: Design the API functor type signature; determine if it is a new functor kind or a composition of existing kinds (likely a new kind given its HTTP-aware interface).

### OQ-028: Route Conflict Resolution
**Question**: When a custom route template overlaps with an auto-generated route, which takes precedence?
**Details**: Example: the auto-generated route for `app.commerce.orders` produces `/v{N}/records/app.commerce.orders/{id}` for GET. If a user also inserts a custom route with template `/records/app.commerce.orders/{id}`, both exist. Options:
- Custom routes always shadow auto-generated routes at the same path
- Auto-generated routes take precedence; custom routes must use different paths
- Conflict is a validation error at insert time — the system rejects the custom route row
**Action**: Choose a rule and enforce it at commit time in the `system.api.custom_routes` write path.

### OQ-029: Route Trie vs. Dispatch Table Implementation ✓ ANSWERED
**Answer**: Hand-rolled route trie. See `spikes/route-trie/output.txt`.
- **Route trie confirmed**: 0.2µs/request at 10k registered routes — well under the 1µs target. O(depth × log fanout), independent of total route count.
- **Linear scan ruled out**: 1µs at 100 routes, 13µs at 1k routes, 132µs at 10k routes. Scales O(n) — fails the target beyond a handful of custom routes.
- **wai-routes ruled out**: uses Template Haskell compile-time route tables — incompatible with DataCode's runtime-registered custom routes.
- **path-piece ruled out**: a type class for parsing individual path segments, not a router.
- **Precedence**: static segments always beat captures at the same depth — correct, deterministic, matches every mainstream router.
- **Integration**: replace `IORef (Map String Application)` in the Servant `Raw` handler with `IORef (RouteTrie Application)`. Schema changes rebuild the trie and atomically swap the IORef — zero request interruption.
- **Conflict resolution** (answers OQ-028 partially): exact-path conflicts are a schema validation error at insert time. The trie's `nodeHandler` slot can only hold one handler; inserting a duplicate pattern is rejected.

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

### OQ-013: Yesod Evaluation ✓ ANSWERED
**Answer**: Yesod not needed for the data plane. Defer to thin-client HTML layer, which is post-MVP.
- The Servant + Warp spike (OQ-002) confirmed that Servant's type-safe routing, combined with a WAI IORef dispatch table, covers all DataCode data plane needs at 1µs/request overhead.
- Yesod would add session management and HTML templating that are irrelevant to a JSON/binary API server.
- Revisit Yesod only if the thin-client HTML layer warrants it — after the data plane is shipping.

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

### OQ-017: PostgreSQL Logical Replication ✗ NOT DOING
**Decision**: Deprioritized for v1. The company primarily uses MariaDB/MySQL, which is the required replication source. `postgresql-replicant` is abandoned; a fork or rewrite is not worth the investment now. Revisit post-v1 if there is demand.

### OQ-018: Redis CDC Approach ✗ NOT DOING
**Decision**: Deprioritized for v1. No viable transparent Haskell library; Redis Streams requires source changes; sidecar adds operational complexity. Not worth it for v1. Revisit post-v1 if needed.

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
