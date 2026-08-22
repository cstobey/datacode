# Open Questions and Deferred Decisions

Questions that need answers before or during implementation. Grouped by urgency.

## Must Resolve Before Writing Core Code

### OQ-001: Dynamic Loading Mechanism ✓ ANSWERED
**Answer**: GADT DSL + Data.Dynamic hybrid. See `spikes/dynamic-loading/output.txt`.
- **GADT DSL** (Approach 2): primary functor mechanism. All four functor kinds must be encodable: validation, foreign key, path constraint (in both its data and access varieties), and event (the event functor enqueues a work item rather than executing immediately — see `events.md`). Spike validated the first three; the event functor requires a DSL extension that produces an `EventRef` (queue table row insert) instead of `Either Error a`. Zero runtime GHC dependency. ~0µs apply latency. Ceiling: regex and recursive types require DSL extensions; user-defined functions require new DSL constructors. **Two of these have since become load-bearing rather than anticipated** (OQ-005): the path-constraint kind widened past equality to anchored presence/absence subqueries, which the spike did not encode, and `=~` became a real operator admissible in any constraint body, so the regex primitive is now required rather than merely possible. See `dynamic-loading.md`.
- **Data.Dynamic** (Approach 3): type registry substrate. TypeRep-based type checking is O(1). Serves as the "registered type library" that the DSL references by name.
- **hint** (Approach 1): failed to compile in the spike — GHC not on PATH or hint version mismatch. Revisit as an escape hatch for advanced user-defined functors; compile async and sandbox the result.
- **Multi-daemon**: needed when compiled-in types must change (requires server restart to load new Haskell modules); the schema daemon restarts are coordinated by a supervisor.

**Requirements accumulated for the architecture revisit.** OQ-005 and OQ-030 settled the event
and function-column syntax, and doing so put four loads on this answer that it was not written
against. Recorded here so the revisit starts from them rather than rediscovering them:

- **The DSL's "user-defined functions" ceiling is now split in two, and only one half still
  binds.** Handlers escape it on their merits — they run in `Effect`, outside the commit, and
  need none of transparency, static access analysis, or replayability — so they are compiled-in
  Haskell registered in `system.events.Handler`, and the ceiling costs a build and a
  schema-daemon restart per new *integration*. Functors do not escape it: they are `Read` or
  `Tx`, they are DSL terms, and a new business rule must need no restart. **This is what makes
  the multi-daemon layer load-bearing rather than contingent** — the restart path is now on the
  documented route for adding an integration, so its latency is a real number the revisit owes
  rather than a "not run" spike. Option E (the `hint` escape hatch) stays deferred, and the
  handler split is the reason it can: the case that wanted arbitrary Haskell got it somewhere
  the DSL does not have to reach.
- **The DSL must encode two things it was not sized for.** The **event functor** was already
  unvalidated; it now has two trigger forms, and `every` needs an interval that is a `Read`
  expression evaluated per row per tick, not a constant. Separately, **function-typed columns**
  mean a DSL term is now a stored *value* whose signature the type checker knows — which is
  mostly a typing change over the existing `FunctorRef`, but it makes the acyclicity check over
  the function call graph a schema-commit obligation and puts template holes (anchored queries
  with a non-emptiness-shaped result count) in the same encoding as assert bodies.
- **The effect ladder replaces the signature blacklist**, so "no arbitrary IO" is enforced by
  the absence of an `Effect a -> Tx a` lift rather than by rejecting `a -> IO b`. The revisit
  should confirm the GADT DSL can be *indexed by effect* — a validation term and a template hole
  are both `Read`, a field default is `Tx`, and nothing in the DSL is `Effect` at all, since
  effectful code lives outside it.
- **One scheduler, not two.** Connector polling is a scheduled event (OQ-019), so the process
  topology question is scheduler + worker pools + schema daemon + data daemons, not that plus a
  connector daemon with its own timing. This is a simplification, but it means the scheduler is
  on the critical path for ingest as well as egress and its failure domain is correspondingly
  larger.

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
- **Compaction is lossless.** It relocates bytes so they are stored more optimally as the schema evolves and never discards a row version. Superseded versions *are* the version chain, which is the graph's account of how a row reached its value; collapsing them to reclaim disk would be rewriting history for space. Pruning is the only operation that loses anything, it loses granularity deliberately, and it happens only as the consequence of a declared `retain` chain (OQ-032). Relocation, compaction, and pruning share the maintenance queue and only the last may lose data — see `storage.md`. The consequence leaned on elsewhere: anything derivable from a row's version chain stays derivable for as long as the row exists.
- **Per-field `created_at`/`updated_at` are derived, cached by configuration, and proposed by usage.** `Table.field.updated_at` is a backward walk of the version chain comparing one column; `Table.field.created_at` is the first non-`Null`-derived value, which is the well-defined reading for a field added by evolution. Never stored on the row — that would multiply row width by field count to hold what the log already contains. Which fields keep a cache is a `system.telemetry.FieldTimeCache` row (`Configuration`, because the set tracks load and a schema commit per tuning change is the wrong grain), and because compaction is lossless the cache qualifies as a materialized view rather than a rollup table. Uncached references are logged to `system.telemetry.FieldTimeRequest` (`LogData`, with a `retain` chain rolling to counts) and the maintenance queue raises a *proposal* — a query must never silently create the view, since that writes state nobody authored in a system built on named branches and no anonymous forks. Declaring up front stays the primary path: usage-driven discovery cannot cover a cold start, where the first query pays the full walk per row. See `transaction-graph.md`.

