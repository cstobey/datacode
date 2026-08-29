# Questions

**Twenty-five answered.** All are recorded in `00-report.md` under **Decisions taken** and in
`50-validation.md` under **Status of section (E)**.

**Five remain.** The 187 per-item questions the designers and critics raised were triaged against
those decisions on 2026-08-28: 58 were made moot by a decision, 109 have a dominant answer and are
mine to write down, 13 hang off something already deferred, and 11 were genuinely yours — cut to five
below by dropping those where both answers lead to the same work.

All five are **facts about the deployment you are building toward**, not language design. That is the
shape the residue takes once the syntax is settled, and none of them blocks Phase 0.

---

# Decisions still needed — final list

## (A) Decisions still needed

Five survive. Six of the eleven THEIRS were demoted (four had a dominant answer on the design's own principles; two merge into one another).

### 1. When a shard's primary dies, does the cluster promote a secondary on its own, or wait for an operator?

*(D08 critic 1 — OQ-006 has never settled it)*

**Differs:** Automatic promotion requires all of D08 §4 — the two-of-three ACK, fencing epochs, the elevation protocol, split-brain recovery. Operator-initiated shrinks that to fencing plus rejoin, deletes the ACK question, and costs write availability on a shard until someone acts. It also decides the failback default (D08 Q6), which is parked on this answer.

**Recommendation:** Automatic elevation, operator-initiated failback. Elevation restores availability; failback only rebalances. Same asymmetry OQ-007 already uses to keep a `UserData` split manual because it moves write authority.

### 2. Roughly how many end-user accounts and registered devices will one cluster hold — thousands, or millions?

*(D07 critic 5)*

**Differs:** `system.auth.Credential` is `Configuration` (`auth.md:78`), and decision 3 put `Registration` and `ClientToken` there too. `Configuration` replicates every row to every server. Correct at thousands; wrong at millions, where all three want to be shard-local `UserData` rooted at `User` — which makes login a shard-directory lookup and a bulk credential import a shard-local operation rather than a cluster-wide event.

**Recommendation:** If millions, re-trait all three before any auth work lands. Re-traiting after is a rewrite; deciding now is three words in `traits.md`.

### 3. Can every MariaDB/MySQL source you replicate from run GTID *and* `binlog_row_image=FULL`?

*(D09 Q6 + D12 Q5 — merged; both recommendations already said "same phone call")*

**Differs:** Yes to both: the connector has one position model with no stored checkpoint, and a shadow table keys on the source's FK chain, so ingested data roots and shards like native data. No to GTID: `mysql_filepos` stays first-class and needs its own at-least-once checkpoint design — the machinery the GTID design was chosen to delete. No to FULL: an UPDATE's before-image carries only the primary key, so every shadow keys on the source PK alone and lands as an unrooted flat table, forfeiting the rooted-key shadow design entirely.

**Recommendation:** Require both. They are the standard CDC prerequisites, and the rooted-key shadow is the whole of what makes ingested data shardable. A source that cannot enable them gets a periodic snapshot, not a streaming connector.

### 4. What is the largest file you actually need to store, and does anything have to upload one in pieces?

*(D01 Q10)*

**Differs:** A few MiB of frontend assets and attachments means one synchronous write plus a size cap, and no ingest path to design. Hundreds of MiB means one upload head-of-line-blocks a tenant's entire write path through the linearized shard primary — so the answer is a batched durability class and a chunked/resumable upload path, not a bigger single-transaction ceiling. The cap number itself is a `Configuration` row and costs nothing; the streaming ingest path is the part that only exists if you say so.

**Recommendation:** If it is first-party CSS/JS/images and document attachments, cap around 16 MiB synchronous and build no resumable upload in v1.

### 5. Does pattern validation need to work on non-ASCII text — accented or non-Latin names and addresses?

*(D04 Q2 — smallest of the five)*

**Differs:** With regex-tdfa, `[[:alpha:]]` does not match `é`, so any class-based predicate silently rejects real names. Yes means regex-rure and a Rust dependency in the build. No means regex-tdfa with the ASCII limit documented beside every class-based predicate. The window is before the first production cluster, not before the docs — a later swap re-interprets patterns already stored in the schema graph.

**Recommendation:** Yes, and pay the engine switch now while it is free. Note the partial escape either way: named predicates are ordinary Haskell functions and `Data.Char.isAlpha` is already Unicode-aware, so only author-written regex classes are exposed.

*Catchall: anything else about the deployment you are actually building toward — cluster count, tenancy shape, hardware, or a workload I have not asked about — that would change any of the above?*

## (B) Answered by a decision

**32** questions were killed outright by the fifteen decisions taken on 2026-08-28. (A further 24 were duplicates or per-file catchalls of the single global catchall, and 2 were already settled in `docs/` — 58 moot in total.)

Most notable:

- **Seven of D16's thirteen** died to *"`:<` declares the child's FK and nothing on the parent"* plus *"a `:>` to a `Component` is table-valued"*. Withdrawing the reverse column removed the default-naming question, the `deprecate`-the-reverse-name question, the table-valued-reverse-path-in-an-assert question, and the `:describe … deep` feature they were all attached to.
- **D12 Q1 and Q7** died to *"`Reference` rows live on the branch shard; tags are allocated cluster-wide"*, which says so in terms: "this closes the cross-branch collision question that D12 wanted to raise as an OQ. Do not file it."
- **D08 Q3, Q4 and critic 4** died to *"pagination is a cursor, not an offset; no exact total"* and *"`limit` requires a total order"* — the exact-count flag, the csv/raw exemption, and the meaning of `limit` without `order by`.
- **D15 #5 and #12** died to *"every added column declares a default"*, which replaced all three contradictory statements about what an evolution-added field reads on old rows.

## (C) Mine to write down

**109.** Ones where the answer is non-obvious enough that you might push back when you see it:

- **`File` gets no content dedup** — one content row shared across owners breaks `erase` and collapses N access policies onto one row. Digest kept for integrity only. (D01 Q7)
- **Bulk insert gets no parent-deduplication** — the denormalized-grid case is dropped; adding it later changes nothing that already parses. (Scope 7, demoted from THEIRS)
- **`{ total = default }` gets built regardless of what you meant by `Default`** — nothing today can reset a field to its default, so the feature stands on its own merits. (Scope 9, demoted)
- **`unsafeHashed`, not `preHashed`** — "make it feel like Haskell" is the stated tie-breaker; close enough that your ear overrides me. (Naming 6, demoted)
- **The connector's `row_image` mirror ships behind a per-connector flag defaulting off** — the position and the audit mirror are two jobs, only one load-bearing. (D09 Q13, demoted)
- **Running totals and RANK are parked** — `numbered` ships either way; an ordered prefix-scan aggregate is separable new work. (D11 Q1, demoted)
- **`show queries` normalizes `query_text` with literals as placeholders** — full text lets a `bypass access on system` token read values out of `app.*` tables it holds no grant on.
- **The three-way client split is named `reach`, as a seeded `Reference` sub-table** — not `standing` (taken, `auth.md:88`) and not `tier`.
- **The connector does not generate a `retain` chain** for tables it creates — warning only, because *silence means keep*.
- **Update-all is spelled `Order where True { … }`** — an explicit `where True` on the one statement that rewrites every row.
- **A mutation returns a commit node and an affected-row count, not rows** — read the new versions back with a query pegged `at` that commit node.
- **`preHashed` and `reveal` move to the `BypassKind` axis**, not path grants, because `GrantCmd` is path-recursive by construction.
- **One new OQ number is spent**, on retiring a population of superseded stored representations (credentials and data keys together). Four designers each claimed "OQ-038"; it can only be spent once.

## (D) Attached to something deferred

**13**, hanging off seven things:

| Deferred thing | Count | Questions |
|---|---|---|
| Supplied-field mask | 4 | `updated_at` as "last changed" vs "last named"; the name `provenance`; `provenance` in an `on` condition; what a merge commit writes to the mask |
| Parameterised regex | 3 | argument character class and 64-char cap; row-path argument outside access asserts; per-tenant pattern-set cardinality |
| Merge reconciliation | 1 | a table-wide `unique` handed out on both sides of a partition (plus the mask question above) |
| Recursion / closure | 1 | `parent` as a virtual column on `Component` tables |
| `.dc` export format | 1 | must re-import replay scrub and erase nodes (also blocked on OQ-036) |
| `Ephemeral` trait | 1 | does `show queries` cover maintenance-queue and scheduled work |
| OQ-012 (distributed query protocol) | 1 | lease vs budget-exhaustion for a fragment whose coordinator died |

One more — the `auto_reclaim` / failback default (D08 Q6) — hangs off decision **A1** above rather than off a deferral, and follows from it directly.

---

## Raw, superseded

The 187 original questions, verbatim from the designers and their critics, kept for provenance. Every
one has been triaged; consult this only to check how a question was disposed of.

## Per-item

The remaining questions are scoped to one change each. They are reproduced verbatim from the
designers and their critics, so several are sharper about their own item than I would be. Questions
about `Component` arity, the `in`/`elem` spelling, the client-kind word, and whether assets belong
in the database are now settled and can be skipped.

### D01-large-files

- Is the target deployment single-binary and CDN-free? That is the one condition under which I would reverse the frontend-artifact recommendation, and it changes nothing else in the design — you use the same `Blob` and the same content addressing, you just accept the orphan-prune loop as the discard path.
- Should `Blob` be readable at all inside a `Read` functor, or is `Effect`-only correct? I have it as `Effect`-only on the transparency argument, but a bounded read of the first N bytes (magic-number validation, image dimensions) is a plausible thing to want and would need a `body.prefix n : Bytes` projection. Adding it later is cheap; deciding now is cheaper.
- Do you want the per-field ordinal-space question resolved in this pass, or as its own item? It is already ambiguous today for a table with two `Doc indexed` fields, so `Blob` exposes it rather than creating it — but it becomes load-bearing the moment a table has two `Blob` fields.
- Is per-shard-root dedup the right scope, or do you want a knob for cluster-wide? I have it fixed at per-root on placement and side-channel grounds. Making it configurable would need the content table's key to vary, which is not a `Configuration` row's job.
- Should `MediaType` ship as a `system.*` `Reference, Extensible` table, or is it the application's to declare? Shipping it means DataCode owns an IANA mirror; not shipping it means every schema re-declares one.
- Anything else you want folded in — a size target, an existing asset pipeline this has to interoperate with, or a case (streaming video, resumable upload, signed URLs) you have in mind that I have not covered?
- (critic) Do you want dedup at all in v1? Fatal objections 5 and 6 say the `unique { root, digest }` pattern breaks `erase` and collapses N access policies onto one row. Making dedup an opt-in the author writes per table (rather than the design's spine) keeps the storage win where it is safe — first-party build artifacts, one owner — and keeps it away from `Personal` uploads where it is a correctness and privacy bug.
- (critic) Is there a case for an `Immutable` marker trait? Fatal #3 shows `Content`'s insert-only property is assumed and unenforced, and `traits.md:304` puts the only append-only rule on `LogData`. `Immutable` composing like `Keyless` and `Personal` would make it structural, and it would also let `Content` state that `body` is never updated so the `unique` index can never disagree with the stored digest.
- (critic) Should the chunk table carry an explicit `seq : Int` rather than leaning on `ordinal`? I recommend yes (four bytes, correct O(1) offset arithmetic, immune to the per-parent ordinal question). Saying yes also settles whether the per-(parent, component-table) ordinal namespace question needs answering at all for this feature — it wouldn't.
- (critic) What is the real `max_blob_bytes` target, given head-of-line blocking? 64–256 MiB on a synchronously-replicated, linearized shard primary means one upload stalls a tenant's whole write path for a 128–512 MiB fan-out. If uploads must be large, the honest answer may be a `Batched` durability class plus a smaller ceiling, not a bigger one.
- (critic) Anything else you want folded in — a size target, a specific upload path (resumable, signed URL, streaming video), an existing asset pipeline this has to interoperate with, or a tenancy shape (single-user vs multi-user per shard root) that would change the dedup and access answers?

### D02-bounded-text

- Should the linter warn on a `Text` field with no length predicate? It is the only lever that serves 'most Text fields need caps' without inventing a default nobody chose, but it will be noisy on `system.*` and on connector shadow schemas, so it probably wants to be scoped to `app.*` authored tables. My recommendation is yes, `app.*` only, warning not error.
- Is `maxBytes` wanted now, or deferred until a byte-limited connector column actually turns up? Shipping it with `maxLen` is what stops someone reaching for `maxLen` when they mean bytes, but it is a third name for a rule you may never use.
- `isNotEmpty` (README.md:216, traits.md:59) and `minLen 1` are the same rule under two names, with two addresses. Keep both, with `isNotEmpty` as the readable spelling and a lint nudge from `minLen 1`? Or define `isNotEmpty` away? I lean keep — it reads better and it is already in three documents — but it is a second spelling and the project usually withdraws those.
- Confirm the `/ minLen12` → `/ minLen` correction across `integrity.md`, `cli.md`, `evolution.md`, and `railroad.md`. If you intended `minLen12` to be a *named top-level definition* (`minLen12 = minLen 12`, per README.md:301-302's advice about failure messages), then those files are consistent and README.md:300 needs the softening instead — but then `where minLen 12` at integrity.md:182 is the line that is wrong.
- A field-level `where maxLen 20` on an alternation such as `nickname : Nickname | NotGiven` — does the predicate apply vacuously at the `Null`-derived variants, or is a predicate on an alternation an error? I recommend vacuous-at-absence, since it is the only reading under which a nullable domain-typed field works at all, but I can find no document that settles it and bounded text makes the case common.
- Do you want an `isTrimmed` predicate shipped alongside, given that `maxLen` counting trailing whitespace will surprise anyone coming from a `CHAR` column with PAD SPACE semantics?
- Anything else about how you expect caps to be used in practice — particularly whether you expect them mostly inline on fields or mostly on named domain types, since that decides how hard the docs should push the naming idiom?
- (critic) Does a predicate inherited from a DOMAIN TYPE keep an origin address the way a trait-inherited one does (evolution.md:98-99, README.md:282-294)? `app.commerce.Email / maxLen` alongside `app.commerce.Customer.email / maxLen` would resolve the collision in fatal objection 1 and would also settle whether `email : Email where maxLen 300` can be diagnosed as a no-op tightening rather than silently ignored. Nothing in docs/ answers this today and it is a genuine OQ candidate, unlike the length cap itself.
- (critic) When a predicate's argument is tightened, should the mode already standing on that address be vacated? Answering 'yes' makes the proposal's address rule safe; answering 'no' means the argument belongs in the address after all. This is the question the four-file `minLen12` edit actually turns on.
- (critic) Should a `maxLen`/`minLen` violation on a scrubbed field be suppressed rather than recomputed? A scrub preserves byte length, not code-point count, so derivable revalidation can manufacture a violation with no commit. Suppressing on the scrub node (which already records checksum-before and checksum-after) looks cheapest, and matches integrity.md:275-276 reading `observed` as `Erased`.
- (critic) Anything else about how you expect caps to interact with the connector shadow schemas specifically — the proposal assumes a MariaDB `VARCHAR(n)` mapping, but no document in docs/ mentions VARCHAR, utf8mb4, or charset anywhere today, so that mapping is new design rather than a restatement.

### D03-client-token-types

- `system.auth.Grant` is referenced at namespaces.md:154 and cli.md:179 and has never been declared. Its shape is a design decision I did not want to take unilaterally: is a grant carried by a `Role` (as the CLI spelling implies) or may it also name a `User` directly, and do the two bypass kinds live as fields or as a linking table?
- Do you want the `Cli` and `Ide` clients to be `Operator` for *every* deployment, or should `standing` be revisable per deployment? I made it a `Reference` field, so changing it is a schema commit and identical everywhere — which is right if 'the CLI may issue admin commands' is a property of DataCode, and wrong if a deployment wants a read-only CLI. The `Reference`-versus-`Configuration` test (traits.md:146) says the former; I want confirmation.
- I recommend that non-reachability filters (the row is absent) while a failed `authed_user` assert redacts (the row is `Redacted`), on the grounds that a browser must not learn the cardinality of rows it can never be granted. That is a second read-failure semantics. Accept, or keep `Redacted` uniform and take the cardinality leak?
- Should a `Client` pin a schema version, so the storefront renders against v3 without the URL carrying it? The machinery exists (api.md's version tokens) and the field would be one line, but it makes reach and versioning interact and I left it out deliberately.
- Should `system.logs.HttpRequest` gain `client :> system.auth.Client`? It costs 2 bytes as a `Reference` tag, and without it no request log says which software made the call — but it is a change to the one table written on every request path.
- The N-clients x M-narrowed-tables binding count: do you want a naming convention for client-scope bindings (`app.commerce.storefront.Order`) before this gets used in anger, or is that premature?
- Anything else you want folded in — particularly if you have a view on whether `standing` is the right word for the three-way split, given it is already carrying `Primary | SecondFactor` on `CredentialMethod` in the same file.
- (critic) The proposal's rejection of `authed_client` is right, but its replacement reason is partly built on the projection/write-through equivalence that queries.md:548-551 forbids. Do you want the recorded reason narrowed to the parts that survive — reach is not an assert, an assert cannot supply a value on insert, and a client filter would classify as a data constraint and never run on read (constraints.md:41) — and the 'six additions' count dropped?
- (critic) Should client reach be pinned to the schema head or to the query's sample moment? Head is the only safe answer, and it is the one place 'nothing is destroyed' has to yield. Same question for token liveness under a caller-supplied `at`.
- (critic) If `Client` is `Reference`, a staging-only test client is a production schema commit. Accept that, or make `Client` `Configuration` and lose the 2-byte tag and the schema-commit-time `tier is Operator` check?
- (critic) Is `tier` the word, or do you want the three-way split to be a `Reference` table of its own (`system.auth.ClientTier`) so a deployment can add a fourth without a language change?
- (critic) Anything else you want folded in — in particular, whether you want `system.auth.Grant` declared as part of this answer or split out, since every version of this design depends on its shape.

### D04-regex

- The `multiline = True` finding means every `^…$` predicate written so far is bypassable by an embedded newline. Do you want that recorded as a normal doc correction under OQ-001, or does a defect that would have shipped a validation bypass deserve its own entry so it stays findable?
- `[[:alpha:]]` is ASCII-only in TDFA — `é` does not match. Is internationalised text validation a requirement for DataCode? It is the one argument that would flip the engine choice to `regex-rure`, and it would flip it now rather than later, because swapping engines after patterns are in the graph changes the meaning of stored schema.
- I recommend widening the argument class from strict alnum to `[0-9A-Za-z_-]` with a 64-character cap, since tenant codes and SKUs need `-` and `_` and the atom-position rule makes them safe. Is 64 the right cap, or do you have a real argument that is longer?
- The pattern budget defaults I picked (repetition product 1 000, node count 10 000, source length 1 024) are chosen to reject `(a|b){800}` with room to spare, not calibrated against anything. Do you want them calibrated against a target worst-case bytes-per-match figure instead, which I can measure?
- Should a row-path argument be admitted at all outside access asserts? It is the case that makes multi-tenant SKU validation work, and it is also the only case that makes cache occupancy a function of column cardinality. I recommend admit-with-warning, but reject-outright is defensible and simpler.
- The admin `search <table>.<field> matching <Pattern>` command is the honest home for 'I need to grep my data'. I did not propose it because nothing in the docs asks for it — is that demand real, or should it stay unbuilt?
- Anything else about the regex surface, the engine choice, or the sandbox build recipe that you want factored in?
- (critic) The 'template lives in a `Reference` row' home collides with `traits.md:398-400`: every insert is a schema commit replicating cluster-wide, and `Extensible` tables are rate-limited for exactly that reason. Is a per-tenant pattern set expected to be tens of rows, or thousands? At thousands, both the template design and my simpler alternative need a different home.
- (critic) `Extensible` on a pattern `Reference` table means a connector can author a pattern automatically. Do you want that ruled out explicitly — a bullet saying a `Pattern`-typed field may not live on an `Extensible` table — or is connector-authored pattern extension acceptable given the review queue at `traits.md:395-396`?
- (critic) The 'package import scope' item at `open-questions.md:409` is now load-bearing twice over: it decides whether `Data.Text`'s prefix/suffix predicates are DSL primitives (which my simpler alternative needs), and `functions.md:116-117`'s regex entry is a stale corner of it. Worth closing that item on its own before deciding anything about `=~`?
- (critic) Is a `=~` admissible at all on a `Secret` / `Hashed` field? `functors.md:92-96` restricts the signature and `railroad.md:165-167` already rejects `unique` and `indexed` there. A yes or no belongs in `types.md` regardless of what happens to parameterisation.
- (critic) The `multiline = True` default means every `^…$` predicate written so far is bypassable by an embedded newline. Per `CLAUDE.md` that is a settled decision (pin it to `False`) and belongs in `tech-stack.md` plus an OQ-001 bullet, not a new OQ — do you agree, or do you want a findable record of the near-miss anyway?
- (critic) Anything else about the regex surface, the engine choice, or how much of the sandbox build recipe you want checked in before the docs claim the engine is validated?

### D05-in-operator

- **The `LetExpr` repair is a precondition — do you want it in this change or separately?** The production admits neither the query binder at `functions.md:338` and `queries.md:338` nor the two-binding block at `auth.md:229-234`, both of which are normative examples today. The `in` disambiguation rule cannot be stated precisely until the production describes the language the docs already use. My proposal is `LetExpr ::= 'let' LetBind+ 'in' Expr` with `LetBind ::= Ident '=' ( Expr | Query )`, but it is a design decision and it is yours.
- **Do you want the `[`-lookahead refinement to kill the parenthesis papercut?** The normative rule I recommend costs you `let active = Order where (status in [Active])`. The refinement — 'the binder-terminating `in` is the one not followed by `[`' — removes that for every literal RHS and leaves the papercut only for a parenthesized-query RHS. It buys real ergonomics for a two-part rule instead of a one-part rule. I lean to the simple rule; the call is close.
- **Sub-query RHS: keep it, or literal sets only?** If you drop it, `` `elem` `` becomes the better answer outright — no new operator, no `let` collision, no provenance restriction to enforce, and `ListLit` plus the tuple still gives you `status \`elem\` [Pending, Shipped]`. The sub-query form is what earns the `CmpOp` entry.
- **Should `in` be admissible inside a `Behavior` definition?** A literal RHS is fine and stays solvable. A query RHS makes the behavior non-closed-form, and the crossing solver would have to fall back to sampling — the thing `events.md` says sampling exists to eliminate. Related and larger: a query inside a `Behavior` is evaluated at the transaction's sample moment, not at the moment the behavior is being asked about, which looks wrong for *any* query in a behavior, not only one under `in`. I have not touched it; it may deserve its own look.
- **Is 'under whose authority does an assert's own read run' genuinely unsettled?** I could not find it decided anywhere, and `><`-presence has the question already. If it is open, it is OQ-038 and the `in` RHS restriction is the conservative interim answer. If it is settled somewhere I missed, point me at it and the restriction may be able to relax.
- **Duplicates and order in `[…]` — settle here or defer to D13?** Neither is observable through `in`. My recommendation is written rows in written order with duplicates preserved (the Haskell reading, and the useful one for a literal table used as a `Source`), but it only binds once a list literal can be a query source, so D13 may be the better place to decide it.
- **Anything else to add — other positions where you expect to write `in`, other spellings you have in mind, or constraints from the D13 virtual-table design I should be building against?**
- (critic) The proposal's own Concession says `` `elem` `` wins if the sub-query RHS is dropped — and generalizing "a `Query` in `Bool` position asserts non-empty" from `AssertBody` to every `Bool` position gives you the sub-query case with no operator at all. Do you want that generalization decided first? It is the fork in the road: with it, `in` has nothing left to earn.
- (critic) Is `Order { customer }` typed `Table Customer` or a one-column table with a named column? The answer decides whether a projection can be an `in`/`elem` RHS at all, and it interacts with D13's record literals. `queries.md:267` licenses the bare-scalar reading only for a distributing path (`rows.bytes_sent`), not for a projection.
- (critic) What is `x in xs` when `x` reads `Redacted` because an access assert denied it, or `Erased` because the row was erased? Under the proposal's law it is `False`, so `not $ x in xs` is `True` and a negative filter leaks redacted rows into the result. Do you want an absence-carrying LHS rejected at compile time (which kills `phone in [NotGiven, NotFound]`), or the `Redacted` case defined separately?
- (critic) Should a query RHS be admissible in a field or type `WhereClause` at all? `self` is not in scope there (`railroad.md:912`), so it can never be anchored, and a validation functor is the one that runs per write on every row of every table carrying the type. My read is that it should be a compile-time error, but it is a decision about what a validation functor is allowed to be.
- (critic) The `LetExpr` production admits neither the query binder (`queries.md:338`) nor the multi-binding block (`auth.md:229-234`). That is a real pre-existing bug worth fixing regardless of this question. Do you want it fixed on its own, so the fix is not entangled with a membership operator that may not survive?
- (critic) Do you agree that "under whose authority does an assert's own read run" is unsettled? I could not find it decided either. If it is open it deserves a number on its own merits — `self >< Project >< Member` has the question today with no `in` involved.
- (critic) Anything else — other positions where you expect to write membership, whether the multi-column form is a real need or a nice-to-have, or constraints from D13 I should be judging against?

### D06-kill-query

- `Ephemeral` is the one genuinely new concept and it is bigger than this feature — `show replication lag`, connector in-flight state, and the generation table are all live runtime state currently expressible only as bespoke commands, and all three become ordinary tables under it. Do you want it introduced with that scope in mind (a general answer to 'system state that exists but is not stored'), or introduced narrowly for the query registry and generalized later if it earns it?
- The `reason` clause is mandatory only when killing someone else's query — a rule the grammar cannot express, so it lands as a bullet. Would you rather have it unconditionally mandatory, matching `ErasureCmd` exactly, at the cost of making the common case (`cancel` on your own runaway) longer than it needs to be?
- `query_text` in the registry is what makes `show queries` actionable, and it is also the only place the system holds query literals — safe here because `Ephemeral` never persists, but visible to any token with `bypass access` on `system`. Do you want it capped by a `Configuration` length, normalized (literals replaced by placeholders) with the full text available only on drill-down, or held in full?
- Three existing admin productions (`revoke token Ident`, `show transaction Ident`, `resolve conflict Ident`) take an `Ident` where the documented argument is a rendered `DataId`, which always begins with a digit and so cannot lex as an `Ident`. `ErasureCmd` already uses `StringLit` and `QueryCmd` follows it. Want me to fix the three, or leave them flagged?
- OQ-038 as drafted has three candidate answers, and the cheapest (an orphaned fragment terminates itself on budget exhaustion) needs no new mechanism but leaves the fragment burning a full budget's worth of I/O — the exact resource someone was trying to reclaim. Is that floor acceptable for the first cut, with a lease added later, or should the lease be in the initial protocol?
- Anything else — constraints, preferences, or context I have missed?
- (critic) The registry is created "at request admission", which scopes observation to the HTTP path. Do you want `show queries` to cover maintenance-queue work (view refresh, compaction, `Doc` shredding) and scheduled work (connector polls, `every` sampling) too? If yes, the registry cannot hang off request admission and `started_by`/`ownerAccess` need a story for rows with no `authed_user` — which is a different design, not an extension of this one.
- (critic) Access asserts redact rather than filter, so a non-admin's `show queries` is mostly opaque rows. Would you rather (a) accept that, (b) have the command apply an implicit `where started_by == authed_user` for tokens without `bypass access` on `system`, or (c) revisit whether an administrative *report* should redact at all — noting that (c) is a change to `constraints.md`'s redaction rule and reaches well beyond this feature?
- (critic) Cancelling a runaway cluster-wide mutation is currently unsolved, since only a queue's own handler may write its `QueueState`. Do you want that in scope here (which means widening the one append-only exemption, or adding a scheduler-side abort that is not a `QueueState` write), or explicitly deferred as its own OQ?
- (critic) The batch-scoped LMDB read transaction is the largest and riskiest change in the proposal and is not actually required by `cancel` — a check point that only reads a flag and a counter works under a query-scoped transaction. Should the LMDB lifetime change be split out as a separate decision measured against OQ-001's drain deadline and OQ-004's zero-copy result, rather than adopted as a consequence of this feature?
- (critic) OQ-012's distribution protocol is still open, and `cancel`'s fan-out and `show queries`' merge both assume its shape. Do you want this design to state its requirements *on* OQ-012 (a per-fragment control path, a demux reader, a liveness signal) and stop there, or to answer OQ-012's protocol half here?
- (critic) Anything else — constraints, preferences, or context I have missed?

### D07-prehashed

- `preHashed` or `unsafeHashed`? I chose `preHashed` because safety here is authorization rather than caller care, but the Haskell `unsafe*` precedent is the strongest argument against me and you may weigh it differently.
- Confirm the amendment to auth.md:284. The current text says 'keep the existing digest' when a post-login re-validation fails; I am changing it to re-hash regardless, on the grounds that a re-hash changes representation and not value. That is a change to a rule you already settled, and it is the one substantive rewrite in this proposal.
- Is `Credential where secret.policy /= <current>` a legal expression? It reads through a `Secret` field to a metadata attribute of the stored value. `==` and `/=` against a `Secret` field are compile-time errors (types.md:373), and the whole design leans on this query being available — so `secret.policy` has to be an admissible projection of the stored representation that is *not* the value. If you would rather not open that door, the alternative is a generated virtual column (`secret_policy :> HashPolicy`) on every `Hashed` field, which costs a column per field but keeps the `Secret` boundary absolute.
- Where does 'import shard restores stored representations and does not run the field-write pipeline' live normatively? I put it in cli.md's DR block because that is where the command is documented, but distribution.md or storage.md may own restore semantics better.
- Should `preHashed` in a projection be rejected outright, as I propose, or admitted with a warning? Rejecting it means a connector credential migration must be a handler rather than a binding, which is more machinery for the migration author but keeps the digest out of a plain `Text` column.
- Should I file the connector-shadow-`Secret` collision as OQ-038, or does it fold into OQ-025 (Connector Schema Change Propagation)?
- Anything else you want factored in — a specific legacy scheme beyond MariaDB's, a deployment where the migration cannot force a reset, or a constraint on how long a verification-only policy may remain live?
- (critic) The proposal's questions_for_user #3 (`secret.policy` legality) is not a question, it is a dependency — four of its conclusions fail if the answer is no. Do you want the generated `secret_policy :> HashPolicy` virtual column decided as part of this change, or is deferring it acceptable knowing the `Derived` classification does not stand without it?
- (critic) Retiring a superseded foreign digest has no working mechanism (`ScrubRule` matches names, not versions; `scrub` is one command per version per row). Is that the genuine OQ-038 — "how is a population of superseded `Secret` versions retired" — and does it generalize past credentials to data-key rotation, where auth.md:369 has the same lazy re-encryption leaving old ciphertext in the chain?
- (critic) Should a function permission be a subtree grant at all? Given recursion, `grant … on system.crypto.preHashed` is subsumed by any grant on `system`. The same hole exists for `reveal` today. Options: a non-recursive permission axis for function nodes, a `BypassKind`-style modifier, or accept that an administrator on `system` can set any password.
- (critic) Is `matches`'s argument order the signature (`Hashed a -> a -> Bool`) or the examples (`attempt `matches` c.secret`)? They disagree, and the login path depends on it.
- (critic) Anything else you want factored in — a target cluster size for the credential import (it drives whether a million-row `Configuration` table is acceptable), a deployment where the source system cannot `reveal` its TOTP secrets, or a position on whether the transaction graph should retain mutation *expressions* rather than only applied mutations?

### D08-cli-fixes

- OQ-038 is the blocker under all of this: does a shard hold **one** root row and its dependents, or a **contiguous interval** of root rows? Everything operational — `split shard`, the partition function, one sequence space per shard, `ShardIndex` as a `Word32`, whether `show shards` can be a query at all — needs the interval reading; `shardOf`'s partiality and `erase shard` need the row reading. Which one do you want, and do you want the other level renamed (`root`? `subtree`?) or just documented as a family concept?
- Do you accept deleting `erase shard` in favour of `erase <table> <DataId>` cascading over the FK chain? railroad.md:838 already defines it as a row-rooted cascade, and the shard spelling makes a DSR's blast radius depend on the partition function — but it does change a compliance-facing command.
- The exact-count footer: are you content with `100 of 100+` on anything that is not cheap to count, plus a named table in the hint so the operator can ask for the real number? Or do you want a `--count` flag that explicitly pays for the scan?
- `csv` and `raw` exempt from the default page cap — agreed? The alternative is capping them and accepting that a script can silently process 100 of 123456 rows with nothing in the output saying so.
- Should the default page cap apply to **ordinary queries** at the REPL and over the API, or only to the `show` family? Capping everything is what OQ-005 listed as 'pagination config' and is the safer default, but it means an unqualified `Order where total > 100` returns 100 rows to an API client that did not ask for a limit.
- `auto_reclaim = False` by default — do you want failback proposed through the maintenance queue, or is that too slow for your operational model and it should default to automatic after quiescence?
- Should a `recover/` branch be created **eagerly** at rejoin whenever the fenced server wrote anything, or only when its divergent writes actually conflict with what landed on `main`? Eager is simpler and always correct; lazy avoids a branch for the common case where the partitioned server wrote to rows nobody else touched, but requires deciding 'conflict' before an operator has looked.
- Do you want the epoch surfaced as a column in `show shards` / `show servers` output by default, or only under `describe shard`?
- Anything else — corrections to the above, other cli.md irritations you have been meaning to raise, or constraints from how you actually expect to operate this that would change the failback or paging defaults?
- (critic) Do you want failover automatic at all? The proposal assumes yes ("failover must be automatic or the cluster stalls"), but OQ-006 has never settled it, and if elevation stays operator-initiated then the two-of-three ACK question disappears and §4 shrinks to fencing plus rejoin — which is most of its value at a fraction of its risk.
- (critic) When a table-wide `unique` value was handed out on both sides of a partition, which row keeps it? "Nothing is destroyed" and the constraint cannot both hold, and where the value is a root table's placement key, distribution.md:325 rejects `release` outright — so today there is no legal path to free either copy.
- (critic) Should a `recover/` branch be reachable by an ordinary `at` version token before it is merged? If yes, an erasure applied on `main` does not reach the divergent copy, which is an OQ-036 problem; if no, that is a new class of branch and needs saying.
- (critic) Does `limit` without `order by` have a defined meaning? The word appears nowhere in queries.md, which is its normative home, and every cursor design here depends on the answer.
- (critic) Anything else — other cli.md irritations, or a view on whether OQ-038 (one root row versus an interval of root rows) is something you already had an answer for that the docs simply never recorded?

### D09-connectors

- Batch granularity: one DataCode commit per external transaction (exactly-once at transaction resolution, one cross-shard prepare round each), or per `batch_window` (cheap, and a crash re-applies at most one window)? I have defaulted `batch_window = 200 milli`; the trade is round trips against re-apply blast radius, and it is the only real tuning knob in the design.
- Should `system.connectors.ExternalTxn` and `ChangeEvent` carry `Personal`? The row image is a verbatim copy of every source PII value, and `erase` cannot currently reach it, so erasing a shadow row today leaves the data in the arrival log.
- Unreserving `DataCode` and `External` versus renaming the variants to `DataCodeWins`/`ExternalWins`. I recommend unreserving on the `access` precedent, but it changes a published CLI production and you may prefer the rename.
- Does the connector *generate* a `retain` chain for the tables it creates, or must an operator write one? Silence means keep, so an undeclared chain means the binlog mirror grows forever — but generating one means the system starts discarding data nobody authored, which is the polarity the retention design deliberately avoids.
- Should the `ExternalTxn` frontier rollup carry `max rows.source_server` for MariaDB's `@slave_connect_state`? I believe MariaDB positions on `(domain_id, seq_no)` and treats the server_id component as informational, but that is the one protocol claim here I did not verify against a source file, and if it is load-bearing the rollup needs an argmax rather than a max.
- Anything else — other spots in `connectors.md` you already knew were wrong, constraints on the connector worker's process model, or source deployments that cannot enable GTID and so need the `mysql_filepos` kind to stay first-class rather than a fallback?
- (critic) The livelock in F1 turns on when a rollup level is written — at prune time, per OQ-005:378 ("a rollup is two appends, aggregate rows then a prune node"). If rollup levels are in fact maintained continuously rather than at expiry, F1 softens to a materialization-lag question. Which is it? That one fact decides whether the derived position is fixable or has to be replaced.
- (critic) Does `retain` reach a `Configuration` table? `aggregates.md:322-326` says only "nothing in it requires that table to carry `LogData`". If it does, the proposal's whole case against storing the position collapses and the argument has to be re-founded on cluster-wide replication cost alone.
- (critic) Are variant names scoped per type or globally? `authority : DataCode | External | Symmetric` and `choice : DataCode | External | Merge` need per-type scoping to coexist, and nothing in `types.md` or OQ-005 says so.
- (critic) Is the connector expected to write an `ExternalTxn` row for every source transaction, including ones touching no shadow table? That is what MySQL gap-freedom costs, and it changes the storage budget by orders of magnitude on a shared source.
- (critic) Initial load: how does a shadow table get its first full copy, and at what GTID? Nothing in `connectors.md` covers snapshotting today, and the "no stored position" design makes the snapshot GTID unrepresentable.
- (critic) `railroad.md:116-117` says `using` is valid only on `Hashed`, but `types.md:474` already writes it on `Encrypted`. Which is normative — should `railroad.md:162` be widened, or is `types.md` ahead of the grammar?
- (critic) Anything else — other spots in `connectors.md` you already knew were wrong, whether the verbatim row-image mirror is wanted at all or was only ever the checkpoint's carrier, and how long a connector is allowed to be offline before re-seeding is acceptable?

### D10-lmdb-vs-sqlite

- Do you accept the one exception this requires to `nothing is destroyed` — that a view refresh REPLACES the derived row rather than appending a version? It is safe because the data is recomputable, but it is a real exception and I would rather it be a decision you made than a consequence you discovered.
- Should a materialized view be visible to `at <moment>` queries at all? A view is pegged to one commit node, so a query at a different moment cannot legally read it. My assumption is that the planner falls back to the source silently and the view is a pure optimization, but the alternative — reporting `NotRetained`-style that the fast path was unavailable — is defensible given how much this design prefers typed gaps to silence.
- Do you want the environment split (primary versus derived LMDB environments) recorded in `storage.md` as normative, or held back until the `spikes/arrangement` numbers exist? It is the one part of this that is an operational judgement rather than a consequence of an existing rule.
- OQ-038 as proposed covers key encoding and text collation together. Would you rather split them — encoding is mechanical and settleable now, collation is a policy question with an ICU-version hazard — or keep them in one question because collation is only reachable through the encoding?
- Is the `an index is the degenerate materialized view` framing one you want stated that strongly in `storage.md`? It is the cleanest reading and it explains `there is no create index`, but it also means every declared `order by` now visibly costs something on every write, which may read as a regression to someone skimming `tables.md`.
- Anything else you want factored in — a target workload shape, an expected view count per shard, a disk budget, or a constraint I have not seen in the docs?
- (critic) `system.integrity.Violation` mixes `Derived` rows (droppable) and `Observed` rows (irrecoverable) in one table, and integrity.md:55-57 calls the table a materialized view. Should derivedness be a row-level discriminator (reusing `origin`), or should the two classes be split into two tables so an extent-level rule becomes possible? The first is smaller; the second makes the physical rule simpler and would change integrity.md.
- (critic) Is a materialized view over a source that is under a `retain` chain permitted at all? aggregates.md:365-369 draws the line ('a rollup's source is pruned, so it is a real table, not a view'), but nothing checks it. If it is permitted, discarding such a view can lose data that pruning left intact, and the discard rule needs a guard rather than an unconditional 'loses nothing'.
- (critic) tech-stack.md:206 already lists LMDB free-list growth under a long reader as open, and the proposal's own §8 says that measurement is the only one that can change the recommendation. Do you want any of the physical design (environment split, `MDB_NOSYNC`, build-then-swap) recorded before `spikes/arrangement` runs, or should this answer stop at the engine question and the derived-table reframe?
- (critic) transaction-graph.md:667-673 says pruning touches only `LogData`; aggregates.md:340-348 describes `UserData` row-level pruning destroying version chains. Which is authoritative? Several rules here (recomputability, per-field timestamps reading `NotRetained`, view discardability) depend on the answer.
- (critic) Anything else you want factored in — in particular, whether you regard `materialize` reaching production without a schema commit as acceptable given that auto-proposed views can silently fail access asserts for restricted tokens, or any constraint on this area I have not read in the docs?

### D11-row-number

- Is the real driver for row numbering **running totals or SQL `RANK`**? Both stay O(n squared) after this change, so if they are the motivation then `row_number` is not the feature — an ordered prefix-scan aggregate is. Worth designing that instead, or as well?
- Should `row_number` be admissible in a **`GroupClause`'s projection**? Allowing it is what makes `ntile` and equal-width bucketing expressible (`group { row_number * 4 / total as quartile }`); restricting it to the final projection is one fewer place for the pipeline-order question to bite. I recommend allowing it, but it is a real narrowing decision either way.
- **`via <alias>.<field>` as the self-edge direction disambiguator** — acceptable? It uses the alias bound later in the same clause, which is a slightly odd read (`via report.manager+ as report`). The alternative is a reserved word for reverse, or fixing the clause order so `as` precedes `via`. Related: the one-hop case `Employee >< Employee via manager as m` is **already ambiguous today** and nothing in the docs resolves it — should that be fixed in the same change?
- Adopt **`parent` as a virtual column on `Component` tables**? It is the one genuinely new column here and is needed to write a closure over a shredded `Doc` node tree, which is the case with the best cost properties (one prefix range scan). It is separable — reject it and the rest of the closure design is unaffected, but the `Doc` tree stays reachable only by declared paths.
- **Link-table recursion (BOM) and path aggregation** — park as OQ-038, or needed now? They are the two things the narrow operator does not cover, and covering them means either widening `via` to accept a derived self-edge binding or importing something closer to Datalog. I recommend parking, but not if a BOM is on the near-term workload.
- Do you want the **`QueryClause*` left-to-right pipeline rule stated normatively** in this change? It has been assumed since `group {A} {B}` was described as needing no new production, and both `row_number` and grouping-over-an-ordered-source depend on it, but nothing in `railroad.md` or `queries.md` says it. It is a one-sentence addition and a separable one.
- Any other notes, constraints, or motivating cases I should fold in before this is written into the docs?
- (critic) Do you want a self-referential FK to be able to root a shard at all? `tables.md:207` (no `Null`-derived variant in a key) and the fact that every tree root has an absent parent are in direct tension, and resolving it — a `Component`-style containment self-edge, a distinguished self-loop root, or an exemption for the head variant of a self-referential alternation — is a real OQ that this work uncovered and neither part addresses.
- (critic) Is scalar extraction from a one-row table something you want? Argmax ("the customer with the highest total") is not currently expressible, and it is the case people actually reach for `first_value` to get. That is a smaller and more broadly useful feature than either half of this proposal, and it makes the group-nests story deliver what the proposal claims it already delivers.
- (critic) Should the generated-column names of `group`, `diff`, and a closure be renameable in general? `rows` is renameable via `NameClause`; `before`/`after`/`change` and the proposed `depth` are not. One rule either way is cheaper than three.
- (critic) Is a correlated subquery in a projection — `(rows order by total desc limit 1) as top` — something you intend to admit? It is the load-bearing move under half the worked examples and it is a larger semantic addition than anything either half proposes explicitly.
- (critic) Anything else you want folded in — in particular, whether a BOM or link-table recursion is actually on the near-term workload, since it decides whether the narrow edge operator is the right shape at all?

### D12-reference-autoinc

- Do you want OQ-038 (cross-branch variant-tag collision) opened as a new number, or folded into OQ-033 as a fourth failure mode of interned-key growth? It is not about the cap, so I lean new — but OQ-033 is where the tag lifecycle is currently discussed.
- The writeback rule refuses inserts into a shadow table over a source with no natural key. Is that acceptable, or is there a real migration case where DataCode must originate rows into a legacy MariaDB table whose only identity is its autoinc? If so, the answer has to be the outbox table, and the ergonomic cost of having no union operator becomes a live question.
- Should generated shadow tables carry `UserData` unconditionally, or should the connector infer `Reference` for small, stable code tables at the author's explicit opt-in? I recommend `UserData` always, with promotion to `Reference` being an authored redeclaration — but that means a 40-row status table replicates as shard-local data until somebody says otherwise.
- Is multi-source ingestion into one logical entity actually in scope for v1? Per-instance namespaces (namespaces.md:84) mean collision only arises at the overlay, and with no union operator the overlay cannot combine two sources anyway — so I have treated it as out of scope. Confirm.
- `binlog_row_image=FULL` as a documented prerequisite: is that acceptable operationally on your production sources, or is the writeback design constrained to key on the source PK because `MINIMAL` is what you actually run?
- Anything else about the ingestion path, the `Reference` tag rule, or the shadow/overlay split you want folded in before I write the edits?
- (critic) `traits.md:330` puts `Reference` rows in the `system` shard; `distribution.md:246` puts them on the branch shard. Which is normative? The answer decides whether OQ-038 (cross-branch tag collision) is a real question or an artifact of the contradiction — under the `system`-shard reading there is one allocator and no collision.
- (critic) Are you willing to have DataCode *enforce* a uniqueness constraint on ingested data at all? Any candidate key on a shadow is schema-time and therefore enforced (`integrity.md:105-109`), so the only safe choice is a constraint the source itself guarantees — its PRIMARY KEY. If you want overlay-level natural keys enforced, that has to be a `monitor`-mode assert, not a `unique`, and `railroad.md` has no spelling for a monitored uniqueness.
- (critic) Should the `connector_log` block at `connectors.md:72-82` be rewritten in real DataCode syntax as part of this change? It currently uses `UUID?` and `Enum(...)`, neither of which is expressible, and `UUID?` contradicts the no-NULL invariant.
- (critic) Anything else about the ingestion path, the `Reference` tag rule, or the shadow/overlay split you want folded in?

### D13-virtual-tables

- Parent dedup rejects the case where two elements agree on a base's key but disagree on one of its non-key columns. Real ingest data (a denormalized CSV where one line has a stale `total`) will hit this. Reject with a diagnostic naming the column is my recommendation — do you want an escape, and if so is it a projection that drops the disputed column from the target rather than a resolution rule on the insert?
- `max_transaction_rows` counted across the staged transaction rather than per statement: is 1,000 decomposed row writes the right default for your deployments, and do you want a per-table override table (mirroring `ExtentPolicy`/`ExtentOverride`) or is one global `Configuration` row enough?
- Nested component literals (`headers = [ {…}, {…} ]`) depend on settling whether a `:>` `Component` field is single- or table-valued. I recommend table-valued with `= { … }` as sugar for a one-element literal. Do you want that raised as OQ-038 and answered before the nested form lands, or should D13 ship the flat form alone and leave nesting until then?
- A top-level binding to a bare table literal (`Tier = [ {…}, {…} ]`) is a constant table with a degenerate key. The existing degeneracy warning says the right thing, so I would permit it with no new rule — but it does compete with `Reference` tables for the same job. Permit, warn harder, or reject with a diagnostic naming `Reference`?
- Four pre-existing gaps surfaced: `Insert`/`Update` ambiguity with no written rule, no clause restriction on write targets (`Order at "v2.1.0" { … }` parses today), `SchemaFile` not admitting `Mutation` despite `.dc` files being documented to contain them, and the stray `insert` keyword at functions.md:194-195. The first two are design decisions and I have not touched them. Fold them into this change, or split them into their own pass?
- Anything else you want weighed here — particularly on the returned shape, whether you eventually want `INSERT … SELECT`, or constraints from the ingest workloads you have in mind that would change the cap or the dedup rule?
- (critic) Is the denormalized-input case (paste a CSV grid, let the system infer which rows share a parent) a real workload you have, or is it inferred? The nested form covers everything else and costs far less; if the grid is real, that is worth knowing because it is the only thing dedup buys.
- (critic) Do you want an unfiltered whole-table update to remain writable? The proposal's insert/update rule makes `Order { status = Shipped }` an insert, so update-all becomes `Order where True { … }`. Same question for `order by … limit` in an update target, which rejecting removes "cancel the oldest pending order".
- (critic) Should a mutation return rows at all? queries.md:567 says an update "returns a new version" — a full re-read of the target through the access-assert path on every batch is a real cost on the bulk path, and there is no defined sample moment for reading an uncommitted staging area.
- (critic) Anything else you want weighed — particularly whether reference-data seeding (a `Reference` insert is a schema commit) should be the design's centre of gravity rather than user-data batch insert, since the two land on completely different write paths.

### D14-nesting-json

- Under `nest`, should a forward (to-one) edge nest by default, or only when the alias is named in the projection? Nesting by default gives the JSON everyone wants from `Order >< Customer`; naming it keeps the projection the single authority for what appears. I lean toward requiring the name, so that no column appears that the projection did not ask for — but it makes the common case one token longer.
- (critic) When a nested column is written through, should the nested rows be ordinary rows of the base table (their own `DataId`, own shard placement, `deprecate` does not cascade) or `Component` rows of the parent? `group`'s documented default is `Component` (queries.md:230), which is right for an ETL extraction and wrong for a nested view of `OrderLine`. My recommendation: a `nest`-produced column inherits its **source's** trait, and `: TraitList` stays available to elevate or demote — the same knob `group` already has, with the opposite default. Do you want that default flipped only under `nest`, or flipped for `group` too?
- (critic) Should a `.dc` re-import be required to replay scrub and erase nodes, the way a shard restore already is (OQ-036, open-questions.md:227)? That is the only thing that stops an export/scrub/re-import cycle from being the way destroyed data returns. The cheap alternative is to refuse `as dc` on any query whose sources carry `Personal` or reach a `Secret`, which is cruder but needs no new machinery.
- (critic) When an export handler runs, whose access rules apply and at which moment — the requester's, re-derived at dispatch against HEAD (consistent with OQ-027's rule for historical reads), or a dedicated export role? And what should happen if the requester is deprovisioned between enqueue and dispatch: fail the export, or run it under the authority as it stood at enqueue?
- (critic) Do you want `nest` (or its projection-form equivalent) admitted inside a template `Hole`? It would give nested rendering — an invoice with its line items in one hole — but it changes the hole's result count, which is currently the entire control-flow mechanism (railroad.md:702-706). I lean toward rejecting it in v1 and treating nested rendering as its own question.
- (critic) Anything else you want weighed here — particularly whether the export destination should be per-server or cluster-wide by default, and whether `export shard`'s unvalidated path should be retrofitted in the same change or left as a separate DR decision?

### D15-default-type

- Was "we need a Default keyword" actually about a *record-literal expression* — `Order where id == "…" { total = default }`, meaning "write whatever the schema's default currently is" — rather than about provenance? There is no spelling for resetting a field to its default today (omitting it in an update means "leave unchanged"), and it is a real gap. It would need a reserved word, because `default` resolves against the enclosing field. I deferred rather than rejected it; say the word and I will design it.
- Do you want the supplied-field mask (Tier 1, 8 bytes per row version, forever, replicated), or is the free Tier 0 comparison enough? My recommendation is Tier 1, but I would decide it on merge reconciliation and connector conflict granularity, not on the defaulted question alone — that is what OQ-038 is for.
- Once the mask exists, should `Table.field.updated_at` keep meaning "last *changed*" (value differs from predecessor) or be redefined to "last *named*"? They diverge when a write sets the same value. My recommendation: keep `updated_at` as-is and let `provenance is Supplied` carry the other reading, rather than adding a third column.
- `provenance` is ten characters and appears in every audit query. Is it worth it against a shorter name? `origin` is out (your own schema uses it twice), `defaulted` loses the sum. I could not find a short word that is both unambiguous and unlikely as a column name.
- The three-way contradiction on what an evolution-added field reads on old rows (default / `NotFound` / `NotGiven`) has to be settled before provenance can be defined. I recommended "the default at the node that added it, else an absence variant of the field's own type" — do you want me to write that fix, or is it yours to make?
- Should `provenance` be admissible in an `on` condition (`on total.provenance is Supplied emit …`, "someone finally set this by hand")? I said yes because the mask is already in the write, but it is the loosest of my recommendations.
- Anything else you want me to weigh — other uses you have in mind for write provenance, a different read of the absence/presence symmetry, or constraints from work in flight that I have not seen?
- (critic) Is "manually added" about a *human* or about *any explicit write*? A form POST and a connector sync both name every column, so a supplied-field mask answers True for both. If you mean a human, the answer is an author on the write — which the transaction graph does not currently record at all (storage.md:17) — or a declared `set_by :> User = authed_user` field, not a mask. Which did you mean?
- (critic) Does `Table.field.updated_at` count the creating version as a change? The doc says "differs from its predecessor" and the creating version has none (transaction-graph.md:650). Settling this one word decides whether `total.updated_at /= created_at` is the free answer to your question, so it is worth deciding before anything is built.
- (critic) Was "we need a Default keyword" actually about a record-literal *expression* — `Order where id == "…" { total = default }`, meaning "write whatever the schema's default currently is"? There is no spelling for resetting a field to its default today (omitting it in an update means "leave unchanged"), it is a real gap, and it is a much smaller change than write provenance. The proposal defers it; I would rather see it designed first, because it may be the whole of what you asked for.
- (critic) If a supplied-field mask ships, what does a **merge** commit write? Every design here turns on that answer, and if the reconciliation functor writes a full row image naming every field, the mask is all-ones after any merge and the feature is dead on branch-heavy workloads.
- (critic) The evolution.md:274 / transaction-graph.md:655 conflict (`NotFound` versus `NotGiven` for a field added by redeclaration) is real and independent of this question. Do you want that settled on its own — my read is that both are wrong where the field has a default, and `NotFound` is wrong in every case because it is not in the declared type — or held until provenance is decided?
- (critic) Anything else you want weighed — other uses you have in mind for write provenance, a different read of the absence/presence symmetry, or constraints from work in flight that I have not seen?

### D16-backreference

- Should the reverse relation's name default when omitted? A bodiless `Comment` child could imply `Document.comments` (child table, snake_case, pluralized), which would let `:describe … deep` nest an unnamed inbound FK. My recommendation is no — pluralization is a natural-language guess, the capitalization convention is style rather than grammar, and Django's `<model>_set` default is the part of `related_name` people most often override. But it would make every existing FK nestable without a schema edit.
- Should the child's replication trait default to `Component` instead of to the parent's? I recommend the parent's, so cascade delete is always written; the counter-case is that most things you nest inline genuinely are owned, and `: Component` on every dependent declaration is noise.
- For a two-root linking table, should the disagreement between nesting and key order (nested under `Order`, key `{ tag, order }`) be a warning or an error? I recommend a warning, matching the cross-shard FK warning, but an error is defensible since the source text then claims an ownership the storage does not honour.
- Should a table-valued reverse path be admissible directly in an `AssertBody` (`assert hasComment { self.comments }`), or must presence keep the single join spelling (`self >< Comment`)? I recommend rejecting the path form to keep one presence spelling, but the path form is shorter and the anchoring rule already permits reverse traversal.
- Do you want `:describe … deep` to take a depth (`deep 2`), or is unbounded-with-cycle-detection enough? Unbounded is simpler and matches `verify shard … deep`; a depth argument would need a `NumLit` in the production.
- Is `Reference` child with a `:>` into shard-local `UserData` something you want ruled out now, or left as the pre-existing open case? This construct makes it easy to write by accident via `SubTableTraits`.
- Anything else you want factored in — other cases this has to cover, constraints I have not seen, or parts of the above you want argued harder?
- (critic) Which reading of `headers :> RequestHeader : Component { ... }` is correct — one header (tables.md:326, `:>` wraps a `DataId`) or all of that request's headers (queries.md:234-236, 'the same construct as an inline component sub-table', plus `ordinal`, document order, and the 2^32-per-parent cap)? This is not a detail of the proposal; it decides whether the proposal is closing a gap or adding a second spelling, and it needs settling in tables.md and queries.md either way. My reading is table-valued.
- (critic) Do you want the reverse relation declared on the parent (`comments :< Comment`, an amendment to another table) or on the child (`document :> Document reverse comments`, a local attribute of the FK)? The proposal itself concludes the NAME must be stored on the FK edge, so the child-side spelling makes declaration and storage coincide and deletes about nine rules. Is the inline-child-declaration ergonomic worth those nine rules to you?
- (critic) Should `count <reverse>` be usable as a filter predicate on the parent when the child carries an access assert? constraints.md:240-243 deliberately accepted visible cardinality for rows already in a result; using it in a `where` turns it into a scannable oracle over rows the requester may not read. Rule, or recorded known leak?
- (critic) For a `Component` child, should `deprecate <Parent>.<reverse-name>` drop the name only and never the edge? traits.md:220 says a component cannot be reparented because the parent IS the identifier, so the proposal's uniform 'retires the relation and its generated FK' cannot apply there.
- (critic) Should the cross-root FK of a many-to-many be reported at schema commit as coerced out of `enforce always` (open-questions.md:144)? Today that rule is stated for asserts; whether an FK functor's referential integrity is subject to it is not written down anywhere I could find, and a linking table is where it first bites.
- (critic) Anything else you want factored in — other cases this has to cover, constraints I have not seen, or parts of the above you want argued harder?


## Catchall

Anything else — constraints, workloads, deployment shape, or parts of this you want argued
harder or taken in a different direction?