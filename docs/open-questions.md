# Open Questions and Deferred Decisions

Questions that need answers before or during implementation. Grouped by urgency.

## Must Resolve Before Writing Core Code

**All answered.** Nothing in this group blocks the first line of core code. The entries stay
here as the decision record; each carries the reasoning and, where one exists, the spike.

### OQ-001: Dynamic Loading Mechanism ✓ ANSWERED
**Answer**: Two mechanisms, because there were two questions. Functors are
**effect-indexed GADT DSL terms**, interpreted, never compiled. Compiled-in Haskell
changes by **generation swap behind a stable router**, governed per host. A schema change
touches only the first, which is what makes zero-downtime schema evolution structural
rather than carefully engineered. See `dynamic-loading.md` and
`spikes/functor-dsl/output.txt`.

- **Effect-indexed GADT DSL**: the functor mechanism. Indexed by a typed de Bruijn
  context, an effect, and a result type. `data Eff = Pure | Read | Tx` has **no `Effect`
  rung** and there is no `Sub 'Tx 'Read` instance, so "no external calls in a commit" and
  "a behavior may not mutate" are both absent constructors rather than rules. Zero runtime
  GHC dependency; 0.07–0.8 µs per application.
- **`Data.Dynamic`**: type registry substrate. O(1) `TypeRep` checking. The registered
  type library the DSL references by name.
- **Generation pool**: router + data workers + a separate handler pool + a per-host
  governor. Replaces "the schema daemon restarts, coordinated by a supervisor", which
  conceded it had no zero-downtime story and left the supervisor unspecified.
- **`hint` is abandoned**, not deferred. The demand was arbitrary Haskell for
  integrations; handlers get it from the generation pool, with no in-process GHC and no
  sandbox problem.

**The previous answer's evidence was weaker than its claim, and this is the correction.**
`spikes/dynamic-loading` recorded "all four functor types encodable in the DSL". Its
`Expr` was a **plain ADT, not a GADT** — the module says so — so type errors surfaced at
eval time as `ValidationError "… type mismatch"`, and "type safety propagates into schema
expressions" was never tested. Two of the three wrong answers in its recorded run were
that defect leaking (a validation message masked by a `Text`-plus-`Int` concatenation; a
valid email reported invalid because `EContains` compared suffixes), and its "compose all
four functors" test composed two. `spikes/functor-dsl` supersedes it for every DSL claim;
the old spike remains the record for ruling out `hint` and for the option comparison.

**Why functors are interpreted.** The performance argument for compiling is empty —
interpretation is one to two orders of magnitude below the 11 µs LMDB read floor. Three
arguments decide it:

- **Transparency.** The query optimizer, static access analysis, `evolution.md`'s
  coercion-path derivation, and the IDE's ER diagram all consume the functor's
  *structure*. The spike implements each analysis as a pure walk over the term to show
  what is bought: assert-variety classification, the `bypass access` exemption set,
  anchoring, shard-crossing detection, revalidation sets, filter placement, call-graph
  acyclicity, and the `every`-was-unnecessary classifier.
- **Replay.** `enforce forward` compares against the predicate as it was, and re-deriving
  a `Derived` violation needs the predicate as of the violation. A term is a
  content-addressed graph node; a retired binary is not.
- **The commit path.** Compilation is an external call, so the effect ladder puts it
  outside the commit. Schema changes would become commit-then-build, and the REPL's
  `:commit` would wait on GHC.

Two arguments *against* compiling were examined and do not hold, recorded so they are not
raised again. The schema graph is one DAG with all branches present, so a compiled
artifact would hold every live named ref in **one binary** sized O(refs × schema), not one
binary per version. And historical `at` reads need only the historical row *shape* (graph
data) plus **current** access rules (OQ-027), so arbitrary-moment sampling costs the
compiled path nothing.

**Ceilings, now three rather than four.** Recursive types; a closed-form crossing solver
for behavior-triggered conditions (OQ-034 — the *classifier* is implemented, the solver is
not); and mergeable sketch types for `percentile` past one chain step (OQ-034). Closed
since the last answer: **regex** is a primitive whose provenance the effect index derives
(`StringLit`/`Reference` are `Pure` and interned at commit, `Configuration` is `Read` and
cached on the row version); **anchored presence/absence subqueries** are `Exists` over a
query whose only root constructor is `self`; and **user-defined functions** split, with
handlers escaping to the generation pool and functors becoming terms in a context of their
parameters rather than Haskell closures.

**Requirements this answer was written against**, carried over from OQ-005 and OQ-030 and
now all discharged: both event trigger forms with `every`'s interval a per-row `Read`
expression; function-typed columns with a static signature and a commit-time acyclicity
obligation; template holes in the same encoding as assert bodies; and the effect ladder as
an index rather than a signature blacklist. **One scheduler, not two** also survives —
connector polling is a scheduled event (OQ-019), so the topology is router + data workers +
handler workers + governor, with no connector daemon keeping its own time. The consequence
stands: the scheduler is on the critical path for ingest as well as egress.

**Open with the topology, not with the mechanism:**

- **Generation swap latency.** The handover primitive needs no invention — LMDB's writer
  lock is cross-process and OS-enforced, so the incoming generation blocks on it while the
  outgoing one finishes its in-flight transaction, and reads never stall at all under
  MVCC. What is unmeasured is the write stall under load and the drain deadline that
  avoids free-list growth from a long-lived reader.
- **Build latency for a handler generation.** 30 s is the accepted budget; measure it.
- **Unresolved prepared nodes become routine.** A worker killed mid-prepare leaves one,
  which is recoverable (OQ-006) but was sized as exceptional. A rolling swap puts it on
  the common path.
- **`Text.Regex.TDFA` is unvalidated as an engine.** It cannot be installed in the
  development sandbox, so the spike validates the primitive's shape and cache with a
  stand-in matcher.

### OQ-002: Servant + Dynamic Schema ✓ ANSWERED
**Answer**: Servant + Warp works. The pattern is `"schema" :> Capture "ns" String :> Capture "name" String :> Raw`. Servant handles the static URL structure; the `Raw` endpoint delegates to an IORef-backed WAI dispatch table for runtime-dynamic routing. No Yesod needed for the data plane. See `spikes/servant-warp/output.txt`.

### OQ-003: Binary Replication Format ✓ ANSWERED
**Answer**: Cap'n Proto for production; cereal during initial development. See `spikes/capnproto/output.txt`.
- **cereal** (used in storage spike): same length-prefix framing as Cap'n Proto, no external toolchain, identical structural design. Ceiling: schema evolution requires an explicit version byte and branching decoder — adding a field to `TxNode` breaks old decoders without code.
- **Cap'n Proto confirmed** (capnproto spike): wire format implemented and validated. Encode/decode round-trip passes all fields including parent locator lists. Encode and full decode both sub-µs (timer resolution of 10k-iteration benchmark insufficient to distinguish; confirmed < 1µs/tx).
- **mmap zero-copy confirmed**: 112-byte TxNode message written to disk, mmap'd back, fields read at fixed byte offsets (e.g. timestamp at message byte 16) with no decode pass. The OS page cache backs the ByteString — no heap allocation.
- **Schema evolution confirmed**: V1 message (dataWords=2) read by V2 decoder → new field defaults to 0. V2 message (dataWords=3) read by V1 decoder → extra data word silently ignored. No version byte, no branching decoder, no migration step. V1=112 bytes, V2=120 bytes (+8 bytes for one new field).
- **Protobuf is NOT a substitute**: Protobuf requires full parsing; Cap'n Proto mmaps the bytes directly.
- **Migration path**: use `cereal` in `Serialize` instances during development; swap to capnp-generated `Cerialize`/`Decerialize` instances before production. Wire framing is identical — only the payload encoding changes. Requires `capnp` C++ tool at compile time (`apt install capnproto`).