### OQ-026: API Version Token Format ✓ ANSWERED
**Answer**: Three interchangeable version token types, all valid as the `{version}` segment in `/v{version}/...` API paths:

- **Graph node hash prefix** (canonical default): content-addressed, always deterministic. The underlying identity of every schema node. Guaranteed unambiguous across servers, shard splits, and merges.
- **Tag**: a fixed-point alias for a specific graph node. Tags do not move after creation. Techs attach tags to commits as part of a transaction; tags are the expected primary UX for human-readable version pinning (e.g. `v2.1.0`, `stable-2026-q2`).
- **Branch name**: a moving alias that always resolves to the current HEAD of a named branch (e.g. `main`, `experiment-checkout`). Advances automatically as new commits land on that branch.

All three resolve to the same thing at dispatch time: token → schema graph node hash → routes registered at that node. The hash prefix is the lowest-level escape hatch that works even when no tag or branch name has been declared.

**No-version behavior**: Requests without a version token are routed to the `main` branch HEAD by default. The server can also route unversioned requests across A/B test branches at a configurable rate; routing decisions persist via session affinity so the same client consistently receives the same branch across requests.

**Promoting a version going forward**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch is currently designated. The `/versions` discovery endpoint lists all live tokens and marks the promoted one. Together these allow operators to tell existing clients "use this tag from now on" without requiring client code changes.

**Policy**: All branches must be named — anonymous DAG forks are not permitted. The `main` branch cannot be deleted. See the Branch and Tag lifecycle documentation in `transaction-graph.md`.

### OQ-027: API Functor Type and Transaction Semantics ✓ ANSWERED

- **Typing**: No separate API functor type. Field types are referenced directly from the schema everywhere they are used — the schema IS the type system. Auto-generated routes are fully typed by the table definition.
- **Transaction semantics**: Reads and writes share the same transaction graph snapshot. The primary server linearizes and executes transactions one at a time. Cross-shard transactions require all shard primaries to agree: a cross-server lock is taken on a `transaction_id` across the involved shards and held until all operations complete. Consequence: the system should group related shards on the same server, and should prefer placing the primary close to the users making requests.
- **Error signaling**: The transaction is atomic — it either fully commits or fully fails. On failure, only the HTTP request log is written (to a per-server system shard that always succeeds independently). The error is returned to the client. 500s should be avoided; all known failure modes return 4xx.
- **Event functors**: Internal events (e.g., index updates, view refresh) resolve within the transaction as they occur. External side effects (email, webhooks, etc.) are never executed inline — they are written to a queue table and processed asynchronously by the event scheduler functor. No external calls from within a transaction.

### OQ-028: Route Conflict Resolution ✓ ANSWERED

- **Custom routes shadow auto-generated at the same path.** The most useful behavior — registering a custom route at `/records/app.commerce.Order/{id}` clearly intends to override the generated handler.
- **Reserved `raw/` prefix**: `/v{N}/raw/<table-path>` is always auto-generated; custom routes starting with `raw/` are rejected at insert time. This guarantees the auto-generated handler is always reachable.
- **Path validation**: custom routes under `/records/` must reference an existing table/view; phantom overrides are rejected at insert time.
- **Version semantics**: custom routes are schema objects in the transaction graph — no routing-mode flag on branches or tags needed. A version token resolves to a schema node, and the routes at that node (generated + any custom overrides) follow naturally.
- **Version ref uniqueness**: branches and tags share `system.VersionRef` with a `VersionRef` ADT (`Branch DataId | Tag DataId`). The `Tag` variant's immutability is enforced by a validation functor. No discriminator column — the type encodes the rule.

### OQ-029: Route Trie vs. Dispatch Table Implementation ✓ ANSWERED
**Answer**: Hand-rolled route trie. See `spikes/route-trie/output.txt`.
- **Route trie confirmed**: 0.2µs/request at 10k registered routes — well under the 1µs target. O(depth × log fanout), independent of total route count.
- **Linear scan ruled out**: 1µs at 100 routes, 13µs at 1k routes, 132µs at 10k routes. Scales O(n) — fails the target beyond a handful of custom routes.
- **wai-routes ruled out**: uses Template Haskell compile-time route tables — incompatible with DataCode's runtime-registered custom routes.
- **path-piece ruled out**: a type class for parsing individual path segments, not a router.
- **Precedence**: static segments always beat captures at the same depth — correct, deterministic, matches every mainstream router.
- **Integration**: replace `IORef (Map String Application)` in the Servant `Raw` handler with `IORef (RouteTrie Application)`. Schema changes rebuild the trie and atomically swap the IORef — zero request interruption.
- **Conflict resolution** (answers OQ-028 partially): exact-path conflicts are a schema validation error at insert time. The trie's `nodeHandler` slot can only hold one handler; inserting a duplicate pattern is rejected.

### OQ-036: Erasure, PII Scrubbing, and Shard Quarantine
**Question**: By what mechanism does data leave DataCode permanently, and what does the system
look like afterwards?

Every existing removal path is deliberately incapable of this. `delete` appends a tombstone and
the row stays readable at earlier moments. `prune` removes schema objects and orphaned
branches. `retain`/`drop` discards `LogData` only, never manually. Relocation preserves
everything by construction. "No subsequent operation can remove it" is stated as a *hazard* in
`integrity.md` about a plaintext credential reaching the log — which is the admission that the
capability is missing rather than merely unbuilt.

It is needed for three concrete cases: a subject-erasure request, a credential or key that
reached the log, and PII an unvetted connector ingested. **This is placed before core code
rather than during it** because one of the candidate mechanisms decides the on-disk log format,
and retrofitting it is a rewrite.

**Unit.** Shards are row-rooted, so "erase this customer" is already a natural unit — the shard
that customer's row roots. Whether erasure is offered at field, row, or shard granularity, and
whether the narrower ones are anything more than a shard-level operation with extra steps, is
undecided. Field-level is the case a connector-ingested column wants; shard-level is the case a
subject-erasure request wants.

**Mechanism.** Two candidates, and they are not close in cost:

- **Overwrite in place.** Zero the payload bytes in the log extent and rewrite the affected
  `log_index` entries. Simple, but it is the one operation that mutates a written extent, and
  every argument for the append-only log is an argument against admitting it.
- **Crypto-shredding.** Encrypt each shard under its own key and destroy the key. The log stays
  byte-immutable and erasure becomes a deletion in a key table, which is a thing the system
  already knows how to do and to replicate. The cost is that it puts a cipher between mmap and
  the Cap'n Proto message, and the zero-copy read path (`storage.md`) is a load-bearing claim
  that would have to be re-argued or scoped to encrypted-shards-only.

Crypto-shredding aligns suspiciously well with row-rooted shards — one key per shard root *is*
one key per customer — which is the argument for taking it seriously despite the read-path
cost.

**Quarantine is the weaker sibling and may be the more common one.** Marking a shard
unreadable and unreplicated pending review destroys nothing and is reversible, which is what an
operator actually wants in the first hour of an incident. Whether it is a distinct mechanism or
the mandatory first step of erasure is undecided; it is also cheap enough that it might be
answerable ahead of the rest.

**Open sub-questions beyond mechanism:**

- **What a read returns afterwards.** It wants a `Null`-derived type, but `Redacted` is already
  taken by access-control denial (OQ-005) and means "you may not see this", not "this no longer
  exists". `Erased` is the obvious spelling.
- **Replication.** An erasure must propagate and must not be optional — a tertiary that missed
  it still holds the data. A prune node is already a recorded graph node, so there is a shape
  to copy, but prune is advisory in a way this cannot be.
- **Derived state.** Materialized views, `Doc indexed` shredded trees, LMDB indexes, and
  `system.integrity.Violation.observed` all hold copies. Rollup levels are the hard case: the
  source is pruned by the time the rollup exists, so the rollup is the only record and may
  itself carry the PII.
- **Exports and backups.** `export shard … to` (`cli.md`) writes bytes outside the system
  entirely, and no in-system mechanism reaches them. Whether that is in scope or is documented
  as an operator obligation needs deciding, not ignoring.
- **Authorization and audit.** Erasure is the one act that destroys evidence, so the record
  *that* it happened, who ordered it, and under what authority has to survive it — analogous to
  a `Waived` violation carrying its reason.

**Constraint**: whatever is chosen must not become a general edit primitive. It is the single
exception to "nothing is destroyed", it must be recorded as a graph node the way a prune node
is, and it must be impossible to reach from the query language — which is why `delete!` was
withdrawn rather than given these semantics (OQ-005, `schema/queries.md`).

### OQ-037: Reversible Secret Storage
**Question**: What type constructor stores a secret the server must be able to read back, and
where does its key live?

`Secret` is a type property; `Hashed a` is the one constructor carrying it, and it is one-way
by construction. That covers every credential verified by re-deriving — a password, an API
key, a WebAuthn public key. It does not cover a credential the server must *reproduce from*: an
authenticator app's shared secret (RFC 6238) has to be recovered to compute the current code,
and a connector's outbound credential has to be recovered to authenticate with. Neither is
expressible, so **a method needing a recoverable secret cannot currently be declared**
(`auth.md`).

**Scope narrowed.** This does *not* block having a second factor. A **delivered** one-time code
is an occurrence rather than an enduring capability, so it is a `Challenge` row in its own
`LogData` table rather than a `Credential`: generated per attempt, stored `Hashed`, verified
with `matches`, sent by an `on state is Issued emit` event, expiring by `Behavior`, and pruned
by a `retain` chain. It needs nothing that does not exist. What remains blocked is narrower
than "multi-factor" — it is authenticator apps and outbound connector credentials
specifically.

The shape is presumably `Encrypted a using <policy>`, mirroring `Hashed a using
system.crypto.HashPolicy.…`, and it would inherit `Secret`'s four effects unchanged except for
reads. What is undecided is everything underneath:

- **Where the key lives.** Not in the same shard as the ciphertext, or the pair travels
  together in every backup and every replication stream. An external KMS is the conventional
  answer and is the first external dependency in a system that has none.
- **Whether reads are a functor at all.** Decryption on read is a per-row operation on the
  read path, which is the path `storage.md`'s zero-copy claim is about — the same collision
  crypto-shredding runs into in OQ-036, and the two should probably be answered together.
- **What a read returns to a token that may not decrypt.** `Sealed` means "one-way"; this is
  not that.
- **Rotation.** Re-encrypting under a new policy is a rewrite of every affected row, which the
  append-only log makes an append of new versions — bounded, but not free, and it interacts
  with `enforce forward` the way password policy rotation already does.