### OQ-004: Storage Engine ✓ ANSWERED
**Answer**: Hybrid architecture confirmed. See `spikes/storage/output.txt` and `spikes/capnproto/output.txt`.
- **Append-only log** (Cap'n Proto frames on disk): the transaction graph. Immutable, sequentially written, mmap-readable without deserialization. Random access by `LogEntry { offset :: Word64, length :: Word32 }` is O(1) seek+read.
- **LMDB `log_index`** (`PhysicalLocator → LogEntry`): finds any row version in the append log by locator. Keys are 14-byte big-endian locators; big-endian encoding means a range scan over all rows in a transaction is a single contiguous LMDB range.
- **LMDB `head_index`** (`DataId → current PhysicalLocator`): resolves the user-visible primary key to the current head version.
- **Full zero-copy read path**: `DataId → head_index → PhysicalLocator → log_index → (file_offset, len) → mmap[offset:len] → Cap'n Proto → pointer arithmetic`.
- **Naming note**: the spike code calls the physical address `RowId`. It is `PhysicalLocator` in the design docs — `RowId` read as "the id of a row", which is what `DataId` is, and the collision was the source of recurring confusion. See `transaction-graph.md`.
- **LMDB threading fix confirmed**: requires `-threaded` in ghc-options AND wrapping the LMDB session in `runInBoundThread` (session-level, not per-operation). The `lmdb` Haskell package calls `isCurrentThreadBound` before acquiring its write lock; without `-threaded`, this always returns False. See `spikes/capnproto/src/Spike/LmdbFixed.hs`.
- **LMDB latency**: read 11µs/op, write 1,107µs/op. Write latency is high because LMDB calls `fdatasync()` on every transaction commit by default (durability guarantee). **This is not a problem** — DataCode batches multiple mutations into a single transaction. At 10–100 mutations/tx, the per-mutation cost is 11–110µs, which is acceptable. Single-mutation micro-benchmarks are not representative of production write patterns.
- **Production LMDB pattern**: dedicate one OS-bound thread (via `forkOS`) for all LMDB writes, with a `TQueue` for serialization. Readers are concurrent (LMDB MVCC — readers never block writers).
- **Compaction is lossless.** It relocates bytes so they are stored more optimally as the schema evolves and never discards a row version. Superseded versions *are* the version chain, which is the graph's account of how a row reached its value; collapsing them to reclaim disk would be rewriting history for space. Pruning is the only operation that loses anything, it loses granularity deliberately, and it happens only as the consequence of a declared `retain` chain (OQ-032). Relocation, compaction, and pruning share the maintenance queue and only the last may lose data — see `storage.md`. The consequence leaned on elsewhere: anything derivable from a row's version chain stays derivable for as long as the row exists, **except over a range a declared `UserData` `retain` chain has pruned**, where it reads `NotRetained`. That exception was missing here while `schema/aggregates.md` described it, and it decides whether a per-field time cache over such a table is a materialized view or a rollup.
- **A re-key severs the chain, and the transaction node carries the link.** Delete-plus-insert mints a new `DataId`, so "complete back to its creation" reads "back to the re-key that created it"; the walk follows the re-key record on the transaction node. See the re-key bullet under OQ-005.
- **Per-field `created_at`/`updated_at` are derived, cached by configuration, and proposed by usage.** `Table.field.updated_at` is a backward walk of the version chain comparing one column. `Table.field.created_at` is the first version carrying a value for the column; for a field **added by evolution** that is the row's own `created_at`, because every older row reads the field's mandatory default (Rule A, under OQ-005) rather than an absence variant. The separate and usually more informative question — when the column appeared — is the adding schema node's timestamp, a schema-graph fact rather than a row version, and a `FieldTimeCache` row buys nothing for it. This replaces "the first non-`Null`-derived value", which assumed an added field reads absence on old rows. Never stored on the row — that would multiply row width by field count to hold what the log already contains. Which fields keep a cache is a `system.telemetry.FieldTimeCache` row (`Configuration`, because the set tracks load and a schema commit per tuning change is the wrong grain), and because compaction is lossless the cache qualifies as a materialized view rather than a rollup table. Uncached references are logged to `system.telemetry.FieldTimeRequest` (`LogData`, with a `retain` chain rolling to counts) and the maintenance queue raises a *proposal* — a query must never silently create the view, since that writes state nobody authored in a system built on named branches and no anonymous forks. Declaring up front stays the primary path: usage-driven discovery cannot cover a cold start, where the first query pays the full walk per row. See `transaction-graph.md`.

### OQ-026: API Version Token Format ✓ ANSWERED
**Answer**: Three interchangeable version token types, all valid as the `{version}` segment in `/v{version}/...` API paths:

- **Graph node id prefix** (canonical default): a prefix of the schema node's `DataId`. The underlying identity of every schema node, unambiguous across servers, shard splits, and merges. A prefix short enough to match two nodes fails with an ambiguity error; the resolver never picks one of two matches.
- **Tag**: a fixed-point alias for a specific graph node. Tags do not move after creation. Techs attach tags to commits as part of a transaction; tags are the expected primary UX for human-readable version pinning (e.g. `v2.1.0`, `stable-2026-q2`).
- **Branch name**: a moving alias that always resolves to the current HEAD of a named branch (e.g. `main`, `experiment-checkout`). Advances automatically as new commits land on that branch.

All three resolve to the same thing at dispatch time: token → schema graph node → routes registered at that node. The id prefix is the lowest-level escape hatch that works even when no tag or branch name has been declared.

**Amended: a node is *named* by its `DataId` and a schema node *additionally* carries a content digest; they are not competing identities.** This entry originally called the token "content-addressed", which contradicted `DataId` being a timestamp plus a server id plus a sequence — not a hash, not deterministic from content, and different on two servers computing the same node. The digest is a 32-byte SHA-256 over the declaration a schema node carries, and it is an **equality witness, never an address**: it answers "do these two nodes carry the same term", which is what replay (OQ-001) and predicate audit (OQ-027) actually need. Naming stays with `DataId`, so routing, parent pointers, and `DataId 'TxNode` all mean one thing. See `transaction-graph.md`.

**No-version behavior**: Requests without a version token are routed to the `main` branch HEAD by default. The server can also route unversioned requests across A/B test branches at a configurable rate; routing decisions persist via session affinity so the same client consistently receives the same branch across requests.

**Promoting a version going forward**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch is currently designated. The `/versions` discovery endpoint lists all live tokens and marks the promoted one. Together these allow operators to tell existing clients "use this tag from now on" without requiring client code changes.

**Policy**: All branches must be named — anonymous DAG forks are not permitted. The `main` branch cannot be deleted. See the Branch and Tag lifecycle documentation in `transaction-graph.md`.

**Load-bearing consequence**: "all branches must be named" is structural rather than policy, because a schema shard is rooted at a branch row and a root table's key *is* the shard directory (OQ-007). An unnamed branch would have no shard.

### OQ-027: API Functor Type and Transaction Semantics ✓ ANSWERED

- **Typing**: No separate API functor type. Field types are referenced directly from the schema everywhere they are used — the schema IS the type system. Auto-generated routes are fully typed by the table definition.
- **Transaction semantics**: Reads and writes share the same transaction graph snapshot. The primary server linearizes and executes transactions one at a time. **Cross-shard transactions take no lock.** The earlier answer here was a cross-server lock on a `transaction_id` held across the involved primaries until all operations completed; it is **withdrawn**. A cross-shard transaction is instead a *prepared node per participant plus one commit node* — the graph's own branch-and-merge shape at transaction scale. The first server to accept the mutation validates against a graph point it pins, appends a prepared node invisible to reads, and hands the *operation* (not a row set) to the next primary, which validates against its own pinned point and answers yes or no; the coordinator then appends a commit node or an abort node. What made the lock look necessary was the assumption that a participant must be prevented from moving; what actually holds is **validation reads merged nodes only**, which makes a prepared node invisible, makes concurrent `A→B` and `B→A` chains abort rather than wait, and is the same invariant that makes an unmerged schema branch and a local admin branch inert. Re-validation rarely fails, and that is derived rather than hoped: an assert is rooted at `self`, so its predicate depends only on the subject row's connected component, and a failure at the second participant means a concurrent write to those same rows — a conflict that had to fail anyway. The consequence about grouping related shards survives and is sharpened into constraint groups (below). See `distribution.md`.
- **A constraint whose revalidation set crosses shards cannot be `enforce always`.** Anchoring bounds work, not locality: an FK may point into another shard and a negative assertion's revalidation set is the FK chain traversed backwards, so a write in a third shard can invalidate an assert without either participant observing it. That guarantee is unachievable without the lock just removed, so such an attachment is restricted to `enforce forward`, `monitor`, or `repair into`, and the breach surfaces as a `system.integrity.Violation` instead of a rejected write. Schema commit names the crossing edge and reports the coercion, because an `enforce always` that silently became `forward` is the read-behaviour-changed-without-touching-a-field case this file already requires be surfaced.
- **Error signaling**: The transaction is atomic — it either fully commits or fully fails. On failure, only the HTTP request log is written (to a per-server system shard that always succeeds independently). The error is returned to the client. 500s should be avoided; all known failure modes return 4xx.
- **Event functors**: Index updates are part of the commit. View refresh and repartitioning are **queued on `system.events.MaintenanceQueue` and run outside it** — they are not "internal events resolving within the transaction", which is what this bullet used to say and what `storage.md` contradicts. External side effects (email, webhooks) are never executed inline either: they go to a queue table and run under the event scheduler. No external calls from within a transaction.
- **A mutation not anchored to one shard becomes a node on the schema shard that every primary applies locally.** The gate is **structural, not a role check**: what makes such a mutation dangerous is its scope, which is readable off the query, exactly as an assert's variety is read off its body rather than its name. An ordinary grant on the system table controls the path, so privilege is a consequence of the rule rather than the rule itself; "admins only" was rejected for the same reason naming conventions were rejected for access asserts. Application is **per shard, independent, and may be partial** — each primary validates every affected row against the full constraint set and records what it did in its own shard, and the initiator's report is a distributed query merged from every participating shard that **names which shards contributed**, the pattern `integrity.md` already established for the same reason (a single global table would be a cluster-wide write hotspot). Three properties follow: the initiator subscribes rather than blocking, since a "wait for all primaries" return value cannot express "shard 47 is down"; the operation is restartable by construction, because an unreachable shard applies the node when it returns; and records stay in their shard, since one row per (operation, shard) written to the schema shard would make every bulk mutation a fan-in burst on the least suitable node. All-or-nothing across every shard was rejected — it needs cluster-wide two-phase commit, which is the thing being removed. The one case resisting independent per-shard validation is a bulk mutation touching a table-wide `unique`, whose authority is a constraint shard (OQ-007).
- **A read at a historical moment is checked against HEAD's access rules, not the moment's.**
  A query with an `at` clause samples the past for *data*; the question of who may see it is
  answered now. The reason is one-directional: an access rule that was removed must not still
  be granting access, and a rule that was added must not be evadable by sampling a moment
  before it existed. So `at` needs the historical row **shape** — which fields existed, how to
  decode them — and that is graph data rather than code, while the asserts it runs are the
  current ones. Data constraints, foreign keys, and event functors do not enter into it, since
  none of them evaluate on a read. **Tightening an access rule is therefore retroactive**, which
  is a change in read behaviour without touching a field, so it falls under the existing rule
  that the commit diff must report it: schema commit **warns** and names every assert whose
  variety or predicate changed, and because both the old and new predicates are content-addressed
  nodes, "which reads would this have redacted" is an ordinary query over the transaction graph
  rather than a report someone has to build. This is what makes functor **transparency**
  load-bearing for auditing and not only for optimization (OQ-001).
- **A schema commit requiring a build advances its ref only when the build lands.** Adding a
  handler *is* a schema commit — `system.events.Handler` is a `Reference` table, so
  `handler foo.bar` compile-checks against the compiled-in registry — and that commit cannot
  complete before the artifact exists. The graph already had the shape: the commit appends the
  node, the build is a queued `Effect`, and on success a merge node lands and the ref advances.
  On failure the node stays **unmerged and inert**, which is the same invisibility that makes an
  unmerged schema branch and a prepared node inert, so a failed build needs no rollback in a
  system where nothing is destroyed. The property this buys: **"live" is ref position and refs
  are data**, so there is never a window in which the graph and the enforced schema disagree —
  which matters most for an access tightening, where such a window is a security lag rather than
  a delay. Ordinary schema changes never reach this path at all, because functors are interpreted.
- **Deferred work waits on a queue position, never on another operation.** Global mutations are queue rows under the event scheduler's existing `Configuration` policy (`backoff_base`, `aging_rate`), so cross-shard prepares and cluster-wide mutations are one mechanism with two callers rather than two deferral systems. Admission is on a condition readable off data rather than off a clock: the shard's write queue reaches zero, **or** the item's age exceeds the aging threshold. The first gives local work precedence and lets global work resolve while a shard is quiet; the second is what guarantees progress, since "wait for server inactivity" alone never arrives on a busy server and inactivity is a clock property besides. The result is the property the arrangement exists for — **no operation waits on another operation, so there is no wait-for edge and deadlock is unrepresentable rather than avoided** — and it holds only alongside "validation reads merged nodes only", since a validation permitted to observe a prepared node would reintroduce the edge. Global *reads* are excluded from all of this and need no deferral at all; see OQ-012.

### OQ-028: Route Conflict Resolution ✓ ANSWERED

- **Custom routes shadow auto-generated at the same path.** The most useful behavior — registering a custom route at `/records/app.commerce.Order/{id}` clearly intends to override the generated handler.
- **Route templates are normalized before any check.** A `route_template` is an absolute path below the version segment: leading slash required, version segment excluded, no trailing slash. It mounts at `/v{token}<template>`. Every rule below is stated against the normalized form.
- **Reserved `raw/` prefix**: `/v{N}/raw/<table-path>` is always auto-generated; a custom route whose first normalized segment is `raw` is rejected at insert time. This guarantees the auto-generated handler is always reachable.
- **Path validation**: custom routes under `/records/` must reference an existing table or derived table; phantom overrides are rejected at insert time.
- **Version semantics**: custom routes are schema objects in the transaction graph — no routing-mode flag on branches or tags needed. A version token resolves to a schema node, and the routes at that node (generated + any custom overrides) follow naturally.
- **Branches and tags are two tables, not one ADT.** This entry originally put both in `system.VersionRef` carrying `VersionRef = Branch DataId | Tag DataId`, so the mutability difference lived in the type and no discriminator column was needed. **Withdrawn** on three counts: `ref : VersionRef` does not compile, because within `system` the short name resolved to the table and `:` may not name a table; `release` was undecidable for `name`, which was a permanently reserved placement key or a releasable value depending on a sibling column's variant; and half the rows rooted a shard while half did not, with the difference carried outside the key, which "the key declaration is the sharding declaration" forbids. `system.schema.Branch` and `system.schema.Tag` are separate tables and the table is the discriminator. See `transaction-graph.md`.
- **Tag immutability and `main`'s undeletability are table properties, not validation functors.** No functor kind can express either: kind 1 receives the new field value and kind 3 the row being written, so neither sees the *previous* version, and no kind is reached on a delete. Both are engine-enforced, the same category as `LogData` append-only. The earlier text named a functor, which would have been implemented as written.

### OQ-029: Route Trie vs. Dispatch Table Implementation ✓ ANSWERED
**Answer**: Hand-rolled route trie. See `spikes/route-trie/output.txt`.
- **Route trie confirmed**: 0.2µs/request at 10k registered routes — well under the 1µs target. O(depth × log fanout), independent of total route count.
- **Linear scan ruled out**: 1µs at 100 routes, 13µs at 1k routes, 132µs at 10k routes. Scales O(n) — fails the target beyond a handful of custom routes.
- **wai-routes ruled out**: uses Template Haskell compile-time route tables — incompatible with DataCode's runtime-registered custom routes.
- **path-piece ruled out**: a type class for parsing individual path segments, not a router.
- **Precedence**: static segments always beat captures at the same depth — correct, deterministic, matches every mainstream router.
- **Integration**: replace `IORef (Map String Application)` in the Servant `Raw` handler with `IORef (RouteTrie Application)`. Schema changes rebuild the trie and atomically swap the IORef — zero request interruption.
- **Conflict resolution** (answers OQ-028 partially): exact-path conflicts are a schema validation error at insert time. The trie's `nodeHandler` slot can only hold one handler; inserting a duplicate pattern is rejected.

### OQ-036: Erasure, PII Scrubbing, and Shard Quarantine ✓ ANSWERED
**Answer**: Two operations, not one. **`erase` closes a row's history and destroys nothing;
`scrub` destroys bytes and is the single exception to "nothing is destroyed".** Quarantine needs
no mechanism. Crypto-shredding is rejected as the general answer and kept where it is free. See
`integrity.md` (policy), `storage.md` (physical), `distribution.md` (constraint index, cold
shards), `schema/traits.md` (`Personal`), `cli.md` and `schema/railroad.md` (`ErasureCmd`).

**Erasure is restriction of processing, and is documented as such.** GDPR Art. 17(3) exempts
retention for legal obligation and legal claims, but "kept forever behind an access check" is not
itself an Art. 17 exemption — it is **Art. 18(2) restriction of processing**, which is a
recognised shape and the one this design implements. Naming it correctly matters: describing it
as erasure invites the assumption that bytes are gone. The retained copy is defensible only
while it stays inert — unreachable by ordinary query, absent from derived state, unused beyond
the audit obligation. Where an authority orders destruction, or a regime offers no audit
carve-out, the operation is `scrub`.

**`erase` reuses settled rules rather than adding an evaluation path.** It appends an `Erased`
tombstone; reads at earlier moments return `Erased` for any token without `bypass erasure`. It is
retroactive by construction, because a historical read is already checked against HEAD's access
rules rather than the moment's (OQ-027). It cascades from a shard root for free, because every
dependent row reaches the root through its FK chain. Eligibility is the `Personal` marker trait
on the table; the act is the tombstone on the row. A *third* shard-level flag was considered and
rejected — erasing the root already scopes the act to the shard.

**A regular tombstone is never an erasure.** `delete` keeps its meaning and its readable history.
`erase` is a separate, manual, recorded act, reachable only from `ErasureCmd`.

**Scrub is overwrite-in-place: one primitive, two callers.** Blanking a leaked secret in the
transaction graph *is* byte destruction, so "erasure needs no destruction primitive" was never
available — the choice was whether to build one primitive or two. Callers are the routine one (a
scrub rule matched) and the rare one (an ordered destruction). Three details it forces: the scrub
node records checksum-before and checksum-after so tamper evidence survives the overwrite;
payload length is preserved so no locator moves, which makes the gap a length disclosure that
compaction removes; and a restore replays every scrub node at or before the restore point, which
is what keeps a re-imported dump from being the way scrubbed data returns.

**Scrub rules are `Configuration`, and they are rules, not rows per field.** A default pattern set
ships (`password`, `passphrase`, `secret`, `token`, `api_key`, `ssn`, `cvv`) matching on field
path and document key. Auto-inserting a config row per matching field was rejected: a schema
commit writing configuration makes the table half-authored and half-derived, so a diff can no
longer say who decided what — and one default pattern already covers every field named
`password` that will ever exist.

**Detection is three layers, preferred in order**: the type at declaration; a static check at
schema commit, which is free because functors are transparent (OQ-001) and the walk that does
static access analysis also answers "does this route reach a `Secret` source?"; and a runtime
matcher over document keys that runs *before the frame is written* on the two dynamic paths that
actually leak, HTTP request logs and connector payloads. Scrub-then-violation is what remains for
a rule taught too late, and subsequent writes of that field store a keyed deterministic digest so
a brute-force attempt stays distinguishable from a user retyping (`auth.md`).

**The unique-constraint leak decided the constraint index format.** Tombstoning a row leaves the
question of whether its `unique` value is freed, and both obvious answers are wrong: freeing a
root table's key breaks routing, because that key *is* the cluster shard directory and the
directory would stop being a function over history; reserving it leaves the erased value in a
replicated index in another shard. The resolution is that **the table-wide `unique` index stores
a keyed digest and partitions on it, always** — not only after an erasure. Uniqueness is
equality-only, so the plaintext was never needed; constraint shards then hold no personal data,
and erasure has nothing to propagate to them. The key is per constraint, generation-tagged,
scoped to its comparison scope — a per-server key would produce two digests for one value and the
constraint would silently never fire. Cost accepted: no cluster-wide ordered index on the column,
which was never usable anyway.

**A reserved value is released only deliberately.** Placement keys are never released; any other
`unique` may be, by an explicit `release` recorded with authority and reason, and only where the
owning row is deleted or erased. Consequence made normative: a lookup by unique value resolves at
the query's sample moment, not at HEAD.

**Derived state is handled by what it is.** Materialized views and shredded document trees are
recomputable, so a refresh drops the row. Two are not: a rollup whose group key is a `Personal`
field is the only surviving record and warns at schema commit; and an interned document key is
schema replicated to every server, which is why scrub rules match document keys and why
`Doc indexed` gained a key-shape rule (see OQ-033).

**Quarantine is expressible, not built.** "Unreadable and unreplicated pending review" is a
revoked namespace grant plus a range-tree entry with no serving roles. Both exist, both are
reversible. A `quarantine` verb was rejected because it would restate what grants and role
assignment already say, and the two would drift.

**Cold shards relax placement, not role count.** Three role holders always. A flat-file dump is
not a replica — not verified, not sequence-tracked, not in the swarm — and over a seven-year
audit window the failures that arrive are regional loss and bit rot, which two geodiverse copies
defend against and one unverified file does not. What may be relaxed is hardware class and write
load: a sealed cold shard on three cheap hosts costs nearly nothing, and moving it there is a
range-tree edit. Where an operator insists on one copy plus a dump, the honest form is a
content-addressed dump whose checksum is a graph node and which a scheduled event re-reads.

**Sunset is proposed, never automatic**, on the rule that already governs materialized views —
an operation that moves authority is not automatic, and inactivity is a clock reading besides.
**Rolling up `UserData` history is a `retain` chain with a predicate, not a command**, which
keeps "pruning is only ever a consequence" intact while giving the row-targeting that was wanted;
per-field timestamps over a pruned range read `NotRetained` rather than a wrong answer.

**Exports stay an operator obligation**, now with one in-system guarantee attached: the restore
replay rule above.

**Rejected: crypto-shredding as the general mechanism.** It aligns well with row-rooted shards,
but it puts a cipher between mmap and the Cap'n Proto message and would have forced the zero-copy
read path to be re-argued. OQ-037 makes it available for free in the one place it costs nothing —
destroying a data key destroys every `Encrypted` value under it — because decryption there is
never on the read path.

**Still open**: nothing blocking. The empirical thresholds are OQ-033 (key cardinality) and
OQ-035 (extent and segment sizing).

### OQ-037: Reversible Secret Storage ✓ ANSWERED
**Answer**: `Encrypted a using system.crypto.CipherPolicy.…`, stored under **envelope
encryption**, with **decryption as an `Effect` and never a read**. See
`schema/types.md#encrypted-types` and `auth.md#envelope-encryption-and-key-custody`.

**The effect ladder decides the shape before any algorithm question does.** `unwrap` is an
external call, and there is no lift from `Effect` to `Tx`, so a commit cannot wait on a key
service. Envelope encryption is the arrangement that satisfies it: an authority wraps a data key,
each server unwraps it once at startup or rotation in `Effect` in the generation pool, and
commits encrypt with the cached key making no external call at all. `WrappingAuthority` is a
`Reference` row naming compiled-in Haskell — the `system.events.Handler` pattern reused — so a
key file, a PKCS#11 token, and a cloud KMS are interchangeable with no new mechanism.

**Servers do not share a private key, and do not have to.** Wrapping the data key to each
server's public key (X25519; `age` is the packaged form and accepts existing SSH keys as
recipients) means each server holds only its own private key, on disk, outside the graph, and
adding a server re-wraps a small blob. This dissolves the concern that made "keep the key and the
secret on the same schema shard" look acceptable as a v1 — **that compromise was offered and is
not needed**, so it is rejected rather than deferred. Two specifics recorded so they are not
re-derived: `ssh-ed25519` is a signing key and reaches encryption only through its X25519
birational map, and the wrapping key never encrypts row data.

**Decryption is an `Effect`, never a read**, which answers three of the four open sub-questions at
once. Both consumers of a reversible secret are handler-side — TOTP verification and connector
authentication — so no cipher sits on the read path, `storage.md`'s zero-copy claim is untouched,
and the collision this question shared with OQ-036 does not exist. What a read returns to a token
that may not decrypt needs no invention: every token gets `Sealed`, and who may call `reveal` is
an ordinary grant.

**Rotation has two tiers.** Rotating the wrapping key re-wraps one blob per data key and touches
no row. Rotating the data key re-encrypts affected rows lazily on write under `enforce forward` —
the same machinery as password policy rotation, since each value records its policy.

**Crypto-shredding falls out free** for `Encrypted` fields: destroy the data key and every value
under it is unrecoverable. It reaches only encrypted fields; plaintext that reached the log is
scrubbed (OQ-036).