Blocks TOTP specifically (OQ-011); does not block the `User`/`Credential` split, which is
settled.

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
- **References**: `:>` declares a foreign key (`customer :> Customer`). `:` requires a type on the right, `:>` requires a table or view; using the wrong one is a compile-time error. Replaces the earlier two-token `: -> Customer`.
- **Head rule**: in an alternation only the first variant decides the token, so `customer :> Customer | MissingCustomer` and `phone : Phone | NotGiven` both typecheck against a single `Null` root — no separate reference-absence hierarchy.
- **Clause order**: `field ( ":" | ":>" ) Type [rename from / from] [unique] [= default] [where pred]`. The default precedes `where` so an `=` inside a predicate is never ambiguous.
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
- **Schema evolution**: redeclare table body; system diffs; `rename from` hint; same-name hides old type; `deprecate`/`prune` for removal
- **Scope**: top-level = global (stored in schema); `let` = local inside function bodies; REPL = transaction model (`:commit`/`:rollback`)
- **Equality**: `=` is binding only (field default, function definition, sum-type declaration, `let`, row construction and update), `==` is comparison, `is` is constructor match ignoring payload. Follows Haskell. Resolves the earlier doubling where `=` also meant exact value equality.
- **Operator spelling** follows Haskell: `==`, `/=`, `&&`, `||`, `not`, `True`, `False`. No `!=`, `and`, or `or` (OQ-031).
- **Candidate keys are mandatory** on every table not carrying `LogData`, `Component`, or `Keyless`; `DataId` does not satisfy the rule, since counting the surrogate would make it vacuous. Default-on with a `Keyless` waiver rather than opt-in, matching enforcement modes where the strict setting is the default and weakening it is an explicit recorded act — and the opposite polarity from `Extensible`, because extensibility is a capability you choose while keylessness is a defect you admit. The exemption is not "logs are special": *occurrences have no identity beyond their occurrence, entities do*, which is why queue tables carry `LogData` too. Replaces the previous state where `unique` existed but nothing required it, leaving "default ordering: unique key ascending" undefined on keyless tables.
- **A key on a shard-local table must be rooted** — its FK chain must reach the shard root, transitively is fine, and FKs to `Reference`/`Configuration` do not participate. Consequence: **the key declaration is also the sharding declaration.** A `UserData` table whose key contains no same-family FK *is* a shard root; one whose key does is a dependent. No separate keyword, and it cannot drift, because adding an FK changes nothing unless it is put in the key. Where a key reaches two roots, the first FK decides — the same head rule that governs `:>`. The root table's own key is cluster-wide, but that index is the shard directory the router already needs, so it costs nothing; every other key is checked within one shard. Requires shards to be **row-rooted** (each `Customer` row roots a shard), which `shardOf :: DataId 'Row -> Maybe (DataId 'Shard)` and `split shard … at key` already implied but no document stated. See `transaction-graph.md`.
- **Continuous time**: `Behavior a ≅ Moment -> a` as a field type, for values that change with no write — accruing interest, countdowns, decaying limits. Nothing is stored; the value is computed from the row at the moment of observation. Exactly one parameter, always `Moment`, because two behaviors compose pointwise only over a shared domain and the scheduler can solve a crossing only over a domain it knows. `Moment` is distinct from `Timestamp` (stored, in a row) and is deliberately not called `CurrentTime`, since historical queries sample the past and the scheduler samples the future. `unique`, `indexed`, `order by`, and `where` are all rejected on a behavior, and behaviors are read-only. Reuse is via traits, not via a behavior-carrying type, because a behavior closes over sibling fields and only a trait can require them. A behavior is **not** a fifth functor kind — the four kinds each enforce something and a behavior is a projection.
- **Units are validation, not algebra.** `Duration`'s canonical unit is the millisecond; conversions are stdlib functions (`days`, `hours`, …) written at the use site, so `rate * days (t - opened_at)` says what `rate` means without a dimensional type system. Domain types narrow value sets; arithmetic operates on the underlying primitive. Dimensional typing was rejected as too large an addition for the benefit, and because it collides with functor transparency and the GADT DSL's ceiling (OQ-001).
- **Retention and rollups**: `aggregate <Name> = <query>` declares what to compute; `retain <Table> as <Name>` declares a chain of resolutions and how long each is kept. A chain never reshapes, which is why the aggregate is named once on the header — a differing step is unrepresentable rather than rejected. Terminals are `forever` (keep) and `drop` (discard); `never` was rejected because in a construct full of durations it reads as "never delete". Ordered `where`/`otherwise` branches partition a table, first match wins, as in a Haskell guard — one block rather than N statements, because order is load-bearing and separate statements have no reliable order. Chain aggregates must declare an associative merge with an identity (`count`/`sum`/`min`/`max` do; `avg` is silently rewritten to `(sum, count)`; `percentile` cannot and is rejected past one step) — phrased as a rule about merges rather than a whitelist so sketch types drop in later. `bucket_start` is injected into every generated level and `grain` is a virtual column, so `RequestRollup where grain == hour` selects a level with no new query syntax; the aggregate's plain name is the union view over all levels, making transparent querying the default and reaching into one level the marked case. **Pruning `LogData` is only ever a consequence of a chain** — there is no manual prune, and a table with no chain is never pruned, which is what closes OQ-032 structurally. A rollup is two appends (aggregate rows, then a prune node), never a rewrite of the transaction being summarized. Rollup levels are consequently real tables, not materialized views: a materialized view is recomputable from its source by definition, and here the source is gone.
- **View keys are derived, never declared.** A `unique` declaration in a view body is rejected. Every view has a key — a table is a set of tuples, so at worst the whole tuple is one — which makes *existence* the wrong question and **meaningful** (a proper subset identifying an entity) versus **degenerate** (all attributes) the right one. Propagation: `where` preserves; projection preserves iff every key column survives, else degenerates; `group` yields the group columns exactly, and exactly rather than approximately because DataCode's `group` nests instead of aggregating away; a `:>` join yields the referencing side's key alone and is lossless, with FK fields substituting to the referent's key so the key survives the FK column being projected away; a non-key join yields the union; a union of relations needs a discriminator that may not exist; an outer join degenerates when a key column comes from the outer side, for the same reason a declared key may not contain a `Null`-derived variant. Degeneracy is a **warning, not an error** — reporting views legitimately have no entity identity — but never silent, because a view claiming an identity it lacks would be trusted by merge reconciliation. Two things depend on the answer: a meaningful key admits **incremental refresh** (upsert by key) where a degenerate one admits only full recomputation; and an incrementally-maintainable view is a **candidate to replace its sources** — the general form of a retention chain superseding its raw table — while a degenerate one pins them, so `deprecate` on a source with a degraded dependent view is rejected until the view is altered or deprecated.
- **A view is a named query**: `view Name : Traits = <query>`, binding with `=` exactly as `aggregate` does. The table-style view body is **withdrawn**. It could not express a join at all — there was no production for one — which made "the users reachable through this linking table" unwritable, and that was the whole requirement. Three things went with it: the standalone `where` body item (and the rule that position told a row filter from a field validation), `WildcardField` (`* from <table>`), and `FieldDecl`'s bare `from <table>` clause. `rename from` stays; it is an evolution hint and never concerned views. A view's asserts are consequently standalone-only. Projections gained two forms to compensate: an `Expr` (requiring `as`, since a computed column has no name to inherit) and a qualified `*` (`User.*`) to take one side of a join, with a later item overriding an earlier `*` on the same name.
- **A view's field types are inherited or computed, never declared.** A projected `FieldPath` keeps the source field's type and its validations; a projected expression **mints a computed type named by the view field's path**, which is not a new naming rule but the existing one (a field's `where` is already addressed by its path, and that path already names its computed type) reaching a new position. Types are shared **structurally** and named by their first definer — two views projecting the same function over the same source type get one type, since functor transparency makes that decidable — so the name outlives its definer's `deprecate`. A function over a key column **degenerates the key**, because injectivity is not knowable in general, which costs incremental refresh, pins the sources, and makes the view read-only.
- **Views are writable, and the derived key is what decides it** — a third consumer of the meaningful/degenerate distinction, alongside incremental refresh and `deprecate` blocking. An insert decomposes into one mutation per base table ordered by FK direction, admissible exactly when the key is meaningful, every join is along a `:>` edge (so the join is lossless and each view row is at most one row per base), and every undefaulted field of each base is projected or fixed by the view's `where`. **The view's `where` is a check constraint on write whose constant equalities supply values on insert** — SQL's `WITH CHECK OPTION` doing one extra job, and the mechanism that lets adding a row through `system.auth.ServiceAccount` create the linking row without the call site naming it. `delete` removes the row the key identifies and never cascades: for a `:>` join that is the referencing side, so deleting a service account leaves the `User`. Stated explicitly because it reads as though the user should go too.
- **Capitalization** follows Haskell: types, traits, tables, views, and sum-type variants are `UpperCamelCase` and singular (a table is a type — `table T : Trait` uses the same `:` that `type A : B` does, and a row is an `Order`, not an `Orders`); fields are `lower_snake_case`; functions, predicates, and constraint names are `lowerCamelCase`; namespace segments are `lowercase`. The field/function split is deliberate — a field names stored data and reads as a column, a function is code and reads as Haskell. Capitalization is style checked by the linter, not grammar: `Ident` admits either case everywhere and position decides what a name is.
- **Placement is separate from identity and needs only a total order.** A candidate key answers *which row is this*; placement answers *where does it go*. `DataId` is excluded from satisfying the candidate-key rule — counting the surrogate would make it vacuous — but it is monotone, total, and present on every row, so it is always a valid *placement* key. Consequence: **every shard can be split**, and a declared partition space only chooses where the cut falls. `LogData` therefore gets the root it was missing: a `system.shards.LogSegment` row keyed `{ origin_server, period_start, branch }`, with all three components derivable or decidable at write time — `origin_server` from bytes 6–7 of the row's own `DataId` (the virtual column, declared nowhere), period from bytes 0–5, branch from the `retain` predicate, which may reference only group fields and the time source. Routing costs zero stored bytes, the log table itself stays keyless, the segment root carries the key instead, and retention aligns to segments so pruning becomes an unlink. A third layer is named to keep this safe: an **extent** is storage, a **shard** is authority, and `PhysicalLocator` already draws the line by carrying `plShard` but *not* the byte offset — so moving a row within its shard rewrites one `log_index` value and is invisible to the graph, while moving it across shards is a recorded split. Splitting a shard with one root row is thus possible but yields a **shard group** sharing a primary, because non-root uniqueness, `assert` evaluation, and `Ordinal` assignment are all defined as within-one-shard. **No syntax was added**: a `shard by <grain>` clause on `retain` was considered and rejected, since the segment key supplies the same alignment for free.
- **Operational tuning is a row, not a trait.** A trait declares what a table *is*; a `Configuration` row declares how a deployment *treats* it. Extent size and segment period track hardware and must differ between staging and production without branching the schema, so they are rows in `system.shards.ExtentPolicy` keyed by table path, with `system.shards.ExtentOverride` keyed `{ table, server }` for per-server exceptions, resolved most-specific-first — two tables rather than one, because a `Null`-derived "all servers" variant in a key is rejected. Traits consequently take **no parameters**; where a declaration must name a policy the spelling is a reference to a policy row, as `Hashed Text using system.crypto.HashPolicy.password_v2` already does. Same separation as enforcement modes, queue retry policy, and retention.
- **`system` is a namespace, not a replication class.** It had been listed as a fifth shard type in `transaction-graph.md` and as a table type in `namespaces.md`; both are corrected. Tables in `system` carry ordinary replication traits — `system.integrity.Violation` is `LogData`, `system.shards.Node` is `Configuration`. Namespace says whose a table is and who may see it; trait says how it propagates.
- **There is one `delete`.** The `delete!` "hard delete" spelling is **withdrawn**. Its documented distinction from `delete` was not one — both left the record in the transaction graph and removed the row from the current state, which is the definition of a delete, so `delete!` was redundant syntax carrying a sigil that promised something it did not do. `delete` is an ordinary mutation: it appends a tombstone version, the row is absent at sample moments at or after it and present at any earlier `at`, the `DataId` is never reused, and writing a new version restores it. The operation `delete!` would have had to mean — destroying bytes already in the append-only log — is real and needed, but it is an administrative act on a shard rather than a row mutation, so it is not reachable from the query language at all. See OQ-036.
- **The virtual columns are projections of the row identifier**, which makes `created_at` an instance of a rule rather than a special case: bytes 0–5 are `created_at`, bytes 6–7 are `origin_server`, and a component's id suffix is `ordinal`. Two are added. **`origin_server`** is typed `:> system.shards.Node` rather than `Int` — as a bare 2-byte integer every "which server wrote this" query is a manual join against a magic number meaningless outside the registry that defines it. It is the only virtual column that is a reference and the only one resolving through a candidate key rather than a `DataId`, since the projected bytes *are* `Node`'s key; `Node` is `Configuration` so the join is local everywhere, and its rows become permanently non-prunable, which costs nothing at one row per server and is what keeps a retired server's historical rows readable (an `| RetiredServer` alternation was rejected — it puts an absence case in every query for no gain). `system.shards.LogSegment` had been hand-rolling this projection as a declared `server` field; that field is **removed** and its key now names `origin_server` directly, which required settling that virtual columns are eligible in a key — all of them but `updated_at`, which is excluded for the same reason a `Behavior` is: not because it is virtual, but because it moves. `period_start` stays declared, and the asymmetry is the point — `period` is a `Configuration` value that may be retuned while routing is never revised, so a truncation under a mutable policy must be pinned at write time; bytes 6–7 cannot be retuned and so need no pinning. **`ordinal`** closes a real gap rather than adding sugar: without it there is no way to *state* document order in a query, only to receive it from a range scan, which cannot be restated after a join or reversed. It is the position at the row's own level, not the full path — nesting makes a path variable-length, the rendered identifier already spells it, and a column whose type varied with nesting depth would be worse than what it duplicates. **The sequence counter (bytes 8–11) stays unexposed**: it disambiguates within one server-millisecond and is a tiebreak rather than an ordering — two servers' values are incomparable, and the clock-regression clamp deliberately continues it across a held timestamp — while `DataId` order already gives the total order anyone reaching for it wants. `updated_at` remains the odd one out, reading the head locator rather than the identifier. See `transaction-graph.md`.
- **Effects are a ladder, and one missing lift carries the whole "no external calls in a commit" rule.** `Pure ⊂ Read ⊂ Tx`, with `Effect` outside that chain and connected by exactly one arrow: `commit :: Tx a -> Effect a` exists, and nothing takes an `Effect a` to a `Tx a`. This **replaces the `a -> IO b` signature rejection**, which was weaker — a signature check does not close `traverse` over an effectful function inside a validation, or one hidden behind a type alias, and an unconstructible type does. `IO` no longer appears in any DataCode signature at all. The arrow that *does* exist is what makes handlers workable: a handler runs in `Effect` and calls `commit` freely, so advancing a queue row's state or writing 50 000 ingested rows in batches is an ordinary transaction subject to every validation and assert. It also fixes retry granularity by placement — everything before the first `commit` is redone on retry, everything after is not. `Effect`'s capabilities come from the handler's `Configuration` row, never from code, so a handler cannot reach an ungranted host and never holds a credential in a compiled constant. See `schema/functions.md`.
- **`every <Expr> emit <queue> { … } where <cond>` is the second event trigger form**, and its interval is an **expression**, not a literal — a `DurationLit`, a field of the row, or a `Configuration` path are one production. That is what retired the interval-override mechanism that was briefly proposed: you do not need an override when you can point the expression at wherever tuning should live. It fires per row of the table it is declared on, so fan-out is what "declared on a table" already means rather than a feature of `every`. **False-to-true still holds** — sampling observes the transition between ticks instead of across a write — which costs a `system.events.TriggerState` bit per (trigger, row) and is why schema commit **warns** when the solver could have closed the condition instead. There is deliberately **no top-level cron form**: a timer job always has rows that parameterize it (which feed, which directory, which account), so that table is the producing table and the payload stays typed against a row it can name. `schedule` and `cron` were considered and not reserved.
- **Inbound arrival is not an event.** A webhook, a connector row, and an operator API call are *writes*: a route whose functor inserts into a landing table, after which the ordinary insert case of `on … emit` covers whatever happens next. Modelling arrival as a trigger form would have provided neither of the two properties the event system exists to provide — there is no side effect to defer and no external call to keep out of the commit, because the row *is* the durable record. This makes OQ-020 purely a route concern.
- **`next <UniqueName>` allocates a sequence, and the scope of a sequence is the scope of the uniqueness it serves.** `next` allocates within the named `unique` constraint's field list minus the field being defaulted, so `unique orderRef { customer, order_num }` gives a per-`customer` counter living with the customer row — a local read-modify-write in a transaction that already touches that shard, with no central coordination — while `unique invoiceNum { invoice_num }` has an empty prefix and reaches the table's master shard, exactly like a table-wide `unique`. Both cases fall out of one rule and **the shard cost is readable off the declaration**, because it is the prefix-reaches-the-root question the candidate key already asks; a table-wide `next` warns at commit, a prefixed one warns about nothing. Gaps are guaranteed (an aborted transaction burns a value) and gapless numbering is a *reporting* requirement served by a view over the log, not by the allocator. `next` is an allocation rather than a value, so it is admissible only in a `DefaultClause` on a field the named `unique` includes. `sequence` and `serial` were considered and not reserved — a modifier would restate a scope that is already declared.
- **A `Component` default constructs the row**, in the same transaction, and the sub-table body is what makes it a construction rather than a reference (`settings :> Settings : Component = { theme = Dark }` versus `created_by :> User = authed_user`). This is what closes the "default table" requirement with no trigger machinery: a row that must exist whenever its parent exists is a total function of the parent, `Component` already owns lifetime, and `=` already takes a row construction. No shard question arises, since a component lives in its parent's row-rooted shard by definition. **Deleting a parent deletes its components**, mechanically over `Component` edges — no cascade declaration and no depth limit, because the edges *are* the ownership. A cross-table in-commit trigger to a non-`Component` table is **refused**: if a row must exist atomically and has independent identity, that is a modelling error, and admitting the general case would put arbitrary user mutation in the commit path with unbounded cascade depth and a cost unreadable from the schema.
- **A function-typed column is a `FunctorRef` with a static signature.** Storage changes nothing — `FunctorRef` is already a column type and already points at a serialized DSL term — and what is new is that the compiler knows the signature. A function type is declared `type Renderer = Amount -> Read Html`; **a field names a declared function type and may not write an arrow inline**, which makes "every function in a field shares one signature" a property of what a field *is*. Values are a named function or a lambda literal, both already grammatical (`Behavior`'s mandatory `=` lambda is the precedent), so **no syntax was added**. Template-Haskell-style `[| … |]` was rejected: its whole appeal is promising arbitrary Haskell inside, which the GADT DSL cannot deliver, and a syntax selling a permanent lie about the ceiling is worse than none. Literals are admissible only on `Reference` tables — because inserting a `Reference` row *is* a schema transaction, so "it still has to compile" is structural — while `Configuration` admits a `FunctorRef` and no literal: **code by schema, selection-among-code by data.** Restrictions all follow from function types having no equality: rejected in `unique`, `order by`, `group by`, `==`, `indexed`, a candidate key, and a field `where`; queries in the body must be rooted at `self` like an assert's; the call graph must be acyclic (decidable, since it is in the schema graph); and an `Effect` function type is name-only, because effectful code is compiled-in and a data write may select a handler but never author one.
- **A template is text with holes, and cardinality is the control flow.** One production — `Hole ::= '{{' Query ( 'using' QName )? '}}'` — where the query's result count supplies every construct a template language usually spells: zero rows render nothing (the conditional, and it is just the query's `where`), one row renders once (plain interpolation, since `self` is a query of one row), N rows render N times joined by the template's separator (the loop). `each`, `if`, and `else` were consequently **not reserved**. `using` names the template applied per row; omitted, the active theme's render function for the row's type applies, which makes the template system and the theme system **one mechanism** rather than two. The separator is a field on the template's `Reference` row, not part of the hole. The one gap — a negative branch — needs no syntax: outer-join a `Null`-derived catch-all and the render function for the absence variant handles it, so **absence renders because absence is a type**. Formatting is an ordinary function call, so there are no filters or pipes; escaping follows the output type, so emitting unescaped markup requires an `Html` value and injection safety is a typing property with no raw-output form. Holes are `Read` and rooted at `self`, for the same read-cost reason asserts are anchored. Cost stated plainly: **a page whose layout is not derivable from the schema walk cannot be expressed as a template**, and fixing that would turn one production into a language.
- **A `Reference` table is needed exactly where a fact originates outside the schema graph.** Self-hosting means system *state* is queryable, not that declarations get mirrored into rows — the schema graph is already queryable, so restating a declaration as a `Reference` row gives two authorities for one fact. `system.events.Handler` qualifies, because it is the bridge that makes `handler system.connectors.ldap.sync` compile-check against Haskell the schema graph cannot see. `system.events.Queue` did not, and was removed on this rule.
- **Guiding principle**: where a choice is otherwise balanced, pick the spelling a Haskell reader would expect. DataCode's operators may carry narrower meanings than Haskell's — `where` constrains rather than binds — but the shape should be familiar.
- **Open**: migration functor syntax (`evolution.md`); pagination config; UI template hints (`schema/traits.md`); package import scope (`schema/functions.md`)

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
    for 90 days
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

**Needs**: an empirical default, and a policy for what happens as a field approaches it.
Spilling silently makes the field quietly slower and larger; refusing to spill makes ingest
fail, which is exactly the outcome `monitor` mode exists to avoid.

**Notes**: should be tunable per field and overridable per connector, in the same spirit as
OQ-009's rendering thresholds. Validate against real webhook payloads (Stripe, GitHub) and
real application log context before fixing a number.

### OQ-034: Behavior-Triggered Event Scheduling
**Question**: How does the scheduler handle an `on` condition whose subject is a `Behavior`?

A condition over stored fields is decided at commit and costs the scheduler nothing. A
condition over a behavior has no write to observe, so the scheduler must compute *when* the
condition will first hold and arrange to wake then (`events.md`). Three sub-questions, all
open:

**Solving.** The crossing moment must be derivable in closed form, which is what restricts
behaviors to an analyzable class (constant, linear, piecewise-linear, exponential decay are
the obvious candidates). The class, the solver per class, and the encoding of both in the
GADT DSL are unspecified. Note this compounds OQ-001: the event functor is the one kind the
dynamic-loading spike never validated, and a crossing solver is strictly harder than the
`EventRef` production that spike would have tested.

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
expressible by sampling it — `every 30 seconds emit … where balance >= credit_limit` (OQ-005) —
at the cost of a `system.events.TriggerState` bit per (trigger, row) and a bounded lateness of
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
**Question**: What are the default extent size and `LogData` segment period, and is a
`UserData` shard group formed automatically or by an operator?