**Scope narrowed and unchanged**: a delivered one-time code is a `Challenge` row and needs none of
this. Unblocks authenticator apps (OQ-011) and outbound connector credentials.

## Must Resolve During Core Development

### OQ-005: Schema DSL Syntax ✓ ANSWERED
**Answer**: Designed. See `docs/schema/` (normative syntax reference, one file per topic),
`docs/schema/railroad.md` (full EBNF + railroad diagrams), `docs/cli.md` (REPL and admin
commands), `docs/auth.md` (ACL model), and `docs/category-model.md` (the categorical
rationale). The decision record is the bullet list below plus OQ-030 and OQ-031.

Key decisions:
- **Tables**: `table Name : Trait1, Trait2 { field : Type = default, order by field }` — DataId PK implicit
- **Types**: `type Email : Text where isValidEmail` — colon = "is a kind of"; sum types `A | B`; absence types `type X : Null`
- **Validation**: `where <predicate>` as a trailing clause on a type or field declaration. Replaces the earlier tentative `{ validate: ... }` block. **One `where` per declaration**, Haskell-style: the body is a single predicate inline, or an indented block of predicates that are implicitly conjoined. No repeated `where`, no `and` between block entries.
- **Validation addressing**: a field's `where` is addressed by the field's path (`app.commerce.Customer.email`), which is also the name of its computed field type — no separate naming syntax. `assert` must be named because it spans two paths and has no single field path to inherit. Origin addresses survive trait inheritance, so a merged field enforces `A.name`, `B.name`, and its own predicates, each individually addressable.
- **Termination**: inside a body, declarations are `,`-separated and closed by `}`; the separator may be leading or trailing (leading-comma style keeps block `where` readable), and a comma before `}` is allowed. At top level there is no separator — a declaration ends at the next token in column 0. Continuation in both cases is by indentation (offside rule), which is what delimits a block `where`.
- **References**: `:>` declares a foreign key (`customer :> Customer`). `:` requires a type on the right, `:>` requires a table or derived table; using the wrong one is a compile-time error. Replaces the earlier two-token `: -> Customer`.
- **Head rule**: in an alternation only the first variant decides the token, so `customer :> Customer | MissingCustomer` and `phone : Phone | NotGiven` both typecheck against a single `Null` root — no separate reference-absence hierarchy.
- **Clause order**: `field ( ":" | ":>" ) Type [unique] [indexed] [= default] [where pred]`. The default precedes `where` so an `=` inside a predicate is never ambiguous. `rename from` was withdrawn with the rest of `SourceClause` once a projection could express a rename.
- **Inline sub-tables**: `address :> Address { ... }` — sugar for a sibling table plus an FK; there is no embedded product-in-row.
- **Traits**: abstract base types (`trait` keyword); tables extend via `:` syntax; replication traits (`Reference`, `UserData`, `LogData`, `Configuration`) are regular traits
- **Joins**: `><` bowtie operator; outer join = `Order >< Customer | MissingCustomer` (guard semantics — the same rule as a nullable `:>` field)
- **Constraints/ACL**: unified `assert name { body }` keyword. `where` is unnamed and field-scoped; `assert` is named and row-scoped.
- **Functor kinds reduced to four**: data constraints and access control are the *same* functor (path constraint), differing only in whether the requesting token is one of the terms. That difference determines when it runs (commit vs. read+write) and what a read failure does (`Redacted` rather than abort).
- **The access variety is recognized structurally, not by name.** An assert whose body mentions `authed_user` is an access constraint; anything else is a data constraint. The earlier rule made the *name* `access` select the variety, which was a magic `Ident` with no lexical status — unusable as an ordinary constraint name, yet not reserved. The decisive defect was elsewhere: it made administrator bypass depend on a naming convention, so a perfectly good access rule named `ownerCheck` would not have been bypassed and nothing in the syntax would have said so. Scanning the body is exact. Consequences: `access` is an ordinary name again; every assert has a real name, which every diagnostic benefits from; **all asserts conjoin regardless of variety**, so alternatives are `||` inside one assert rather than several asserts (an access assert that *widened* would invert "recursion sets the ceiling, functors lower it", OQ-024); a conjunct not mentioning the token inside an access assert is silently bypassed too, so schema commit **warns** and names it; and an edit that adds a token mention **reclassifies** the assert, changing read behaviour without touching a field, so the commit diff reports it.
- **Path constraints gained presence and absence.** The kind's signature widened from `(a, a) → Either Error ()` to `Row → Either Error ()`. A `Query` in assert position asserts its result is **non-empty**; `not` of one asserts it is empty. Equality is now the case where the body is an expression rather than a query. This was not expressible before and could not be faked: every path in the schema graph is single-valued by construction, so an equality-only assert had nothing to quantify over — which is exactly why the pre-existing ACL examples read as contrived. The requesting token enters as a **join term** (`self >< Project >< Member >< authed_user`), so the equality *is* the join and no comparison is written. An outer join with a `Null`-derived catch-all expresses absence too, but `not` is preferred in an assert: nothing consumes the variant there, and the guard form invites the filter-placement error below. No quantifier keyword was added — `any`, `none`, `exists`, and `elem` were all considered and are all unnecessary once a query can stand in boolean position.
- **Asserts are anchored.** An assert's query must be rooted at `self`, and every subsequent source must be reached by a join along a declared `:>` edge in either direction; an unanchored source is a compile-time error. Access asserts run on every read, so an assert free to scan would scan on every read; anchoring bounds the work to the row's connected component, and any number of hops within it is fine. It also makes the *reverse* direction findable, which is what an absence assertion needs — a write to `Suspension` must revalidate the `Invoice` rows reaching it, and the FK chain traversed backwards is that set. What anchoring does not buy is locality: an FK may cross a shard, which is a warning naming the edge, with system-shard role tables as the pattern that avoids it.
- **`authed_user` replaces `user`** as the requesting-token binding, and is a full `User` row rather than an id — which answers what the token exposes by making it ordinary path traversal. `user` read like a table name and would have collided with the likeliest field name in any permissions schema. `self` and `authed_user` are **contextual bindings, not reserved words**; `self` had been used in trait function bodies since `traits.md` was written without being listed anywhere. There is deliberately **no `authed_client`** binding: client scope is schema-level configuration, and admitting the client into an assert would put one decision in two places.
- **Administrator escalation is a grant attribute, not an expression.** `grant <role> on <namespace> bypass access` skips every assert mentioning `authed_user` and nothing else — an administrator is exempt from access control, never from data integrity. Rejected: `|| authed_user.role is Admin` in every rule (spreads one decision across every table, unauditable), and rebinding `authed_user` to all users for administrators (silently changes a term's arity, so `>< authed_user` degrades from "I am a member" to "any member exists", and means nothing for an assert that compares rather than joins). `grant`, `grants`, and `bypass` are the three words this reserved, joining the `TokenCmd` family that already had `revoke`, `on`, and `scoped`.
- **`=~` is a real operator.** It had been lexed and used since the first draft of `functions.md` while appearing in no production; it is now a `CmpOp`. Its right operand is restricted **by trait** — a string literal, a `Reference` path, or a `Configuration` path — so a pattern can never be user-supplied. The first two resolve at compile time (a `Reference` insert *is* a schema commit) and reject a malformed pattern there; a `Configuration` pattern resolves at runtime, keys the compiled-pattern cache on the config row version, and fails at runtime. TDFA is a DFA engine, so the restriction is about provenance, not backtracking.
- **Filter before guard.** A filter on an outer-joined source must be written inside the join term; an outer-level `where` naming an outer-joined source's field is a compile-time error. Filtering after the guard deletes the very rows the guard produced, so an account whose every suspension is lifted yields zero rows rather than a `NoSuspension` row. This is SQL's `ON`-versus-`WHERE` trap, closed structurally rather than documented, because the same expression appears inside `assert` where the symptom is not missing rows but a constraint asserting the opposite of what it reads as. Relatedly, `as` is **mandatory** on a join running against the reference direction whenever the query names that source, since there is no `:>` field to name the column and the bare table name would read as though the table were the value.
- **`not $ …` parses.** `NotExpr` gained an explicit `'not' '$' Expr` alternative. `not` is a prefix operator here rather than a function, so `$` could not fall out of the operator table as it does in Haskell — without it, `not $ …` was written throughout `functions.md` and `auth.md` and parsed nowhere.
- **Schema evolution is two statements.** Redeclare a `table` to change stored structure; bind a query to reshape one. **`*` in a table body carries forward every field the body does not mention**, which makes additive evolution one line instead of a full restatement — and makes omission unambiguous: with `*` present an omitted field is carried forward and you drop it with `deprecate`, without `*` omission still deprecates. A rename is `Customer = Customer { *, status as account_status }`, a retype is `{ *, toTier (loyalty_tier) as loyalty_tier }`, and the projected expression **is** the migration functor, which closes the "syntax TBD" the type-change row carried. `rename from` and the whole of `SourceClause` are withdrawn as a second spelling for the first of those. **Names on the right-hand side resolve to the version current at the start of the commit**, names introduced by the commit resolve within it, and the result must be acyclic — which is what lets a binding redefine the thing it reads. A binding whose source is superseded in the same commit is **frozen into storage**, since it can no longer be recomputed; that is the rollup argument reaching one case further.
- **Scope**: top-level = global (stored in schema); `let` = local inside function bodies; REPL = transaction model (`:commit`/`:rollback`)
- **Equality**: `=` is binding only (field default, function definition, sum-type declaration, `let`, row construction and update), `==` is comparison, `is` is constructor match ignoring payload. Follows Haskell. Resolves the earlier doubling where `=` also meant exact value equality.
- **Operator spelling** follows Haskell: `==`, `/=`, `&&`, `||`, `not`, `True`, `False`. No `!=`, `and`, or `or` (OQ-031).
- **Candidate keys are mandatory** on every table not carrying `LogData`, `Component`, or `Keyless`; `DataId` does not satisfy the rule, since counting the surrogate would make it vacuous. Default-on with a `Keyless` waiver rather than opt-in, matching enforcement modes where the strict setting is the default and weakening it is an explicit recorded act — and the opposite polarity from `Extensible`, because extensibility is a capability you choose while keylessness is a defect you admit. The exemption is not "logs are special": *occurrences have no identity beyond their occurrence, entities do*, which is why queue tables carry `LogData` too. Replaces the previous state where `unique` existed but nothing required it, leaving "default ordering: unique key ascending" undefined on keyless tables.
- **A key on a shard-local table must be rooted** — its FK chain must reach the shard root, transitively is fine, and FKs to `Reference`/`Configuration` do not participate. Consequence: **the key declaration is also the sharding declaration.** A `UserData` table whose key contains no same-family FK *is* a shard root; one whose key does is a dependent. No separate keyword, and it cannot drift, because adding an FK changes nothing unless it is put in the key. Where a key reaches two roots, the first FK decides — the same head rule that governs `:>`. The root table's own key is cluster-wide, but that index is the shard directory the router already needs, so it costs nothing; every other key is checked within one shard. Requires shards to be **row-rooted** (each `Customer` row roots a shard), which `shardOf :: DataId 'Row -> Maybe (DataId 'Shard)` and `split shard … at key` already implied but no document stated. See `transaction-graph.md`.
- **Continuous time**: `Behavior a ≅ Moment -> a` as a field type, for values that change with no write — accruing interest, countdowns, decaying limits. Nothing is stored; the value is computed from the row at the moment of observation. Exactly one parameter, always `Moment`, because two behaviors compose pointwise only over a shared domain and the scheduler can solve a crossing only over a domain it knows. `Moment` is distinct from `Timestamp` (stored, in a row) and is deliberately not called `CurrentTime`, since historical queries sample the past and the scheduler samples the future. `unique`, `indexed`, `order by`, and `where` are all rejected on a behavior, and behaviors are read-only. Reuse is via traits, not via a behavior-carrying type, because a behavior closes over sibling fields and only a trait can require them. A behavior is **not** a fifth functor kind — the four kinds each enforce something and a behavior is a projection.
- **Units are validation, not algebra**, and **units are values**. `Duration`'s canonical unit is the millisecond, unit names are *constants* rather than conversion functions, and converting is division: `rate * (t - opened_at) / day`. Domain types narrow value sets; arithmetic operates on the underlying primitive. Dimensional typing was rejected as too large an addition for the benefit, and because it collides with functor transparency and the GADT DSL's ceiling (OQ-001). The earlier answer had conversions as stdlib functions (`days`, `hours`, … `:: Duration -> Decimal`); **that is withdrawn** because it put a factor in two independent places (the constant `day` and the function `days`) and bound one identifier to two meanings — `7 days` was a literal while `days x` was an application. `Duration / Duration :: Decimal` is the one division yielding a dimensionless number, which is what makes this work without dimensional types; `NumLit Ident` desugars to multiplication, so `7 day` *is* `7 * day` and units compose (`2 * week`, a user-defined `fortnight` in a `Reference` table). Consequently **no unit name is ever bound in the plural**, so the collision cannot recur. A converting `type Day : Duration` was considered and rejected. The decisive count is the field-scoped-subtype rule, which would make `period == day` and `period == 1` both read as true in one expression; a value carrying a scale factor *is* dimensional typing is the second. The third count as first written — "`type X : Y` is a transparent refinement, so there is no constructor to apply" — is **narrowed**: transparent refinement is `:`'s default reading, not its only one. `:` introduces a constructor in exactly two positions, a `Null`-derived absence type (a fresh nullary constructor, which is what makes `phone is NotGiven` distinguish `NotGiven` from `MissingCustomer`) and `Hashed`/`Encrypted` (a representation-changing transform, which is why those two are the only ones taking `using`). See `schema/types.md`.
- **Elapsed time, calendar offsets, and bucket sizes are three types.** `Duration` (divisible, ms-canonical: `milli`, `second`, `minute`, `hour`, `day`, `week`), `Period` (a calendar offset added to a `Timestamp`, `Int`-scaled, no millisecond count: `month`, `quarter`, `year`), and `Grain` (a truncation into labelled buckets: `Minute`, `Hour`, `Day`, `IsoWeek`, `Month`, `Quarter`, `Year`, `IsoYear`). They were one type while `Duration` was the only one, which hid a `month` with a fixed millisecond count and a bucket size with no count at all. `Period` has no conversion to `Duration` in either direction, so `now + 3 * month` gets calendar semantics rather than a 30-day approximation — the type system decides it instead of a rule to remember. **Calendar addition is not associative**, so one operator cannot cover both readings: `+` is from-origin (Dec 31 + 3 * month = Mar 31) and `stepMonth` accumulates one month at a time with a clamp at each step (Dec 31 → Mar 28/29, the day-of-month never recovering), which is the semantics a schedule anchored to a late day-of-month needs. Rollover (`addGregorianMonthsRollOver`) is deliberately absent. Non-integral `Period` literals are rejected rather than rounded. `Period` spellings of `day` and `week` are **reserved, not bound** — they would collide with the `Duration` constants while being behaviourally identical until `Timestamp` carries a zone, since the calendar reading of "a day" only diverges across a DST boundary. Capitalization carries the `Duration`/`Grain` overlap (`hour` the duration, `Hour` the grain), which is the ordinary type/variant case rather than a new rule.
- **Grains align; they do not merely coarsen.** Every `Grain` declares the grain whose buckets its own tile *exactly*, giving a forest rather than a total order: `Minute → Hour → Day → Month → Quarter → Year`, and `Day → IsoWeek → IsoYear`. Two roots, because ISO weeks tile ISO years by construction and tile nothing on the calendar side, so `by IsoWeek , by Month` is rejected — the week of January 29 straddles two months and merging across it would put a bucket in a month it is only partly inside. Alignment also decides what a width comparison could not: `IsoWeek` is coarser than `Day` and finer than `Month` while dividing neither, so its position is declared rather than computed, which is what closes the decidability hole in "grain must strictly coarsen". A step's retention is compared against the successor grain's **maximum** span (`Month` is 28–31 days, so `for 30 day , by Month` is rejected), keeping the check conservative and decidable. `for` takes a length and never a grain — a `Grain` has no count — and admits both `Duration` and `Period`, so `for 6 hour` stays legal and no minimum retention window is imposed. An `IsoWeek` level is labelled by **ISO** year, since December 29–31 can fall in week 1 of the following ISO year; `bucket_start` is the Monday and `isoWeekOf :: Timestamp -> (Int, Int)` returns the pair. Retain-chain grains are consequently `UpperIdent` (`by Hour`, `by IsoWeek`), which also distinguishes the bucket size from the retention length beside it in the same step.
- **Retention and rollups**: `retain <Table> as <Binding>` declares a chain of resolutions and how long each is kept. A chain never reshapes, which is why the binding is named once on the header — a differing step is unrepresentable rather than rejected. Terminals are `forever` (keep) and `drop` (discard); `never` was rejected because in a construct full of durations it reads as "never delete". Ordered `where`/`otherwise` branches partition a table, first match wins, as in a Haskell guard — one block rather than N statements, because order is load-bearing and separate statements have no reliable order. Chain aggregates must declare an associative merge with an identity (`count`/`sum`/`min`/`max` do; `avg` is silently rewritten to `(sum, count)`; `percentile` cannot and is rejected past one step) — phrased as a rule about merges rather than a whitelist so sketch types drop in later. `grain` is a virtual column on a level and a real one on the union, so `RequestRollup where grain == Month` selects a level with no new query syntax; the name denotes the union over all levels, making transparent querying the default and reaching into one level the marked case. **Pruning `LogData` is only ever a consequence of a chain** — there is no manual prune, and a table with no chain is never pruned, which is what closes OQ-032 structurally. A rollup is two appends (aggregate rows, then a prune node), never a rewrite of the transaction being summarized. Rollup levels are consequently real tables, not materialized views: a materialized view is recomputable from its source by definition, and here the source is gone.
- **Derived keys are computed, never declared.** A binding has no body in which to write one, which is the grammar enforcing the rule rather than a check. Every derived table has a key — a table is a set of tuples, so at worst the whole tuple is one — which makes *existence* the wrong question and **meaningful** (a proper subset identifying an entity) versus **degenerate** (all attributes) the right one. Propagation: `where` preserves; projection preserves iff every key column survives, else degenerates; `group` yields the group keys exactly, and exactly rather than approximately because DataCode's `group` nests instead of aggregating away; a `:>` join yields the referencing side's key alone and is lossless, with FK fields substituting to the referent's key so the key survives the FK column being projected away; a non-key join and a cross product both yield the union of the two keys; the one relational union in the language is the one a `retain` chain generates over its levels, whose discriminator is `grain` — there is no general `union` operator, so no case needs a discriminator that may not exist; an outer join degenerates when a key column comes from the outer side, for the same reason a declared key may not contain a `Null`-derived variant. **A superkey of a declared candidate key reduces to it**, which is what keeps `group { c.* }` meaningful rather than degenerate and what licenses the optimizer to rewrite it as a group on the key — unavailable, and unsound, on a source with no declared key. Degeneracy is a **warning, not an error** — reporting tables legitimately have no entity identity — but never silent, because one claiming an identity it lacks would be trusted by merge reconciliation. Three things depend on the answer: incremental refresh (upsert by key) versus full recomputation; whether the table is a **candidate to replace its sources**, with `deprecate` on a source rejected while a degenerate dependent exists; and whether it is writable.
- **There is no view.** A table declaration, a query, and a derived table are one kind of thing, so `ViewDecl` and `AggregateDecl` collapse into `Binding ::= QName (':' TraitList)? Param* '=' Query` — no keyword, matching DataCode's own top-level function definitions and Haskell's top-level bindings. `QName` rather than `Ident`, matching `TableDecl`: a binding is a table and every table belongs to a namespace, so `system.auth.ServiceAccount = …` has to parse. The bare-`Ident` case is `LetBinding`, which is local. `table` keeps its keyword because it declares storage and constraints, which a binding declares neither of. A right-hand side is a `Query` if it contains a `QueryClause` and an `Expr` otherwise, which is the rule that already disambiguated parenthesized atoms, now also applied to `$`'s right operand so `count $ Orders group { customer }` parses. A binding's `TraitList` **overrides the replication trait it would otherwise inherit from its sources**; absent one it inherits the most restrictive trait among them. `Reference` and `Configuration` sources are ignored in that computation, because they are present everywhere and so restrict nothing — the same carve-out key rooting already makes. Only a disagreement among `UserData`, `LogData`, and `Component` sources is an error: a derived table over `LogData` was never free to be `UserData`. Its asserts and uniqueness constraints are standalone-only, since there is no body. The table-style view body had already been withdrawn for being unable to express a join; `WildcardField` and `FieldDecl`'s bare `from` went with it.
- **Aggregate functions are ordinary functions.** The closed `Aggregate ::= 'sum' | 'count' | 'min' | 'max' | 'avg'` production and the postfix position it occupied are **withdrawn**; `count rows`, `sum rows.bytes_sent`, and `count $ Orders group { customer }` are ordinary application, needing no grammar addition since `as` is not an `Atom`. The postfix form also fed them the wrong input — `id count` passed a column to a function that takes a table, and `bytes_sent sum` named a column that is not in scope after a group. Six words were unreserved (`aggregate`, `sum`, `count`, `min`, `max`, `avg`) and `aggregate` now names a *concept*, any function from a table to a scalar. The decisive argument is that the retention rule was already phrased as "must declare a merge, not a fixed list", which the closed production contradicted in the one place a reader would check; a user-defined or sketch-typed aggregate is now admissible wherever the built-ins are. One semantic rule makes it work: **a path through a table-valued column distributes**, so `rows.bytes_sent :: Table Amount`.
- **`group` takes a projection and returns a table.** `GroupClause ::= 'group' Projection`, whose items are the group keys; every column they do not mention collapses into a generated table-valued column named `rows`, which the following projection shapes. Group keys can therefore be renamed and computed (`group { monthOf placed_at as month }`), which a bare `FieldPath` could not express. `group {A} {B}` needs no new production — it is `QueryClause*`. A group key named `rows` is rejected; residual columns named `rows` cannot collide, being inside it. `group` is not required to aggregate: `count Orders` reads the whole table and yields a scalar rather than a one-row table.
- **A `ProjItem`'s name clause carries traits and an FK name.** `NameClause ::= 'as' Ident (':' TraitList)? ('via' Ident)?`, all three naming the same thing. A nested table defaults to `Component` — the same construct as an inline component sub-table, with the zero-byte parent link — and its FK defaults to the group row's table name in `lower_snake_case`. **The trait decides whether the name is a column or a sibling table**: `Component` gives a path (`Agg.LinkedTable`), and elevating out of it gives the rows their own `DataId` and shard placement, a real `:>` field, no cascade on `deprecate`, and a top-level name. That is what an ETL extraction needs, since the extracted rows outlive the row they were grouped under. Capitalization is not what promotes it, which matters because capitalization is style rather than grammar.
- **Naming a source field removes it from `*`.** This replaces "a later item overrides an earlier `*` on the same name", of which it is the generalization, and it is what makes `{ *, status as account_status }` a rename rather than a copy. To keep both, mention the field twice. The same selector works in a `TableBody`, where it carries forward the previous version of the table.
- **A cross product is `via` a `Null`-derived type.** `A >< B` where no `:>` edge connects the two is a **compile-time error**, and `via Unrelated` where `type Unrelated : Null` says the join has no condition. `via` already names the join edge, so a typed absence there says the edge is absent and records why in the name the author chose — the discipline the language already applies to absent values, one position over. No grammar changed: `via` took a path, and a type name is one. An accidental cartesian across a distributed database is expensive enough to be worth making unwritable, and forcing one deliberately stays available.
- **A rollup is a parameterized binding.** `retain ... as <Name>` names a binding of one `Grain` parameter, applied once per level. The **injected `bucket_start` is withdrawn**: generating it put the observation grain into scope with nothing naming it, which is the ambient-time reading the language rejects everywhere else, and the author now writes `group { truncateTo g created_at as bucket_start, ... }`. That deletes the `aggregate` keyword, `AggregateDecl`, the injected column, and the two-level "time is the outer group" rule in one move. With no chain naming it a rollup binding denotes nothing queryable, because the grain is unbound — the ordinary reading of an unapplied function. `using` still names the raw step's time source, and the binding must group on the same column or the commit is rejected.
- **`split` and `merge` are withdrawn; a split is a set of bindings and a merge is a join.** Both were imperative statements asserting a decomposition nothing could check — `split Customer into { ... }` could produce fragments no join would reassemble, and the language would not say so. As queries the derived-key rules check them. **The fragment retaining the source's candidate key is the root; every other fragment gets a `:>` to it, and no fragment or more than one holding the key is rejected** — losslessness made structural, since a fragment that drops the key derives a degenerate one and would have pinned its source anyway. The generated FK is named after the root in `lower_snake_case` and is renamed by an ordinary projection. `split` and `merge` stay reserved for `split shard` and `resolve conflict ... using merge`.
- **Materialization is automatic, proposed, and operator-overridable.** It replaces the user-defined index: there is no `create index`, because which arrangements are worth maintaining is a function of observed load rather than the author's foresight. A query nobody has run is slow; the next one is fast. The maintenance queue **proposes** a view from `system.telemetry` request logs and a `Configuration` row sets the auto-approval threshold, so automatic behaviour is a policy somebody set rather than state nobody authored — the objection that already shaped the per-field time cache. `materialize`, `refresh view`, and `drop materialized view` are admin commands, not schema syntax, for the reason `retain` and `enforce` are separate statements: operational policy that changes over time and is not the schema author's decision.
- **Field types are inherited or computed, never declared.** A projected `FieldPath` keeps the source field's type and its validations; a projected expression **mints a computed type named by the field's path**, which is not a new naming rule but the existing one (a field's `where` is already addressed by its path, and that path already names its computed type) reaching a new position. Types are shared **structurally** and named by their first definer — two projections of the same function over the same source type get one type, since functor transparency makes that decidable — so the name outlives its definer's `deprecate`. A function over a key column **degenerates the key**, because injectivity is not knowable in general, which costs incremental refresh, pins the sources, and makes the result read-only.
- **Derived tables are writable, and the derived key is what decides it** — a third consumer of the meaningful/degenerate distinction, alongside incremental refresh and `deprecate` blocking. An insert decomposes into one mutation per base table ordered by FK direction, admissible exactly when the key is meaningful, every join is along a `:>` edge (so the join is lossless and each row is at most one row per base), and every undefaulted field of each base is projected or fixed by the `where`. **The `where` is a check constraint on write whose constant equalities supply values on insert** — SQL's `WITH CHECK OPTION` doing one extra job, and the mechanism that lets adding a row through `system.auth.ServiceAccount` create the linking row without the call site naming it. `delete` removes the row the key identifies and never cascades: for a `:>` join that is the referencing side, so deleting a service account leaves the `User`. Stated explicitly because it reads as though the user should go too.
- **Capitalization** follows Haskell: types, traits, tables, derived tables, and sum-type variants are `UpperCamelCase` and singular (a table is a type — `table T : Trait` uses the same `:` that `type A : B` does, and a row is an `Order`, not an `Orders`); fields are `lower_snake_case`; functions, predicates, and constraint names are `lowerCamelCase`; namespace segments are `lowercase`. The field/function split is deliberate — a field names stored data and reads as a column, a function is code and reads as Haskell. Capitalization is style checked by the linter, not grammar: `Ident` admits either case everywhere and position decides what a name is.
- **Placement is separate from identity and needs only a total order.** A candidate key answers *which row is this*; placement answers *where does it go*. `DataId` is excluded from satisfying the candidate-key rule — counting the surrogate would make it vacuous — but it is monotone, total, and present on every row, so it is always a valid *placement* key. Consequence: **every shard can be split**, and a declared partition space only chooses where the cut falls. `LogData` therefore gets the root it was missing: a `system.shards.LogSegment` row keyed `{ origin_server, period_start, retain_node, retain_branch }`, with every component derivable or decidable at write time — `origin_server` from bytes 6–7 of the row's own `DataId` (the virtual column, declared nowhere), `period_start` from bytes 0–5, and the retention pair from the `retain` predicate, which may reference only the rollup's group keys and the time source. The key was `{ origin_server, period_start, branch }`; `branch` was renamed `retain_branch` because a DAG branch is a different thing under the same word, and `retain_node` was added because reordering `retain` branches renumbers the indexes, so an open segment and new rows could otherwise share one key under two retentions. Routing costs zero stored bytes, the log table itself stays keyless, the segment root carries the key instead, and retention aligns to segments so pruning becomes an unlink. A third layer is named to keep this safe: an **extent** is storage, a **shard** is authority, and `PhysicalLocator` already draws the line by carrying `plShard` but *not* the byte offset — so moving a row within its shard rewrites one `log_index` value and is invisible to the graph, while moving it across shards is a recorded split. Splitting a shard with one root row is thus possible but yields a **shard group** sharing a primary, because non-root uniqueness, `assert` evaluation, and `Ordinal` assignment are all defined as within-one-shard. **No syntax was added**: a `shard by <grain>` clause on `retain` was considered and rejected, since the segment key supplies the same alignment for free.
- **Operational tuning is a row, not a trait.** A trait declares what a table *is*; a `Configuration` row declares how a deployment *treats* it. Extent size and segment grain track hardware and must differ between staging and production without branching the schema, so they are rows in `system.shards.ExtentPolicy` keyed by table path, with `system.shards.ExtentOverride` keyed `{ table_path, server }` for per-server exceptions, resolved most-specific-first — two tables rather than one, because a `Null`-derived "all servers" variant in a key is rejected. Traits consequently take **no parameters**; where a declaration must name a policy the spelling is a reference to a policy row, as `Hashed Text using system.crypto.HashPolicy.password_v2` already does. Same separation as enforcement modes, queue retry policy, and retention.
- **`system` is a namespace, not a replication class.** It had been listed as a fifth shard type in `transaction-graph.md` and as a table type in `namespaces.md`; both are corrected. Tables in `system` carry ordinary replication traits — `system.integrity.Violation` is `LogData`, `system.shards.Node` is `Configuration`. Namespace says whose a table is and who may see it; trait says how it propagates.
- **There is one `delete`.** The `delete!` "hard delete" spelling is **withdrawn**. Its documented distinction from `delete` was not one — both left the record in the transaction graph and removed the row from the current state, which is the definition of a delete, so `delete!` was redundant syntax carrying a sigil that promised something it did not do. `delete` is an ordinary mutation: it appends a tombstone version, the row is absent at sample moments at or after it and present at any earlier `at`, the `DataId` is never reused, and writing a new version restores it. The operations `delete!` would have had to mean are `erase` and `scrub`, both administrative acts reachable only from `ErasureCmd` and never from the query language. See OQ-036.
- **Removal is administrative, and there are three verbs, not one.** `erase` closes a row's history, `scrub` destroys bytes, and `release` frees a reserved `unique` value. All three are `ErasureCmd` productions, all three take a mandatory `reason`, and none appears in `Query` or `Mutation` — which is the constraint that withdrew `delete!` rather than giving it these semantics. `row` was considered as a marker (`erase row …`) and not reserved: it is the likeliest identifier in any schema, and `erase <table> <id>` is unambiguous without it. `bypass` gained a second kind, `erasure`, kept separate from `bypass access` because reading an erased row's history is narrower and rarer than administering a namespace (OQ-036).
- **`diff` compares two graph points, never two moments.** `Table diff "a" to "b"` returns the query's rows keyed by their derived key with generated `before`, `after`, and `change` columns; a degenerate derived key is rejected, since nothing would identify a row across the two points. Graph points rather than moments because a diff must be reproducible and a moment is not a graph position. **There are no window functions and none are planned** — a rollup level is a real table and queries compose, so period-over-period comparison is a shifted self-join. `union`, `except`, `intersect`, `window`, `over`, and `partition` are consequently unreserved. `now`, as a query-level binding for relative sampling (`at now - 30 day`), is available if wanted and currently unneeded.
- **`indexed` gained a `using`.** `Doc indexed using <predicate>` names a `Text -> Bool` over the document key; a key that fails it spills instead of interning, however far below the cap the field is. `using` rather than a new clause word, because the established spelling for a declaration that must name a policy is a reference to a function or a row (`Hashed … using`), and this reuses it with no reserved word added. `deprecate` correspondingly takes a `NamePattern` rather than a bare `QName`, so a polluted key table is cleaned in one statement (OQ-033).
- **The virtual columns are projections of the row identifier**, which makes `created_at` an instance of a rule rather than a special case: bytes 0–5 are `created_at`, bytes 6–7 are `origin_server`, and a component's id suffix is `ordinal`. Two are added. **`origin_server`** is typed `:> system.shards.Node` rather than `Int` — as a bare 2-byte integer every "which server wrote this" query is a manual join against a magic number meaningless outside the registry that defines it. It is the only virtual column that is a reference and the only one resolving through a candidate key rather than a `DataId`, since the projected bytes *are* `Node`'s key; `Node` is `Configuration` so the join is local everywhere, and its rows become permanently non-prunable, which costs nothing at one row per server and is what keeps a retired server's historical rows readable (an `| RetiredServer` alternation was rejected — it puts an absence case in every query for no gain). `system.shards.LogSegment` had been hand-rolling this projection as a declared `server` field; that field is **removed** and its key now names `origin_server` directly, which required settling that virtual columns are eligible in a key — all of them but `updated_at`, which is excluded for the same reason a `Behavior` is: not because it is virtual, but because it moves. `period_start` stays declared, and the asymmetry is the point — `period` is a `Configuration` value that may be retuned while routing is never revised, so a truncation under a mutable policy must be pinned at write time; bytes 6–7 cannot be retuned and so need no pinning. **`ordinal`** closes a real gap rather than adding sugar: without it there is no way to *state* document order in a query, only to receive it from a range scan, which cannot be restated after a join or reversed. It is the position at the row's own level, not the full path — nesting makes a path variable-length, the rendered identifier already spells it, and a column whose type varied with nesting depth would be worse than what it duplicates. **The sequence counter (bytes 8–11) stays unexposed**: it disambiguates within one server-millisecond and is a tiebreak rather than an ordering — two servers' values are incomparable, and the clock-regression clamp deliberately continues it across a held timestamp — while `DataId` order already gives the total order anyone reaching for it wants. `updated_at` remains the odd one out, reading the head locator rather than the identifier. See `transaction-graph.md`.
- **Effects are a ladder, and one missing lift carries the whole "no external calls in a commit" rule.** `Pure ⊂ Read ⊂ Tx`, with `Effect` outside that chain and connected by exactly one arrow: `commit :: Tx a -> Effect a` exists, and nothing takes an `Effect a` to a `Tx a`. This **replaces the `a -> IO b` signature rejection**, which was weaker — a signature check does not close `traverse` over an effectful function inside a validation, or one hidden behind a type alias, and an unconstructible type does. `IO` no longer appears in any DataCode signature at all. The arrow that *does* exist is what makes handlers workable: a handler runs in `Effect` and calls `commit` freely, so advancing a queue row's state or writing 50 000 ingested rows in batches is an ordinary transaction subject to every validation and assert. It also fixes retry granularity by placement — everything before the first `commit` is redone on retry, everything after is not. `Effect`'s capabilities come from the handler's `Configuration` row, never from code, so a handler cannot reach an ungranted host and never holds a credential in a compiled constant. See `schema/functions.md`.
- **`every <Expr> emit <queue> { … } where <cond>` is the second event trigger form**, and its interval is an **expression**, not a literal — a `LengthLit`, a field of the row, or a `Configuration` path are one production. That is what retired the interval-override mechanism that was briefly proposed: you do not need an override when you can point the expression at wherever tuning should live. It fires per row of the table it is declared on, so fan-out is what "declared on a table" already means rather than a feature of `every`. **False-to-true still holds** — sampling observes the transition between ticks instead of across a write — which costs a `system.events.TriggerState` **row** per (trigger, row) — the held bit is a column, not the storage unit — and is why schema commit **warns** when the solver could have closed the condition instead. There is deliberately **no top-level cron form**: a timer job always has rows that parameterize it (which feed, which directory, which account), so that table is the producing table and the payload stays typed against a row it can name. `schedule` and `cron` were considered and not reserved.
- **Inbound arrival is not an event.** A webhook, a connector row, and an operator API call are *writes*: a route whose functor inserts into a landing table, after which the ordinary insert case of `on … emit` covers whatever happens next. Modelling arrival as a trigger form would have provided neither of the two properties the event system exists to provide — there is no side effect to defer and no external call to keep out of the commit, because the row *is* the durable record. This makes OQ-020 purely a route concern.
- **`next <UniqueName>` allocates a sequence, and the scope of a sequence is the scope of the uniqueness it serves.** `next` allocates within the named `unique` constraint's field list minus the field being defaulted, so `unique orderRef { customer, order_num }` gives a per-`customer` counter living with the customer row — a local read-modify-write in a transaction that already touches that shard, with no central coordination — while `unique invoiceNum { invoice_num }` has an empty prefix and reaches the shard holding that constraint's value index, exactly like a table-wide `unique` (OQ-007). Both cases fall out of one rule and **the shard cost is readable off the declaration**, because it is the prefix-reaches-the-root question the candidate key already asks; a table-wide `next` warns at commit, a prefixed one warns about nothing. Gaps are guaranteed (an aborted transaction burns a value) and gapless numbering is a *reporting* requirement served by a view over the log, not by the allocator. `next` is an allocation rather than a value, so it is admissible only in a `DefaultClause` on a field the named `unique` includes. `sequence` and `serial` were considered and not reserved — a modifier would restate a scope that is already declared.
- **A `Component` default constructs the row**, in the same transaction. A `RecordLit` `DefaultClause` on a `:>` field whose `SubTableTraits` include `Component` constructs; any other `Expr` references an existing row (`settings :> Settings : Component = { theme = Dark }` versus `created_by :> User = authed_user`). Under the table-valued rule below, `= { theme = Dark }` is sugar for a one-element literal. This is what closes the "default table" requirement with no trigger machinery: a row that must exist whenever its parent exists is a total function of the parent, `Component` already owns lifetime, and `=` already takes a row construction. No shard question arises, since a component lives in its parent's row-rooted shard by definition. **Deleting a parent deletes its components**, mechanically over `Component` edges — no cascade declaration and no depth limit, because the edges *are* the ownership. A cross-table in-commit trigger to a non-`Component` table is **refused**: if a row must exist atomically and has independent identity, that is a modelling error, and admitting the general case would put arbitrary user mutation in the commit path with unbounded cascade depth and a cost unreadable from the schema.
- **A function-typed column is a `FunctorRef` with a static signature.** Storage changes nothing — `FunctorRef` is already a column type and already points at a serialized DSL term — and what is new is that the compiler knows the signature. A function type is declared `type Renderer = Amount -> Read Html`; **a field names a declared function type and may not write an arrow inline**, which makes "every function in a field shares one signature" a property of what a field *is*. Values are a named function or a lambda literal, both already grammatical (`Behavior`'s mandatory `=` lambda is the precedent), so **no syntax was added**. Template-Haskell-style `[| … |]` was rejected: its whole appeal is promising arbitrary Haskell inside, which the GADT DSL cannot deliver, and a syntax selling a permanent lie about the ceiling is worse than none. Literals are admissible only on `Reference` tables — because inserting a `Reference` row *is* a schema transaction, so "it still has to compile" is structural — while `Configuration` admits a `FunctorRef` and no literal: **code by schema, selection-among-code by data.** Restrictions all follow from function types having no equality: rejected in `unique`, `order by`, `group`, `==`, `indexed`, a candidate key, and a field `where`; queries in the body must be rooted at `self` like an assert's; the call graph must be acyclic (decidable, since it is in the schema graph); and an `Effect` function type is name-only, because effectful code is compiled-in and a data write may select a handler but never author one.
- **A template is text with holes, and cardinality is the control flow.** One production — `Hole ::= '{{' Query ( 'using' QName )? '}}'` — where the query's result count supplies every construct a template language usually spells: zero rows render nothing (the conditional, and it is just the query's `where`), one row renders once (plain interpolation, since `self` is a query of one row), N rows render N times joined by the template's separator (the loop). `each`, `if`, and `else` were consequently **not reserved**. `using` names the template applied per row; omitted, the active theme's render function for the row's type applies, which makes the template system and the theme system **one mechanism** rather than two. The separator is a field on the template's `Reference` row, not part of the hole. The one gap — a negative branch — needs no syntax: outer-join a `Null`-derived catch-all and the render function for the absence variant handles it, so **absence renders because absence is a type**. Formatting is an ordinary function call, so there are no filters or pipes; escaping follows the output type, so emitting unescaped markup requires an `Html` value and injection safety is a typing property with no raw-output form. Holes are `Read` and rooted at `self`, for the same read-cost reason asserts are anchored. Cost stated plainly: **a page whose layout is not derivable from the schema walk cannot be expressed as a template**, and fixing that would turn one production into a language.
- **A `Reference` table is needed exactly where a fact originates outside the schema graph.** Self-hosting means system *state* is queryable, not that declarations get mirrored into rows — the schema graph is already queryable, so restating a declaration as a `Reference` row gives two authorities for one fact. `system.events.Handler` qualifies, because it is the bridge that makes `handler system.connectors.ldap.syncUser` resolve against Haskell the schema graph cannot see. A second case qualifies too: a code value that must be compile-checked and is stored as a 2-byte variant tag. `system.events.Queue` met neither, and was removed on this rule. (The exemplar was `…ldap.sync` until `sync` was reserved by `force sync`; a `QName`'s last segment is lexed like any other token.)
- **Guiding principle**: where a choice is otherwise balanced, pick the spelling a Haskell reader would expect. DataCode's operators may carry narrower meanings than Haskell's — `where` constrains rather than binds — but the shape should be familiar.

Settled in the 2026-08-28 design review. Each is normative in the `docs/` file named; the bullet is the decision record.

- **A `:>` field whose target carries `Component` is table-valued.** `headers :> RequestHeader : Component { … }` denotes **all** of that request's header rows, in `ordinal` order. A `:>` to any other table is single-valued and wraps one `DataId` — and a component has no `DataId`, so the field cannot be wrapping one; a parent-prefix range scan is what it denotes instead. That is what resolves the standing disagreement between `tables.md` and `traits.md`. Consequences: `= { theme = Dark }` is sugar for a one-element literal, so the default clause and the field type agree; a table-valued field is rejected in a key, in `unique`, in `order by`, and in `==`, and is excluded from `*` unconditionally; and `ordinal` stays on **stored** components, withdrawn from nested tables produced by `group` or by a projection sub-nesting, where nothing was inserted in any order. Because 1:many inline declaration therefore already exists for owned children, `:<` shrank to the case that needs it. See `schema/tables.md`.
- **`Component` is 1:many structurally, and a many:many *link table* may still be a `Component`.** The parent's `DataId` *is* the component's identity prefix, so a second parent has nowhere to live: cardinality is 0..2³² from the parent and exactly 1 from the child, which makes a many:many *identity* unrepresentable rather than merely disallowed. The ordinal follows from the same fact rather than being a separate choice — single parent, so the parent's id is the prefix, so an ordinal disambiguates siblings, so the parent link costs zero bytes and the subtree is one range scan. A component may still reference outward freely, so `OrderTag : Component` of `Order` carrying `tag :> Tag` is a legal many:many, shard-local to `Order`. The discriminator is the *other* invariant, that nothing outside the parent's subtree may reference a component: **use a `Component` for a link exactly when nothing needs to reference the link row itself from outside, and the link's lifetime is the owner's.** A `Membership` row a `Payment` points at cannot be a component; one nobody points at can. Two corrections to the assumption this came from: outward references are **not** limited to `Reference` targets — the cost of crossing a shard is a warning naming the edge plus coercion out of `enforce always` — and `:<` does not *make* a relationship many:many; the two `:>` fields do. One consequence worth stating outright: a two-`:>` link table lands in **one** side's shard family, decided by the head rule, and the asymmetry is unavoidable, so it should be chosen deliberately rather than by declaration order.
- **`Component` shrinks to one declared bit, and that bit is owned lifetime.** A `Component` **may declare `unique`**, checked within the parent, which costs one shard-local check and closes the two-identical-`(order, tag)`-links gap; the key exemption said a component does not *need* a key, never that it may not have one. `Component` **stops occupying the replication-trait slot** and becomes a marker trait beside `Personal` and `Keyless`, so `table OrderTag : UserData, Component` is legal — "wherever the parent is" is not a replication *policy*, it is what rooted placement already means, and the row's replication answer comes from `UserData`. The ordinal representation is **derived**: eligibility is the key's head being an FK that reaches the shard root, which is the rule that already decides placement, so it cannot drift. What the key cannot say is lifetime — `Order` keyed `{ customer, order_num }` and `OrderLine` keyed `{ order, product }` have the same shape and opposite answers on a parent delete — so `Component` survives as exactly that declaration: it means cascade, its absence means restrict. Everything it used to bundle is now a consequence: `created_at` and `origin_server` inherit, nothing outside the subtree may reference it or the subtree is not prunable as a unit, the row cannot be reparented, the surrogate identity is the position. Two costs priced rather than hidden: **ordinal assignment is a per-parent read-modify-write**, coordination-free because the parent's shard primary linearizes writes but still a serialization point, which schema commit prices exactly as it already prices a table-wide `next`; and **`created_at` is the parent's**, with the declared-`Timestamp` escape named at the point of decision rather than found later. The space case is roughly 24 bytes a row — `Ordinal` (4) rather than `DataId` (12), a zero-byte identifier prefix rather than a 12-byte FK column, and no declared counter — and that is the whole of it. The counter-scoping credit belongs to `next <UniqueName>`, which any rooted key already gets.
- **A write that changes a row's *shard root* is a delete plus an insert, not an update.** A rooted key can be invalidated by exactly one thing — the placement-key FK being updated — because an FK functor resolves to a *live* row and a key may not carry a `Null`-derived variant. Treating that write as delete-plus-insert deletes four rules: the recorded cross-shard migration it would otherwise need (a delete in shard A plus an insert in shard B is an ordinary two-participant transaction, already fully specified), "a component cannot be reparented" as a standalone invariant, any rule about placement-key mutability, and the absolute prohibition on referencing a component from outside, which relaxes to a warning. **The trigger is a change of shard root, not of any placement-key field.** Changing `Order.order_num` — a non-head field of `unique orderRef { customer, order_num }` — leaves the root unchanged, so no ordinal is invalidated and nothing crosses a shard; and a **root** table's candidate-key change is not a re-key at all, since a shard is named by its root row's `DataId`, which does not move. That second narrowing is what makes username change, email change and branch rename possible; the broader phrasing rejected all three with no escape. **The gate is every `unique` on the table, headed by the placement key's own head field.** Where any `unique` is headed elsewhere, the re-key is rejected naming the constraint, because the delete tombstones the row, a tombstone does not free the value, and the insert then writes the same value and collides with its own tombstone — and because a `unique` rooted elsewhere is checked against whichever population the row sits among, so moving the row changes what the constraint means with none of its own values changing. The escape is the existing deliberate one: `release` the offending value with its mandatory authority and reason, then re-key. Auto-releasing inside an update would defeat the property that a reserved value is released only deliberately, and would put an `ErasureCmd` inside the query language. Two things this adds, both needed anyway: **deleting a row with live inbound non-owned references is rejected** — this is RESTRICT, and it follows from the FK functor's signature rather than being new policy — and re-keying is rejected wherever that delete is. The row's `DataId` genuinely changes; it became a different row in a different shard. See `schema/tables.md` and `transaction-graph.md`.
- **A re-key records itself on the transaction node, not on the row.** A supersession is a fact about a *transaction*, so a row column stores it on the wrong object; sparsity is the lesser objection. The record is five fields — `{ table, old row key, new row key, old shard root, new shard root }` — with no reason and no authority, because a re-key destroys nothing and the actor is recoverable from the request log. The identifiers are **`head_index` row keys**, a `DataId` or a `DataId` plus one `Ordinal` per nesting level, not `DataId`s: a component has no `DataId` and its identifier is variable-length, and naming a component reparent is precisely what this exists for. Equality of the two roots is how a reader tells a same-shard re-key from a cross-shard one — no flag, no node kind. Both prepared nodes carry an identical record and the commit node carries none, so the record is never load-bearing for applying a transaction and an old decoder that ignores it still applies the delete and the insert correctly. The pairing is **not derivable** from the mutation list, which is why the record must be explicit rather than merely convenient: two rows of one table re-keyed in one transaction cannot be matched, because the values that would disambiguate them are exactly the ones that changed. One gap the record does not close on its own — it is old→new and lives on the *old* row's shard, while every consumer starts from the successor — is closed by a server-local, unreplicated **new→old index derived from it**, the same posture as `PhysicalLocator`. Costs priced: one pointer word on every `TxNode` in the cluster forever, plus content when populated; the Cap'n Proto spike measured a data-section scalar and must be re-run with a pointer field before that number is leaned on. Consequences settled with it: the predecessor's post-state is the successor's pre-state, so the version-chain walk follows the link and an `on` condition is a transition across it (`on status is Shipped` correctly stays silent rather than re-firing on the insert half); component ordinals are **preserved** by prefix substitution rather than reassigned; a re-key resets `created_at` and `origin_server` on the row and its subtree; the tombstone at the old key is **terminal**; `diff` reports `Removed` plus `Added` and never learns about the link; the `erase` cascade follows re-key links transitively forward, with an outbound-edge entry in the report; a `Violation` on a re-keyed row stays in the source shard and resolves forward; and a tertiary, holding current state only, cannot answer re-key history or per-field timestamps.
- **Every field added to an existing table declares a default, and the rule is unconditional.** Omitting one is a compile-time error whether the table holds zero rows or forty million — deliberately the opposite polarity from "mode is mandatory on a *populated* field", which is conditional because the blast-radius *number* is what the author needs in hand, where here there is no number and a conditional rule would only mean a schema file that succeeds in development and fails in production. This replaces three contradictory statements about what an added field reads on older rows: the default, `NotFound`, and `NotGiven`. The latter two are wrong for one reason — both sit outside the field's declared type, so `loyalty_tier : Tier` reading `NotFound` makes an exhaustive match over `Tier` non-exhaustive because of an evolution that happened later. Requiring the default outright beats requiring *either* a default *or* a `Null`-derived variant, because the weaker rule has to infer which variant an old row reads and a type may carry two. **Nothing is backfilled**: the value is computed at read from the schema node current for the row version being read. The admissibility criterion is **`Pure` *and* stable for the life of the row** — reproducible at read from the old row plus the schema node, and identical to what an insert after the add would have stored. `Pure` alone is too weak: `= other_field * 2` takes no ambient input but an old row recomputes it at read while a post-add insert froze it, so two populations diverge with nothing in the row saying which regime applies. `= next orderRef` is rejected because it allocates rather than evaluates. `= authed_user` is rejected because it is transaction-ambient input rather than row data — the same shape as *time is a parameter, never ambient* — and **not** because no token exists: it resolves, to whoever is reading, which would make `created_by` differ between two readers of one row. A `:>` field to a `Component` target needs no default at all, its old-row value being the empty table. Three rules travel with it: the default must satisfy the field's own `where`; no `unique` field may be added to a populated table, because every admissible default is constant; and the rule binds the **effective field set** and generators — a trait gaining a field, `Doc indexed` siblings, rollup levels, connector shadow schemas — not table redeclaration. The documented escape for a default the criterion rejects is the binding form (`Customer = Customer { *, Bronze as loyalty_tier }`), which is a real rewrite and is frozen into storage. An aggregate column added to a live retention chain is typed `T | NotRetained` **and defaults to `NotRetained`**, so the rule applies uniformly with no exception for rollup levels. The full form-by-form table is in `schema/evolution.md`.
- **A field path is bound to its declared type for the life of the table.** Re-declaring a deprecated field with the identical type is an un-deprecate needing no default; a different type is rejected with "choose a new name". Both other answers break something — treating it as an add makes rows written before the deprecation read the default instead of their stored value, and treating it as not-an-add leaves rows written while the field was hidden undefined. Mirrors the variant-tag permanence rule.
- **A schema object may not name a data row.** This is what decides a `:>` field's default, stratified by the target's trait: a `Reference` target admits one (the FK stores a 2-byte variant tag, and a `Reference` row *is* schema); `Configuration` does not (replicated everywhere but a deployment fact — resolve by *name* at runtime, as `CipherPolicy.key_name` already does, so staging does not share production's key); `UserData` and `LogData` do not (shard-local *and* deployment-specific). Not a new rule, just one that now covers three forms instead of one. It rejects a literal `DataId` default and a lazily evaluated query default without either needing its own rule. An **eagerly resolved** query default fails neither test — resolve once at schema commit and freeze the result into the node and it is as stable as a literal, telling a `Query` from an `Expr` is already applied in three positions, and "exactly one resolved row" is a requirement `matches` already carries — so **the reason it is still restricted is the stratification, not the difficulty**.
- **A `Reference` sub-table may be seeded where it is declared.** Constructing a row as a default stays rejected (a construction needs a transaction and a row committed last year has none); what is admitted is seeding the sub-table in its declaration and then defaulting to one of those rows by query — `f :> T : Reference { name : Text unique } [ { name = "a" }, { name = "b" } ] = T where name == "a"`. Every part is a schema act, so all of it belongs in one schema commit: an inline sub-table is already sugar for "declare a sibling, then reference it", inserting a `Reference` row is already a schema transaction, and the default names a `Reference` row, which the stratification permits. It replaces a declaration plus N scattered inserts for the small code tables that want exactly this — `OrderStatus`, `Tier`, `Priority`. `FieldDecl` gains `SubTableRows ::= TableLit`, unambiguously, because after a `SubTableBody` nothing else in a `FieldDecl` begins with `[`. Three constraints the grammar cannot express: `SubTableRows` is admissible only where `SubTableTraits` names `Reference` (on a `Component` or `Configuration` sub-table the rows would be *data* written by a schema commit); the default query must resolve to exactly one row, which the `unique` in the body is what guarantees; and the query resolves at schema commit and is not re-evaluated on read.
- **Membership is `` `elem` ``, and the multi-field form is a `RecordLit`.** `` status `elem` [Pending, Shipped] ``. `in` stays reserved for `let … in` and gains no second meaning — admitting it as a comparison creates a real ambiguity, and the proposed disambiguation ("the first `in` at bracket depth 0 closes the binder") does not count `let` nesting and breaks `let a = let b = 1 in b + 1 in a * 2`, which parses today. Backtick infix at Haskell's fixity already exists and `Data.List` is auto-available, so this costs one production: `TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'`, shared with the multi-row insert. The multi-field form is `{ customer = c, order_num = n } `elem` <table>` — a `RecordLit`, not a tuple, which reuses an existing production, needs no `TupleLit`, binds by name rather than position, and makes the element shape identical to the insert literal's. One element shape everywhere.
- **Case insensitivity is a storage transform, not a second equality.** `==` stays exact. A second equality operator would have to be understood by `unique`, by every index, by join matching and by derived-key propagation — a large blast radius for a convenience. Canonicalize on write instead, at step 4 of the field-write order, which already applies the type's storage transform and until now was used only by `Secret` types: `type Email : Canonical Text using system.text.Policy.email` stores the folded, normalized form, so `==`, `unique` and the index are ordinary operations over ordinary bytes. Four details decide whether this is right or subtly wrong: fold with full case folding (`ß` → `ss`), never `toLower`; keep the original in a second field where display matters (`email : Email unique` beside `email_as_given : Text`), which makes the trade visible rather than hidden in an operator; NFC normalization is the other half and runs at the same hook, which is why the transform names a **policy row** rather than being fixed; and for regex the case flag goes on the pattern row, so a `Reference` pattern table with `{ name, pattern, case_sensitive }` gets it with no grammar at all, while a bare `StringLit` pattern stays case-sensitive — literals are exact, policies are configurable. **Rejected: a function in `UniqueDecl`** (`unique emailRef { fold email }`). It keeps the original casing, but an index over `fold email` is usable only by a query that spells `fold email`, so every lookup carries the function; storing the canonical form and keeping the original beside it costs the same bytes and reads better.
- **Pagination is a cursor, not an offset, and there is no exact total.** `LimitClause ::= 'limit' NumLit`; **no offset**, and none is added. A cursor needs no syntax — given a total order, "resume after the last row" is `where (ordering tuple) > (last values)`, an ordinary `where` — so DataCode gets cursor pagination free and would have to *add* a production to get offset. Offset is O(offset) and hides it: every shard must produce and discard its prefix so the coordinator can merge. The one advantage offset would have had here does not survive contact: DataCode could make offset stable, because a query pegged to a `(commit node, sample moment)` pair sees the same relation twice — but only if the caller threads the peg, and `at` defaults to request arrival. A cursor threads the peg and the position in one token. **No exact total**: `100 of 100+` is produced by fetching `limit + 1` and discarding the extra, exact for the "is there more" bit at one row of cost; a real total is a separate query, and `count (Order where total > 100)` already is one. **`limit` requires a total order**, taken from an explicit `order by`, else the source's declared one, else candidate key ascending — and **any stated order is extended by the candidate key as a final tiebreak**, because `order by placed_at desc` is not total and fifty orders sharing a timestamp put a page boundary mid-tie, where a resume predicate then skips or repeats the rest. `limit` on a degenerate-keyed source declaring no ordering is a compile-time error. This closes the "pagination config" item that stood open here. `100 of 100+` and the printed continuation are CLI display conventions, not grammar — see `cli.md`.
- **`:<` declares the child's FK and nothing on the parent.** The name goes on the right, with `via`: `:< Comment via document { … }`, and `BackRefDecl ::= ':<' QName SubTableTraits? ( 'via' Ident )? SubTableBody?`. The design pass came back proposing a table-valued reverse column on the parent; that is **withdrawn**, with every rule written to support it. Three reasons, the third deciding: it is a second spelling for a join, which already covers navigating against the reference direction with `as` mandatory; it puts a `*`-exclusion special case in the language that exists only because the feature does; and the syntax would not look like what it costs — a non-owned child has its own `DataId` and possibly another shard, so `Order { *, comments { … } }` hides a cross-shard fan-out where `Order >< Comment as c` looks like the join it is. Nesting stays available through the join plus a sub-projection, where the cost is visible. `via` already means "names its FK back to the containing row" and omitting it already has a default (the parent's table name in `lower_snake_case`), so three advantages follow: no phantom field name in a body where it is not a field, no new meaning for `via`, and `deprecate` addresses the thing that exists. The parse stays unambiguous because the item begins with `:<`. Spelled `:<` and not `<:` because `<:` is the subtyping operator everywhere it appears and DataCode's `:` already *means* subtype, so `comments <: Comment` would be a well-formed sentence saying the wrong thing. Scoped to children that are **not** owned — true linking tables, and children with independent lifetime — since inline 1:many already exists for owned ones. It removes the second *declaration*; a writable derived table over a linking table removes the second *call site*. Both are worth having and the docs should say which is for which.
- **`File` is a first-class type, DataCode is the origin, and its content is readable in `Read`.** No external CDN — DataCode serves the CSS and JS. Two consequences change the design as proposed: a `File` **carries a media type**, not just octets, because the HTTP response needs one, which makes an octet-stream response mode required work; and content must be readable in `Read`, not only in `Effect`, because a stylesheet is both served at a URL and inlined into rendered HTML for mail, and a template hole is `Read`. The read is bounded by a `system.config` size cap, above which the value is reachable only through the streaming handler. Storage tiering is settled three ways: where a `File`'s chunks are laid out **inside** the graph is a `Configuration` row beside `ExtentPolicy`, per field with a per-server override — pure tuning, invisible to the model; bytes on the server filesystem with the row holding a digest and a path are available as a **separately named type**, never as a quiet per-field flag, because the type name is what warns that four properties are forfeited (`verify shard` cannot check the bytes, replication does not carry them, a restore does not restore them, `scrub` cannot reach them); and a purely external reference is an ordinary `Text` URL needing no mechanism. A size cap ships as a `Configuration` row, with the chunked-and-swarmed path as the way past it rather than a bigger number — and that path is mostly built already, because a `File`'s chunks are `Component` rows named `<parent DataId>.<ordinal>`, each carrying a digest (BitTorrent's piece hash), and announce-and-fetch already exists for sequence ranges. Two changes get there: each chunk is its own transaction, which also removes the cap's cause (one large synchronous write head-of-line-blocks a linearized shard primary), and announce-and-fetch widens from sequence ranges to chunk digests. One trap named now because the model invites it: **content-addressed pieces tempt dedup, and dedup is rejected** — sharing one content row across owners breaks `erase` and collapses N access policies onto one row. The digest is for verification and transfer, never for identity, which is exactly where this departs from BitTorrent.

The remaining verdicts from the same review, each smaller:

- **A length cap is a validation, not a type.** `Text 255` and `Text 1 255` are already grammatical, so this was never a grammar question. A type-level cap makes over-length connector data *untypeable*, and the ingestion posture is that connector-sourced rules default to `monitor` so one bad row cannot halt a binlog — a cap you cannot set to `monitor` converts a data problem into an outage. `where maxLen 255` is already used in six files. What was genuinely missing: `maxLen` and `minLen` were used eight times and **defined nowhere**, and the count is now pinned to **code points**.
- **`Default a` as an injected type is rejected**, on one argument: `is` would have to carry two contradictory meanings. Take `phone : Phone | NotGiven = NotGiven`. If `Default` wraps the value, `phone is NotGiven` is `False` on every defaulted row, so the absence check — the most load-bearing thing in a language with no NULL — breaks silently; if `is` sees through `Default`, the feature does nothing. The only escape is a constructor `is` treats specially, which is the magic-`access`-identifier defect this OQ already withdrew once. The free replacement is honest about its limit: `Order where total.updated_at /= created_at` finds fields changed **since the row was created**, and does not distinguish "supplied at insert" from "defaulted at insert". Distinguishing those costs a supplied-field bitmask on the row version, deferred until merge semantics exist, because the mask reads all-ones after any merge.
- **Row numbers are `numbered <table>`, an ordinary function**, returning the table plus a generated `n` column, exactly as `group` generates `rows` and `diff` generates `before`/`after`. No grammar, no reserved word, and it takes its ordering as a parameter rather than reading it from an enclosing clause. A virtual `row_number` column was **rejected** as a correctness hazard: virtual columns are key-eligible, a row number changes when an unrelated row is inserted, and a materialized view keyed on position would renumber its whole extent on one insert. It gives `lag`/`lead` by self-join on `n-1` and running totals; it does not give `rank`/`dense_rank` (they differ on ties) or frame clauses.
- **Multi-row insert is a table *literal*.** `Insert ::= QName RecordLit | Query TableLit`, decomposed by base-table key, bounded by `max_transaction_rows`. Update-all is spelled `Order where True { … }` — an explicit `where True` on the one statement that rewrites every row. A mutation returns a commit node and an affected-row count, never rows; read the new versions back with a query pegged `at` that commit node.
- **Nesting happens in the projection, not in a `nest` clause.** `ProjItem ::= FieldPath Projection? NameClause?` absorbs both the nesting ask and the query side of `:<`.
- **Materialized views need no second engine.** Neither LMDB-extra nor SQLite: a view's rows *are* rows, and they already have a format, an index, a locator indirection, a compactor, a scrubber, a backup story and a wire protocol. SQLite would add a second of each plus a serialization boundary that breaks the zero-copy claim for that path. The only genuinely new physical concepts are a **derived extent** (droppable, unreplicated) and an **arrangement** (one LMDB sub-database per view and order) — and an arrangement is also what an index is, which is the physical content of "materialization replaces the user-defined index". DuckDB is worth having as an Arrow/Parquet *export target* from a tertiary, never as an engine.
- **The `=~` restriction stands; its stated reason does not.** "TDFA is a DFA engine, so a pathological pattern costs no more than a linear scan" is false — TDFA builds its DFA lazily and caches states, and a ten-character pattern was measured exhausting a 3 GB heap. The restriction is kept and re-founded on provenance, transparency, and a commit-time pattern budget. Two corrections travel with it: TDFA defaults to `multiline = True`, so every `^…$` predicate written so far is bypassable by an embedded newline and the flag is pinned to `False`; and its POSIX character classes are ASCII-only. Parameterised patterns are deferred — alnum is the wrong safety property (digits are alnum and `a{800}` is the attack; the property wanted is **positional**, that an argument may only occupy an atom position in the parsed pattern), the motivating example does not typecheck, and the repaired residue is already expressible by putting the pattern in a `Reference` row and reaching it by FK.
- **Every `Ident`-typed identifier argument in the CLI grammar is retyped `StringLit`**, because a rendered `DataId` begins with a digit and cannot lex as an `Ident`. `cancel` is adopted; the `Ephemeral` trait it arrived with is deferred to its own scope. `split shard … at key` was never removed and stays.
- **Deferred, with reasons**: recursion and transitive closure (real new expressiveness, orthogonal, and blocked on the tension between "no `Null`-derived variant in a key" and every tree root's nullable self-FK); `in` as an operator (`` `elem` `` covers it); the `Ephemeral` trait; the supplied-field mask; the `.dc` export format (blocked on the table literal *and* on a scrub-replay rule for re-import); parameterised regex; `Default a` and `Text 255`, rejected on the merits above.

- **Open**: UI hint key vocabulary (`schema/traits.md` — the `UiHint` syntax is settled in `schema/railroad.md`; only the key set is open, and it belongs with OQ-009 and OQ-016); package import scope (`schema/functions.md` — `import` selects from what is registered and `system.config.AllowedPackage` gates which libraries may be registered, but the registration mechanism, who performs it, and whether a registered name can be effect-indexed automatically are unspecified); how a validation is addressed when one predicate function is applied twice in a block (`minLen 8` and `minLen 12`) and how a bare lambda predicate is addressed at all — the rule says the address is the function applied, while six sites across `evolution.md`, `railroad.md`, `integrity.md` and `cli.md` write `minLen12`, and neither spelling gives a lambda an address; the cardinality of a document path, since a duplicate object key produces sibling nodes and an array element has no name (`schema/queries.md`); how a `Component` row is named in a mutation, having no `DataId` and being identified by parent plus one `ordinal` per level; and the spelling of a cross-table uniqueness constraint, which `system.schema.Branch.name` and `system.schema.Tag.name` need and which `UniqueDecl` and `StandaloneUnique` cannot express, both being single-table.

### OQ-030: Event Functor Syntax ✓ ANSWERED
**Answer**: `on <condition> emit <queue> { <payload> }` on the producing table, and
`handler <FunctorRef>` on the queue table. Replaces the `assert event { <FunctorRef> }`
placeholder. See `events.md` and `schema/functors.md`.

Each of the three defects in the placeholder is addressed by a different part of the answer:

- **Not an assertion** → `on … emit` is its own statement. `assert` states an invariant that
  can abort a commit; an event registration declares a deferred effect that can abort nothing.
  The name `event` is no longer special to `assert`.
- **No trigger condition** → the `on` expression, with one uniform rule: **an event fires on a
  `False` → `True` transition of its condition, never on the condition merely being true.**
  For stored fields the transition is observed across the write; for a `Behavior` it is
  solved for. This is why no `becomes` keyword was needed — transition semantics are the
  default, and a keyword restating the default is not worth reserving.
- **No queue binding or retry policy** → `emit` names the queue. Retry policy stays in
  `system.events.Queue` deliberately: it is an operational property of the destination that
  changes over time, and tuning it should not require redeclaring a table. Same separation as
  enforcement modes.

It also splits producer from consumer, which the placeholder conflated: `on … emit` is the
producing table's declaration, `handler` is the queue's.

Three keywords added: `on`, `emit`, `handler`. Queue tables carry `LogData` — a queue item is
an occurrence, and two identical enqueues are two distinct work items.

**`repair … into <queue>` is settled with it.** `into` names an ordinary queue table, the same
binding `emit` makes. The two keep different spellings because the statements have different
shapes: `emit` takes a payload literal, while a repair's payload is fixed — it is the
violating row.

**Not answered here**: behavior-triggered conditions require the scheduler to *solve* for a
crossing moment rather than observe a transition, which is new machinery. See OQ-034. Event
functors over stored fields are implementable as specified; over behaviors they are not yet.

### Completing the Event Model

The above answered the trigger and the queue binding. Working through the remaining event
kinds — timer ingest, webhook arrival, on-demand external lookup, open-form behaviors, and
internal triggers — settled the rest without a new statement at top level. `every`, the effect
ladder, inbound-is-not-an-event, `next`, and `Component` defaults are recorded under OQ-005.
What belongs here is the queue and handler structure:

- **`Queue` is a trait extending `LogData`**, and `handler` is valid only on a `Queue` — it was
  previously valid on any `LogData` table, and a log is not a work list. The trait carries
  `scheduled_at`; the rest is four structural rules checked at commit, because two of them are
  about field *types* and the grammar cannot say "a foreign key to any table carrying trait X":
  exactly one `handler`, exactly one `:>` to a `QueueState` table, at most one field of type
  `Priority`, and append-only everywhere else. Rules 2 and 3 read the **type**, never the name —
  the same structural reading that decides an assert's variety from its body.
- **The `QueueState` field is the one exemption from append-only in the whole system**, and it
  is narrow: one field, on a `Queue`, written only by that queue's handler. It is what makes a
  request/response event expressible with no second mechanism — a client polls the row and reads
  a domain-meaningful state (`Bound`, `Applied`) while the scheduler reads that state's
  `disposition : Pending | InFlight | Done | Failed`. `QueueState` extends `Reference`, so
  adding a state is a schema commit and `state is Bound` is compile-checked.
- **Priority is per item, defaulted per field, and recognized by type.** `type Priority : Int`
  with `nice` semantics (lower is more urgent), aged toward urgency by the scheduler so a
  background item behind a saturated urgent queue does not starve. Per-*queue* priority was
  rejected: an on-demand single-user LDAP lookup and a nightly full refresh share a handler, a
  payload shape, and a destination and differ only in urgency, and per-queue priority would
  force that into two tables — duplicating the schema and splitting the rows an operator wants
  in one list.
- **Handlers are the one place arbitrary Haskell is admissible, and they are compiled in.** A
  handler runs outside the commit, so it needs none of the three properties the GADT DSL exists
  to provide: it is not inspected by the optimizer, not part of static access analysis, and
  never replayed. Registration is two rows on the split that already exists everywhere else —
  `system.events.Handler : Reference` for existence (code, so `handler foo.bar` is
  compile-checked against the compiled-in registry) and `system.events.HandlerConfig :
  Configuration` for tuning (hot). Adding a handler needs a build and a schema-daemon restart,
  which is acceptable because handlers arrive at the rate of new **integrations** (SMTP, HTTP
  POST, LDAP bind, S3 put), not new business rules — those are functors and need no restart.
  Retuning one is a `Configuration` write.
- **Retries are occurrences, so they are rows.** One `Attempt` table is generated per queue
  table, sharded with the rows it describes. `attempt_count` is a count over it and the next
  `scheduled_at` is derived from backoff over it, so a flapping destination is visible per item
  instead of collapsed into an integer. This is the queue rule ("anything needing a record after
  the fact goes in its own `LogData` table referencing the queue row") applied to the scheduler's
  own bookkeeping.
- **Two system tables were removed rather than fixed.** `system.events.Item` carried `payload :
  Bytes`, which duplicated the queue row — the payload existed twice, could diverge, and "the
  queue is inspectable with standard DataCode tools" is false of a blob. Its other fields
  decomposed: `scheduled_at` to the trait, `status` was a second authority for what the
  `QueueState` field holds, and `attempt_count`/`last_error` became the attempt history.
  `system.events.Queue` went to the `Reference`-tables rule under OQ-005. What remains is
  `QueuePolicy`, `BackoffState`, and `SchedulerLimit`, all `Configuration`.
- **`repair` is deferred because of *when*, not *where* — nothing to do with shards.** `repair`
  is `monitor` plus an enqueue, and `monitor` means the write was *accepted*, so by the time a
  violation exists the commit is over and there is no in-commit moment left. The retroactive
  case settles it independently: adding a predicate to a populated table can enqueue millions of
  repairs, which is not one transaction. **The in-commit way to fix a value is a type
  transform**, steps 1 and 4 of the order of operations — a value that should be rounded to
  cents belongs in `Amount`'s transform, not in a validation with a repair queue behind it, so
  `events.md`'s illustration was changed to a postal code, something only fixable by consulting
  something outside the row. A `ValidationRef` may now name an `assert`, which is what makes
  "an unsatisfiable path constraint hands the row to a functor that inserts the missing row"
  need no new syntax.

### OQ-031: Record Literals and Operator Spelling ✓ ANSWERED
**Answer**: Both resolved in favour of Haskell spelling.

**(a) Record literals use `=`.** Row construction and row update take `field = value`, as in Haskell record syntax. This removes the construction/update split that previously had construction on `:` and update on `=`:

```
app.commerce.Order { customer = customerId, total = 99.99 }   -- construction
Order where id == "uuid-..." { status = Shipped }             -- update
order { total = order.total * (1 - discount) }                -- update in a function body
```

Every brace-delimited key-value form follows: connector config (`add connector … { host = "…" }`) and UI hints (`ui { template = "card" }`) construct rows in system tables, so they take `=` too. `:` is left free to mean only "is a kind of".

Consequence for parsing: a brace block in query position is a projection when its items are bare paths and a row update when they are `field = value` bindings — one token of lookahead past the identifier.

**(b) Operator spelling follows Haskell.**

| Was | Now |
|---|---|
| `!=` | `/=` |
| `and` | `&&` |
| `or` | `\|\|` |

`and` and `or` are no longer reserved words. They were never Haskell operators — they are list functions (`and :: [Bool] -> Bool`) — so the old spelling misled a Haskell reader. `not`, `True`, and `False` were already correct; the reserved-word list had `true`/`false` lowercase and has been fixed.

New lexing note: `|` and `||` share a prefix, and `|` is already heavily loaded (sum types, unions, outer-join guards). Maximal munch resolves it, but a missing space turns a type alternation into a boolean expression. See `schema/railroad.md`.

### OQ-032: Retention of Observational Violations ✓ ANSWERED
**Answer**: Retention is declared by **predicate**, not by age alone, using the ordered branch
form of `retain` (`schema/aggregates.md`). See `integrity.md`.

```
retain system.integrity.Violation
  where origin is Derived && state is Repaired
    for 90 day
    , drop
  otherwise
    forever
```

`Derived` violations are queries over the transaction graph and recomputable; once `Repaired`,
the repair is visible in the subject row's own history, so dropping a closed one loses nothing.
`Observed` (transient witness), `Forced` (operator judgement, not re-derivable), and anything
`Waived` (the waiver and its reason are the audit trail) all fall to `otherwise forever`.

**The constraint is met structurally rather than by policy.** "Prune the log shard" can no
longer destroy audit evidence because it is no longer an operation: log data is discarded only
as a consequence of a declared `retain` chain, and a `LogData` table with no chain is never
pruned. Silence means keep.

This also replaced the framing in the question. `LogData` was described as "prunable" in a way
that read as "pruned on a schedule"; it means *may be discarded if a policy says so*. None of
the three options considered was taken — the table is not split, nothing is promoted to
`Configuration`, and no per-row detail is summarized away — because a predicate branch
expresses the actual rule directly.

### OQ-033: Document Key Interning Cap
**Question**: What is the default key-cardinality cap for a `Doc indexed` field, and how is a
spill surfaced?

Interned document keys are schema objects replicated to every server, so unbounded key
cardinality from an external source is a cluster-wide problem, not a local one — a payload
using UUIDs as object keys would grow a `Reference` table on every node
(`schema/documents.md`). Above the cap, keys spill to a shard-local data table; the cap is
what makes that boundary safe.

**The policy half is answered** (OQ-036). Three moves at increasing cost, none of which rewrites
history:

- **Prevent.** `Doc indexed using <predicate>` sends keys failing a shape test straight to spill,
  however far below the cap the field is. This is the fix; a document keyed by identifiers is a
  map keyed by a value, and the rule is how the schema says so.
- **Demote.** `deprecate` on an interned key, or on a pattern, stops new writes from interning it
  while existing rows keep resolving. It does not reclaim tags — tags are assigned monotonically
  and never reused, and proving no row holds one is not decidable while unmerged branches exist —
  so the counter does not move back and nothing is rewritten. On a general `Extensible`
  `Reference` table, where there is no spill target, the same verb reads as a denylist.
- **Supersede.** Redeclaring the field mints a new key table at a new schema node. The cap resets,
  historical rows decode against the key table at their own node, and the old table becomes
  prunable once orphaned.

Crossing a fill threshold raises a violation naming the *shape* found (`94% match
/^[0-9a-f-]{8,}$/`), which is what makes a shape rule get written while it costs one declaration
rather than a supersession.

**Still open**: the number. Needs an empirical default, tunable per field and overridable per
connector in the same spirit as OQ-009's rendering thresholds. Validate against real webhook
payloads (Stripe, GitHub) and real application log context before fixing one.

### OQ-034: Behavior-Triggered Event Scheduling
**Question**: How does the scheduler handle an `on` condition whose subject is a `Behavior`?

A condition over stored fields is decided at commit and costs the scheduler nothing. A
condition over a behavior has no write to observe, so the scheduler must compute *when* the
condition will first hold and arrange to wake then (`events.md`). Three sub-questions, all
open:

**Solving.** The crossing moment must be derivable in closed form, which is what restricts
behaviors to an analyzable class (constant, linear, piecewise-linear, exponential decay are
the obvious candidates). The class, the solver per class, and the encoding of both in the
GADT DSL are unspecified. **This no longer compounds OQ-001, and the residue is sharper for
it.** The event kind is validated — `spikes/functor-dsl` encodes both trigger forms producing
an `EventRef`, so the `EventRef` production is no longer a hypothetical the solver would have
had to be built on top of. What is left is exactly the solver, plus the classifier it shares
with the `every` warning. The classifier **is implemented** in that spike, because the warning
needs it whether or not the solver exists, so the open work is narrower than it was: a solver
per analyzable class, against a classifier that already partitions conditions into closable
and not.

**Re-solving on write.** A behavior closes over stored fields, so writing the row changes the
function and moves the crossing. Every pending wake-up derived from a behavior on that row
must be recomputed at commit — and an item already enqueued may have been enqueued for a
crossing that no longer happens. Whether such an item is withdrawn, or dispatched with its
condition re-checked at fire time, is undecided.

**Missed crossings.** If a server is down across a crossing moment, the event can fire late or
be skipped. "The trial expired" wants to fire late; "the rate-limit window opened" may not.
The policy, and whether it belongs per queue or per trigger, is undecided.

**Constraint**: whatever is chosen must not reintroduce polling, since eliminating the
hand-rolled `scheduled_at ≤ now` timer is most of the point of solving for crossings at all.

**`every` unblocks the use case without answering the question.** An open-form behavior is now
expressible by sampling it — `every 30 second emit … where balance >= credit_limit` (OQ-005) —
at the cost of a `system.events.TriggerState` row per (trigger, row) and a bounded lateness of
one interval. That makes behaviors *usable* before this OQ is settled, and it deliberately does
not resolve it: sampling is exactly the polling solving exists to eliminate. Two consequences
for the work here. The solver's job is now framed as **shrinking the set of conditions for which
`every` is the only option**, which gives the "analyzable class" question a measurable target.
And schema commit must decide, per condition, whether the solver *could* have closed it — the
warning that fires when `every` is used unnecessarily needs the same classifier the solver
needs, so the classifier is required even for conditions the solver declines to handle.

**Aggregate encoding belongs here too.** A retention chain (`schema/aggregates.md`) needs the
same kind of machinery from the other direction: an aggregate admissible in a multi-step chain
must declare an associative merge with an identity, and that merge has to be encodable in the
GADT DSL alongside the crossing solver. Open with it:

- How a merge is declared and checked. `count`/`sum`/`min`/`max` are obvious; the rule is
  written as "must declare a merge" specifically so a mergeable sketch type (t-digest for
  percentiles, HyperLogLog for distinct counts) can be added later without changing it. What
  that type looks like is unspecified.
- `avg` is rewritten to `(sum, count)` and divided on read. Whether that rewrite is a general
  mechanism (an aggregate declaring a different stored form from its read form) or a
  one-off is undecided; a general mechanism is what a sketch type would need.
- Whether the closed-form solver for behavior crossings and the fold for aggregates share a
  representation. Both are "compute something in closed form over a restricted function
  class", and building them twice would be a mistake worth avoiding deliberately rather than
  by accident.

**Blocks**: `on` conditions over behaviors; mergeable sketch types, and therefore `percentile`
in a chain of more than one step. Conditions over stored fields and chains built from
`count`/`sum`/`min`/`max`/`avg` are unaffected and implementable as specified.

### OQ-035: Extent Size, Segment Period, and Shard-Group Formation
**Question**: What are the default extent size and `LogData` segment grain, and is a
`UserData` shard group formed automatically or by an operator?

The mechanism is settled (OQ-007, `transaction-graph.md`, `storage.md`); the numbers are not.

- **Extent size**, and whether the threshold is expressed in bytes, rows, or extent count. Too
  small and `log_index` grows for no benefit; too large and repartitioning moves more than it
  needs to. Wants measurement against real write volume, like OQ-033.
- **Segment grain**, defaulting to `Day`. It must align with the retention grains in use — a raw
  step of `for 6 hour` under a `Day` segment cannot prune by segment — and a low-volume server
  must not accumulate near-empty segments. Now typed `Grain` rather than `Duration`, so the
  alignment requirement is a check over declared alignment edges rather than arithmetic, and a
  segment may seal on a calendar boundary (`Month`) whose buckets have unequal length.
- **Sequence counter storage.** `next <UniqueName>` (OQ-005) allocates one counter per
  (constraint, prefix value), sharded by the prefix. Where the coordination lands is now fully
  settled: with the prefix row for a prefixed sequence, and **in the constraint's own shard**
  for a table-wide one — the same shard that holds that constraint's value index, rooted at its
  schema-node row (`distribution.md`). What remains open is only the layout: whether the counter
  is a row in a generated table, a reserved field, or an LMDB-side value outside the log, and how
  it interacts with a split that moves the prefix row.
- **Shard-group formation.** Sealing a log segment is automatic and splitting a `UserData`
  shard is operator-initiated. A shard group sits between them: it adds sub-shards under one
  existing primary without redistributing roots or moving authority. Whether that makes it
  automatic like the first or proposed like the second is undecided. The *representation* is
  settled and needed no new concept — a shard group is sibling leaves under a range-tree node
  with no override, which is what sharing a primary already means (`distribution.md`).

**Notes**: all three are `Configuration` rows with a per-server override, so a wrong default is
tunable rather than fatal. Validate against real log volumes before fixing numbers.

### OQ-006: Failure Detection and Primary Elevation
**Question**: How does the cluster detect a failed primary and who initiates elevation of a secondary?
**Options**: Heartbeat with timeout, lease-based (primary must renew a lease), or external witness node.
**Constraint**: Must not split-brain — two secondaries must not both believe they are primary.
This constraint now also governs the shard **range tree**: ranges must be non-overlapping and
strictly nested, because overlapping ranges with a priority tie-break would let two rows claim
one shard, which is split-brain arriving by configuration rather than by failure
(`distribution.md`).

**Lock-holder recovery is no longer a failure mode here.** OQ-027's cross-server lock is
withdrawn, so there is no distributed lock to be orphaned by a mid-transaction primary death.
What remains is narrower and simpler: a coordinator that dies between appending a prepared node
and appending the commit or abort node leaves a prepared node with no resolution. Since a
prepared node is invisible to validation and excludes nothing, an unresolved one blocks no
work — the recovery obligation is to eventually append an abort, not to unwind a lock, and an
elevated secondary can do it from the graph alone because the prepared node records the
operation and the pinned point. Bounding how long an unresolved prepared node may persist
before an elevated primary aborts it is the remaining question, and it is a garbage-collection
question rather than a correctness one.

### OQ-007: Shard Split Trigger ✓ ANSWERED
**Answer**: Both, split by what the operation costs. Three thresholds, three behaviours:

| Trigger | Action | Authority |
|---|---|---|
| An extent fills | Allocate the next; repartition in the background | Automatic and invisible — rewrites a `log_index` offset only, so no locator changes, no graph node, nothing replicates |
| A `LogData` segment's grain bucket closes or its segment exceeds the size threshold | Seal the segment, start a new one | Automatic — sealing moves no data |
| A `UserData` shard exceeds the size threshold | Report; wait for `split shard … at key` | Operator — a split redistributes roots and moves write authority |

The line is mechanical rather than a matter of taste: an operation that moves no data and
writes no graph node can be automatic; one that moves authority cannot. It rests on
`PhysicalLocator` carrying `plShard` but not the byte offset — see `transaction-graph.md` and
`distribution.md`.

Thresholds and the segment grain are `Configuration` rows (`system.shards.ExtentPolicy`,
`system.shards.ExtentOverride`), not syntax and not trait parameters. Their default values are
OQ-035.

Three topology decisions settled alongside it, all in `distribution.md`:

- **Role assignment is a coarsening of the partition function, not a merger with it.** Two maps
  exist over one key space: the partition function (placement key → shard; exact, total,
  refined by a split, recorded as a graph node) and a **range tree** (key range → role triple;
  coarse, `Configuration`, edited by elevation). Every range boundary is a partition boundary, so
  a range covers a whole number of shards and a shard's roles resolve through exactly one range.
  Unifying them into a single tree with triples on interior nodes was considered and rejected:
  role assignment changes for reasons unrelated to key space, so every `elevate` would edit the
  structure deciding where rows are stored. The coarsening also *removes* the stale-routing
  window rather than detecting it — a split needs no assignment write, because the children
  resolve through the unchanged covering range. Ranges nest strictly and may not overlap
  (overlap plus a priority tie-break is split-brain by configuration, OQ-006), resolution is
  most-specific-wins as with `ExtentPolicy`/`ExtentOverride` and namespace inheritance (OQ-024),
  and ranges rather than per-shard rows are *required* because the table must be `Configuration`
  and a per-shard one would be `Configuration` at `UserData` cardinality.
- **Schema shards are rooted at a branch.** One shard per branch, keyed by branch name — which
  makes OQ-026's "all branches must be named" load-bearing rather than policy, since a root
  table's key *is* the shard directory. Branches get independent primaries, so schema work on two
  branches does not contend and a merge serializes at the target branch's primary. `Reference`
  rows live on the branch (inserting one is a schema transaction); `Configuration` rows do not,
  because operator tuning must survive a merge — the existing trait/configuration line. This
  makes the local-branch workflow work: an administrator clones the schema graph to the branch
  point plus its reference rows, works offline, and uploads, with no user data present. Two
  consequences are structural rather than incidental — a new constraint cannot be validated
  locally, so conformance is established per shard *at merge* via the bulk-mutation path, and a
  local branch has no secondaries and so is not durable until uploaded. It is inert with respect
  to the cluster for the same reason a prepared transaction node is: validation reads merged
  nodes only.
- **A table-wide `unique` gets its own shard, rooted at the constraint's schema-node row.**
  Not the schema shard: that index holds every value of the column cluster-wide, cannot split,
  and would make one primary the serialization point for writes to every table declaring such a
  constraint — so schema-shard unavailability would stop all writes rather than only DDL. As its
  own shard it splits by value range and its primary moves by ordinary elevation. Constraints
  touched together should share a primary, so the default grouping is one constraint shard per
  **namespace subtree** (namespaces are already the grouping axis with inheritance, OQ-024),
  overridable by a `Configuration` row. **Colocation is an optimization, not a correctness
  requirement** — a transaction spanning two groups is an ordinary multi-participant
  prepared-node transaction that costs a hop and breaks nothing — so schema commit warns where
  the touched set is static and stays silent where it cannot know; a hard rule would be
  unenforceable for interactive transactions. The value index spans branches while the
  *declaration* is branch-versioned, which means an unmerged branch's table-wide `unique` has a
  partial index, backfilled at merge and `enforce forward` until then.

### OQ-008: Client Token Provisioning
**Question**: Which identifiers must each platform supply at device registration?
**Settled**: Client tokens are issued to a **device**, through a registration process, and the
required identifiers are **per-platform configuration in `system.auth.*` rather than a fixed
schema** — a desktop install, a mobile app, and a headless agent agree on nothing, so a fixed
set would be wrong for at least two of them. Registration yields a token scoped to a namespace
subtree (`issue client token for … scoped to …`), rotatable without disturbing the user tokens
presented alongside it. See `auth.md`.
**Still open**: the identifier set per platform, and what constitutes sufficient device
identity on each.

### OQ-009: Weighted Cardinality Algorithm
**Question**: What is the exact function `f(element_count, element_size)` that determines relationship rendering level?
**Notes**: Thresholds and weights should be tunable per application and overridable per field. The initial defaults need empirical validation.
**Action**: Design algorithm; validate with real schema examples before first UI implementation.

### OQ-010: PageRank Parameters for Schema Linearization
**Question**: What are the damping factor, convergence criteria, and edge weighting rules for schema PageRank?
**Notes**: Edge types (foreign key, path constraint) may warrant different weights. Should be tunable.
**Second consumer**: schema PageRank also breaks ties in `UserData` extent clustering — which dependent tables sit next to the root when they cannot all fit (`storage.md`). That imposes a requirement the IDE alone did not: the computation must be **deterministic**, because two servers computing it independently must reach the same layout. Convergence criteria expressed as "close enough" are therefore unacceptable without a fixed iteration count and a canonical tie-break.

## Can Defer to Post-MVP

### OQ-011: FIDO2/WebAuthn for Long-Lived Credentials ✓ ANSWERED
**Answer**: **Yes, but not in the first pass.** What the first pass owes it is a model flexible
enough to take it later without disturbing anything, and that is settled:

- **`system.auth.User` is authentication-method agnostic.** A user row is an identity; the
  proof of that identity is a `system.auth.Credential` row keyed `{ user, method }`. One user
  may hold several credentials at once, and a new method is a new `CredentialMethod` row —
  a `Reference` table, so adding one is a schema commit — rather than a change to `User` or to
  the rows already in it. Adding WebAuthn later touches no existing row.
- **Multi-factor is a prerequisite edge, not a flag.** `CredentialMethod.requires` names a
  method that must also be satisfied, which puts "administrators need a second factor" in the
  method and in one presence assert rather than in login code.
- **A delivered one-time code is an occurrence, not a credential**, so it is a `Challenge` row
  in its own `LogData` table: `Hashed` code, `on state is Issued emit` for the send, expiry as
  a `Behavior`, `retain` chain for cleanup. Nothing new was needed, and it means a second
  factor is available in the first pass. Separating enduring capability from occurrence is the
  `User`/`Credential` split paying for itself twice.
- **Not every method fits `Hashed`** — an authenticator app's shared secret must be recoverable.
  That is `Encrypted`, answered in OQ-037, so authenticator apps and outbound connector
  credentials are no longer blocked. Reach for the delivered code first regardless: it needs no
  key custody.

Implementation remains post-MVP. See `auth.md`.

### OQ-012: Analytical Query Distribution Protocol
**Question**: How exactly are distributed materialized view computations coordinated between neighboring servers?
**Notes**: The BitTorrent-style propagation model handles transaction replication; the analytical distribution model is a separate protocol.

**Settled — global reads need no deferral mechanism.** A query is pegged to a
`(commit node, sample moment)` pair and never blocks a writer, so a global read cannot be in
anyone's way transactionally. What it *can* do is starve local work of I/O, which is a resource
budget rather than a scheduling problem, and the placement answer already exists: dedicated
tertiary servers. This splits the original "delay global work behind local work" question in
half and leaves only global *mutations* needing the queue (see OQ-027 and `distribution.md`).
**Still open**: whether the I/O budget is expressed per connection, per token, or per query.

**Settled — push and pull are both kept, and answer different questions.** Push (the commit
fan-out, already mandatory for the two secondaries) carries liveness; announce-and-fetch over
the swarm carries catch-up. A client that was offline and a tertiary that lagged both want
"deltas since sequence N", so resumption is one protocol. Server-to-server pushes carry the
payload; **client pushes carry an invalidation only** — pushing payloads would force the commit
path to evaluate every subscriber's access asserts per row, putting an access decision on the
write path, which exists nowhere else in the design. Latency was not the deciding factor and
cannot be: a parked long-poll, an SSE stream, and an HTTP/2 push are the same thing on the wire.
A `Behavior` cannot be pushed at all — nothing is written, so there is no commit to notify on,
and a client watching one is asking the scheduler for a crossing (OQ-034). **Still open**: how
many parked subscriptions a node holds, and the eviction policy at that ceiling.

### OQ-013: Yesod Evaluation ✓ ANSWERED
**Answer**: Yesod not needed for the data plane. Defer to thin-client HTML layer, which is post-MVP.
- The Servant + Warp spike (OQ-002) confirmed that Servant's type-safe routing, combined with a WAI IORef dispatch table, covers all DataCode data plane needs at 1µs/request overhead.
- Yesod would add session management and HTML templating that are irrelevant to a JSON/binary API server.
- Revisit Yesod only if the thin-client HTML layer warrants it — after the data plane is shipping.

### OQ-014: D3.js Integration
**Question**: How does the HTML rendering engine decide when to use D3.js visualizations vs. plain HTML?
**Notes**: Likely a theme-level decision (some themes include D3 components). Needs more design once base HTML rendering is working.

### OQ-015: Service Accounts ✓ ANSWERED
**Answer**: **Yes as a concept, no as a token type.** Machine callers hold ordinary
`system.auth.User` rows, so every request still carries a user token and there is no second
identity model. What distinguishes a service account is a linking row and a **view** over it:

```
system.auth.ServiceAccount = User >< AccountKind { User.*, AccountKind.purpose }
  where kind is Service
```

The view is a filter over `User`, not a subtype — it narrows to the rows reachable through a
linking table and may project that table's columns or not. Because the join is along a `:>`
edge and the derived key is meaningful, it is **writable**: inserting through it creates the
`User` row and the `AccountKind` row, with `kind = Service` supplied by the view's own filter.
That is the point of the pattern rather than a bonus — the call site never names the linking
table.

A trait was rejected. A trait is a declaration on a table, so `User : ServiceAccount` would
make every user one; the thing being described is a set of rows, which is a view's job.

The motivating case is third-party ingestion: a connector authenticates as a service account
whose credentials are `ApiKey`-method rows, and everything it writes is attributable to an
identity living in the same tables and obeying the same asserts as a human's. See `auth.md`.

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

### OQ-019: Connector Daemon Architecture ✓ ANSWERED
**Answer**: There is no connector daemon, in either sense. Polling is a scheduled event under
the one scheduler, and the outbound work runs in `Effect` — which makes it a handler, and
handlers are the **separate handler worker pool** (OQ-001). So the answer to "separate process
or pool inside the server" is *separate process*, but not because connectors are special: they
land there by being effectful, alongside SMTP and S3 and every other integration.

Three properties come free rather than being designed for. A connector cannot crash the data
plane, which was the original concern. Its reachable hosts, credentials, and timeouts come from
a `Configuration` row and are enforceable at the OS level, because the pool is a distinct
process. And a new connector integration ships as a generation swap on the handler pool alone,
never touching the data workers.

**Narrowed to worker-pool topology.** There is **one scheduler**, and connector polling is a
scheduled event under it rather than an independent loop: a connector's CDC sync and its state
verification are two `every` declarations on the connector row, with the intervals as ordinary
`Configuration` fields (`connectors.md`). Two schedulers would have meant two retry policies,
two backoff states, and no way to reason about total outbound load — the thing to avoid before
writing code rather than after. What remains open is only whether the connector *workers* are a
separate supervised process or a pool inside the server, which is the original question minus
the scheduling half — and is now answered above by the handler pool. The inbound direction is not scheduled at all (OQ-005, arrival is a write),
so a connector's failure surface is a handler's failure surface and is bounded by
`HandlerConfig`.

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

### OQ-024: Namespace Access Control Inheritance ✓ ANSWERED
**Answer**: **Grants recurse to children.** A grant on a namespace reaches that namespace and
every descendant namespace, table, view, and functor within it. See
[namespaces.md](namespaces.md#namespace-access-control).

The model is default-deny with recursive grants, which is not the same as the "implicit
inheritance vs. explicit grants" tradeoff the question posed. Nothing is granted by tree
membership: there is no root grant, and a grant confers nothing on siblings or ancestors. What
recurses is an *explicit* grant, downward over the subtree it names. Requiring a grant per
level would have made the namespace tree decorative for authorization purposes — the reason to
put a table under `app.commerce` is that it belongs with the rest of `app.commerce`, and that
is exactly the statement a grant wants to make.

Narrowing stays available and is the marked case: additional functors restrict at the table or
row level beneath an inherited grant. Recursion sets the ceiling; functors lower it.

**Amended: a grant may declare `bypass access`.** "Functors lower it" left no way to express an
administrator, whose authority is precisely not to be lowered, and the alternatives were both
bad — `|| authed_user.role is Admin` in every rule spreads one decision across every table and
cannot be audited, and rebinding the token to all users silently changes a term's arity.
`grant <role> on <namespace> bypass access` skips every assert mentioning `authed_user`, on
read and on write, and skips nothing else: an administrator is exempt from access control,
never from data integrity. The exemption is exact because the set of access constraints is
read off the assert bodies rather than off their names (OQ-005). Two properties follow from
putting it in the grant: bypass is one queryable place, and it is subtree-scoped like every
other grant, so an administrator of `app.pm` is an ordinary user everywhere else. See
`namespaces.md`.

### OQ-025: Connector Schema Change Propagation
**Question**: When an external schema changes (new column added to MariaDB table), how does DataCode notify users whose application schema (`app.*`) references that connector table?
**Notes**: The shadow schema is updated automatically. But if `app.commerce.Order` is a view over the connector table and a new field appears in the connector, does it automatically appear in the view, or must the user explicitly add it?
**Action**: Design the schema change notification and propagation rules; likely a configurable policy per view.