The mechanism is settled (OQ-007, `transaction-graph.md`, `storage.md`); the numbers are not.

- **Extent size**, and whether the threshold is expressed in bytes, rows, or extent count. Too
  small and `log_index` grows for no benefit; too large and repartitioning moves more than it
  needs to. Wants measurement against real write volume, like OQ-033.
- **Segment period**, defaulting to day. It must divide sensibly into the retention grains in
  use — a raw step of `for 6 hours` under a daily period cannot prune by segment — and a
  low-volume server must not accumulate near-empty segments.
- **Sequence counter storage.** `next <UniqueName>` (OQ-005) allocates one counter per
  (constraint, prefix value), sharded by the prefix. The rule is settled and so is where the
  coordination lands — with the prefix row for a prefixed sequence, on the table's master shard
  for a table-wide one. The layout is not: whether the counter is a row in a generated table, a
  reserved field on the prefix row, or an LMDB-side value outside the log, and how it interacts
  with a shard split that moves the prefix row.
- **Shard-group formation.** Sealing a log segment is automatic and splitting a `UserData`
  shard is operator-initiated. A shard group sits between them: it adds sub-shards under one
  existing primary without redistributing roots or moving authority. Whether that makes it
  automatic like the first or proposed like the second is undecided.

**Notes**: all three are `Configuration` rows with a per-server override, so a wrong default is
tunable rather than fatal. Validate against real log volumes before fixing numbers.

### OQ-006: Failure Detection and Primary Elevation
**Question**: How does the cluster detect a failed primary and who initiates elevation of a secondary?
**Options**: Heartbeat with timeout, lease-based (primary must renew a lease), or external witness node.
**Constraint**: Must not split-brain — two secondaries must not both believe they are primary.
**Additional failure mode (from OQ-027)**: Cross-shard transactions take a distributed lock across all involved shard primaries and hold it until all operations complete. If any participating primary dies mid-lock, the recovery protocol must detect the partial lock and either complete or roll back the transaction. This is effectively a two-phase commit recovery problem — the failure detection mechanism chosen here must also handle lock-holder crash recovery, not just primary elevation for normal reads and writes.

### OQ-007: Shard Split Trigger ✓ ANSWERED
**Answer**: Both, split by what the operation costs. Three thresholds, three behaviours:

| Trigger | Action | Authority |
|---|---|---|
| An extent fills | Allocate the next; repartition in the background | Automatic and invisible — rewrites a `log_index` offset only, so no locator changes, no graph node, nothing replicates |
| A `LogData` period closes or its segment exceeds the size threshold | Seal the segment, start a new one | Automatic — sealing moves no data |
| A `UserData` shard exceeds the size threshold | Report; wait for `split shard … at key` | Operator — a split redistributes roots and moves write authority |

The line is mechanical rather than a matter of taste: an operation that moves no data and
writes no graph node can be automatic; one that moves authority cannot. It rests on
`PhysicalLocator` carrying `plShard` but not the byte offset — see `transaction-graph.md` and
`distribution.md`.

Thresholds and the segment period are `Configuration` rows (`system.shards.ExtentPolicy`,
`system.shards.ExtentOverride`), not syntax and not trait parameters. Their default values are
OQ-035.

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
  That is OQ-037, and it blocks authenticator apps and outbound connector credentials
  specifically, not multi-factor and not the split above.

Implementation remains post-MVP. See `auth.md`.

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

### OQ-015: Service Accounts ✓ ANSWERED
**Answer**: **Yes as a concept, no as a token type.** Machine callers hold ordinary
`system.auth.User` rows, so every request still carries a user token and there is no second
identity model. What distinguishes a service account is a linking row and a **view** over it:

```
view system.auth.ServiceAccount = User >< AccountKind { User.*, AccountKind.purpose }
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

### OQ-019: Connector Daemon Architecture
**Question**: Is the connector daemon a separate process (separate daemon alongside the schema and data daemons) or a thread pool within the main DataCode server process?
**Notes**: Separate process allows independent restart; same process is simpler. Connector failures should not crash the main server.
**Action**: Decide during core architecture design; likely a separate supervised process.

**Narrowed to worker-pool topology.** There is **one scheduler**, and connector polling is a
scheduled event under it rather than an independent loop: a connector's CDC sync and its state
verification are two `every` declarations on the connector row, with the intervals as ordinary
`Configuration` fields (`connectors.md`). Two schedulers would have meant two retry policies,
two backoff states, and no way to reason about total outbound load — the thing to avoid before
writing code rather than after. What remains open is only whether the connector *workers* are a
separate supervised process or a pool inside the server, which is the original question minus
the scheduling half. The inbound direction is not scheduled at all (OQ-005, arrival is a write),
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
