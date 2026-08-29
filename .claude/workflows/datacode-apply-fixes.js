export const meta = {
  name: 'datacode-apply-fixes',
  description: 'Apply the full review to docs/: grammar first, then all 30 files, then indexes, then verify',
  phases: [
    { title: 'Grammar' },
    { title: 'Rewrite' },
    { title: 'Indexes' },
    { title: 'Verify' },
  ],
}

const ROOT = '/mnt/c/Users/chris.tobey/Documents/synced/git/datacode'

const COMMON = `You are applying a completed design review to the **DataCode** documentation.
Repository root: ${ROOT}. DataCode is a category-theoretic distributed database in Haskell, in
design phase — the repo is documentation and feasibility spikes, no production source.

## READ THESE FIRST, IN FULL

1. ${ROOT}/CLAUDE.md — project instructions, invariants, documentation style.
2. ${ROOT}/review/00-report.md — **the whole file**. Its "Decisions taken" section holds ~30
   decisions made and confirmed by the project owner during the review. They are settled. Apply them.
3. ${ROOT}/review/50-validation.md — the admissible-default table (§B) and the settled §E items.
4. Your own file's findings. ${ROOT}/review/10-findings.md is 1.1 MB grouped by file; extract only
   your section, e.g.:
   \`sed -n '/^## docs\\/schema\\/types.md$/,/^## docs\\//p' ${ROOT}/review/10-findings.md\`
   Each finding carries evidence, why it is wrong, and a proposed fix. **Line numbers refer to the
   file as it was before this pass** — locate by quoted text, not by line number.

## THE SINGLE MOST IMPORTANT INSTRUCTION

**This is a correction pass, not a rewrite from scratch. PRESERVE THE REASONING.**

These documents record *why* each decision was made and what it replaced. That record is the point
of the corpus and it is expensive to reconstruct. Fix what is wrong, cut what is genuinely
duplicated, and **keep every argument, every rejected alternative and every "this replaces X"
note**. If you find yourself deleting a paragraph that explains a decision, stop — you are doing the
wrong thing. Shorten prose that restates the sentence before it; never shorten prose that carries an
argument.

If a finding's proposed fix would delete reasoning, apply the correction and keep the reasoning.

## WHAT TO DO

- Fix every finding in your section that is still valid. Some may have been overtaken by a decision
  in 00-report.md — if so, the decision wins and you skip the finding.
- Apply every decision from 00-report.md that touches your file. Several touch many files; each of
  you handles your own file's part only.
- Make every code example conform to the corrected grammar (supplied below). This is the largest
  single category of defect in the corpus.
- Remove redundancy: **one normative home per rule, everything else links.** Homes are listed in
  CLAUDE.md. If your file restates a rule owned elsewhere, replace the restatement with a link and a
  one-line summary. If your file *is* the home, make sure the rule is stated there completely.
- Fix broken links and anchors. An anchor is the heading lowercased, punctuation dropped, spaces to
  hyphens, backticks dropped.

## STYLE

Microsoft Documentation Style, as CLAUDE.md specifies: second person, active voice, present tense,
sentence-case headings, short sentences, lists over prose walls. No "simply", "just", "obviously",
"we". Match the existing voice — it is already close, and the corpus reads as one document.

## RULES OF ENGAGEMENT

- **Edit ONLY your assigned file.** Another agent owns every other file. If you find a defect
  elsewhere, report it in \`cross_file_notes\` rather than fixing it.
- Do not create new files.
- Do not add an OQ number. One agent owns \`open-questions.md\` and will file them; report anything
  you believe is genuinely open in \`new_open_questions\`.
- Use Edit for targeted changes and Write only if you are restructuring the whole file.
- Never leave a placeholder, a TODO, or "TBD" that was not already there and still true.`

const RESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    file: { type: 'string' },
    findings_fixed: { type: 'number' },
    findings_skipped: { type: 'array', items: { type: 'string' }, description: 'Finding title plus why it was skipped — overtaken by a decision, refuted, or out of scope.' },
    decisions_applied: { type: 'array', items: { type: 'string' } },
    structural_changes: { type: 'array', items: { type: 'string' }, description: 'Sections added, removed, merged, or moved.' },
    redundancy_removed: { type: 'array', items: { type: 'string' }, description: 'Rule restated here that now links to its home instead.' },
    cross_file_notes: { type: 'array', items: { type: 'string' }, description: 'Defects found in files you do not own.' },
    new_open_questions: { type: 'array', items: { type: 'string' } },
    unresolved: { type: 'array', items: { type: 'string' }, description: 'Anything you could not fix and why.' },
  },
  required: ['file', 'findings_fixed', 'decisions_applied', 'structural_changes'],
}

phase('Grammar')

const grammar = await agent(`${COMMON}

## YOUR FILE: docs/schema/railroad.md

You go first and alone, because every other file's examples must conform to what you produce. This
file is the single source of truth for DataCode syntax: the EBNF is both the normative grammar and
the railroad-diagram source.

Fix the **eight structural defects** named in 00-report.md, and apply every grammar delta from the
decisions. At minimum, and check 00-report.md and 30-integrated-grammar.md for the full statement of
each:

**The assert grammar.** \`not $ <Query>\` has no parse; a bare \`Query\` cannot be an operand of
\`||\`; \`StandaloneAssert\` admits only \`Expr\` so no derived table can carry a presence or access
assert. The recommended single fix is to lift "a \`Query\` in boolean position asserts non-empty"
from \`AssertBody\` to **every \`Bool\` position**, which repairs all three. Decide and implement.

**\`Binding ::= Ident\`** cannot name a namespaced derived table, which four files declare. Use \`QName\`.

**\`retain\` chains.** \`drop\` is a \`ChainStep\`, so it violates "every later step carries \`by\`" and
the \`as\` step-count rule — every \`drop\`-terminated chain in the repo is illegal. Make \`drop\` a
terminal rather than a step.

**\`TypeDecl\` admits \`WhereClause*\`** where the prose and OQ-005 both say one \`where\` per declaration.

**\`LengthLit\` is unreachable from \`Expr\`**, so \`every 15 minute\` and \`= 15 minute\` do not parse.

**Reserved words used as field names** in five normative declarations (\`reason\`, \`handler\`, \`key\`,
\`order\`, \`view\`-adjacent). Some are doc bugs for other agents; the grammar-side decision is which
words stay reserved. Add \`cancel\` and \`conflicts\`; unreserve \`DataCode\` and \`External\`.

**The \`:\` maximal-munch row is wrong** — it lists \`:\` and \`:>\` and omits \`:<\` and the seven
\`MetaCommand\` literals.

**Every \`Ident\`-typed identifier argument in Administration** should be \`StringLit\`: a rendered
\`DataId\` begins with a digit and cannot lex as an \`Ident\`. Four positions are affected.

Then the additions from the decisions:

- \`TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'\` in \`Atom\` and \`Source\`; \`[\` and \`]\` as
  single-character tokens. Membership is \`\\\`elem\\\`\`, an ordinary backtick infix — **no \`in\` operator**.
- \`Insert ::= QName RecordLit | Query TableLit\`.
- \`ProjItem ::= FieldPath Projection? NameClause?\` — nesting in the projection. There is **no
  \`nest\` clause**.
- \`BackRefDecl ::= ':<' QName SubTableTraits? ( 'via' Ident )? SubTableBody?\` as a \`BodyItem\`.
  The name goes on the **right** with \`via\`; there is no left-hand identifier and no reverse column.
- \`SubTableRows ::= TableLit\` on \`FieldDecl\`, after \`SubTableBody\`; and
  \`DefaultClause ::= '=' ( Expr | Query | SeqAlloc )\`.
- \`ShowCmd ::= 'show' ShowTarget ReportClause*\` with
  \`ReportClause ::= WhereClause | OrderByDecl | LimitClause | Projection\`, folding in \`TxnCmd\` and
  \`IntegrityCmd\`; \`ShardRef\`/\`ShardRange\`; \`CancelCmd\`; \`ExportCmd\`; \`--limit\`.
- \`MetaCommand\`'s \`:describe QName 'deep'?\`.
- \`Resolution ::= QName | 'merge' RecordLit\`.

Also add or correct the **constraints not expressible in the grammar** for all of the above,
including: the admissible-default rule (50-validation.md §B is the authority — every added column
declares a default; the criterion is \`Pure\` and stable for the life of the row; \`next\`,
\`authed_user\`, lazy queries and mutable-field expressions are rejected; a \`:>\` to a \`Component\`
target needs none); \`limit\` requires a total order extended by the candidate key; a \`Component\`
\`:>\` field is table-valued; \`SubTableRows\` only on a \`Reference\` sub-table; a schema object may
not name a data row; POSIX character classes rejected in \`=~\` patterns.

Update the **Reserved Words** section and its "considered and deliberately not reserved" list to
match, including the reasons — that list is one of the most valuable things in the file.

Return the complete final EBNF and reserved-word list in \`unresolved\`'s first element is WRONG —
instead, put the complete final EBNF, verbatim, in \`structural_changes\` as a single element, so the
next phase can be given it.`, { label: 'grammar:railroad', phase: 'Grammar', schema: RESULT_SCHEMA })

const grammarText = (grammar && (grammar.structural_changes || []).join('\n\n')) || '(grammar agent returned nothing — read docs/schema/railroad.md directly)'

log('grammar rewritten; fanning out across 27 files')

phase('Rewrite')

const FILES = [
  ['docs/schema/types.md', 'Primitives, domain types, sum types, Moment/Behavior, Duration/Period/Grain, absence types, is, Secret, Hashed, Encrypted. NEW: the `File` type (media type, Read-readable, chunked as Components, storage tiering a/b/c); the case-folding storage transform (`Canonical Text using <policy row>`, toCaseFold not toLower, NFC); `Text` length is a predicate not a type argument (`where maxLen 255`), and `maxLen`/`minLen` are used eight times in the corpus and defined nowhere — define them, and pin "255 characters" to a counting unit.'],
  ['docs/schema/tables.md', 'Table bodies, fields, defaults, candidate keys, ordering, FKs, sub-tables. NEW and large: a `:>` to a `Component` target is TABLE-VALUED (state the asymmetry against a non-Component `:>`, and that `= { … }` is sugar for a one-element literal); `Component` is 1:many and shrinks to one declared bit, cascade-vs-restrict, and stops occupying the replication-trait slot; a `Component` may declare `unique`; `:<` back-reference declarations; `SubTableRows` seeding a `Reference` sub-table; every added column declares a default (50-validation.md §B is the authority); RESTRICT on deleting a row with live inbound non-nullable references; re-keying is a delete plus an insert triggered by a change of shard root, with the gate.'],
  ['docs/schema/traits.md', 'Traits, inheritance, replication traits, Component, Keyless, Personal, Extensible, Queue/QueueState. NEW: `Component` stops occupying the replication-trait slot and becomes a marker (so `T : UserData, Component` is legal) meaning owned lifetime only; `LogData` gets two secondaries under the batched class (the "server-local" line is wrong); `Reference` rows live on the branch shard with cluster-wide tag allocation. The withdrawn `from A.name` rename clause is still the only documented way to resolve a trait field collision — that hole must be closed.'],
  ['docs/schema/queries.md', 'Filter, projection, joins, grouping, derived tables, mutation, historical queries, diff. NEW: `ProjItem` nesting; `TableLit` and multi-row insert decomposition; `` `elem` `` membership; `numbered <table>`; `limit` requires a total order extended by the candidate key and its semantics are absent from this file entirely — this file is its home; pagination is a cursor, no offset, no exact total; write-through admissibility restated per nesting level. Also: `id` is used in mutation examples and does not exist, and `"uuid-..."` is not the DataId rendering.'],
  ['docs/schema/aggregates.md', 'Aggregate functions, mergeable aggregates, retain chains, log retention. NEW: `drop` is a chain terminal not a step (every example here is currently illegal); a rollup column added to a live chain is typed `T | NotRetained` AND defaults to `NotRetained`; `retain` on `UserData` stands and is rare; the `cutoff` in the branch example is bound nowhere; `truncateTo` has no signature; generated level tables have no name, trait, or placement.'],
  ['docs/schema/evolution.md', 'Redeclare, rename, retype, deprecate, prune, split, merge, ADT extension, visibility. NEW and central: every added column declares a default — this file carries the three contradictory statements about what an added field reads on old rows (the default / NotFound / NotGiven) and must now carry the settled rule; nothing is backfilled, the value is computed at read from the schema node that added the field; a field path is bound to its declared type for the life of the table (re-declaring identically is an un-deprecate, a different type is rejected); the split example is rejected by the root rule twelve lines below it.'],
  ['docs/schema/constraints.md', 'assert, path constraints, presence and absence, access control. NEW: the assert grammar is fixed, so `not $ <query>` and `||` between queries now parse — make the examples match whatever railroad.md settled; a standalone assert may carry a query, which is what lets a derived table have one; `authed_client` stays rejected and the reason is restated once here with client scope pointing at auth.md.'],
  ['docs/schema/functors.md', 'The four functor kinds, order of operations, enforcement modes. NEW: the order of operations omits defaults entirely and must not; step 3 decides per field from a mode declared per predicate; the FK functor signature is wrong for every `Reference` FK (it resolves a tag, not a DataId); the event signature `a → EventRef` cannot express the false-to-true rule; "defined as rows in system tables" names a table that does not exist.'],
  ['docs/schema/functions.md', 'Scope, the effect ladder, auto-wrapping, function types, function-valued columns. NEW: the effect ladder types a field default as `Tx`, which the mandatory-default rule contradicts — 50-validation.md §A resolves it (the cell is what the POSITION admits, not the index a default carries; the effect is inferred from the body and checked against the position). Also: `insert` is used as a statement keyword and is neither reserved nor a production; `system.config.AllowedPackage` is referenced and the namespace does not exist; `Text.Regex.TDFA` as an always-available import defeats the `=~` provenance restriction; POSIX character classes are now rejected in `=~` patterns.'],
  ['docs/schema/documents.md', 'The Doc type, shredding, key interning, key shape rules, demotion. NEW: `Doc` nodes are Components and a `:>` to a Component is now table-valued — check every claim here against that; `table app.log.RequestBodyKey : DocKeys` has no body and does not parse; `key` and `name` are reserved words used as field names; the spill table has no FK so under the key-rooting rule it is itself a shard root; "the shredded form is derivable / a materialized view" is false because interning is a schema commit and is order-dependent.'],
  ['docs/schema/templates.md', 'Text with holes, cardinality as control flow, using, escaping by type. NEW: `{{ money self.total }}` cannot parse because a Hole admits only a Query and a function application is not a Source; this file restates the template EBNF under a different start symbol and calls itself "the whole grammar" — railroad.md is the home, link to it; a template is never bound to a type or table so `self` has nothing to resolve against; `Html` is declared nowhere.'],
  ['docs/transaction-graph.md', 'Append-only DAG, branches and tags, shards, DataId, component ordinals, PhysicalLocator, virtual columns. NEW: `system.graph.Transaction` is declared, and a re-key records itself on the transaction node typed over `head_index` keys; `LogData` gets two secondaries (the "server-local by default" paragraph is wrong); a `Component` `:>` is table-valued; the stale reference to LogSegment\'s removed `server` field; graph nodes have two incompatible identity schemes (DataId and an undefined content-addressed hash); `system.VersionRef` does not compile and declares no trait; the clock-regression clamp is process-local so a crash re-issues used DataIds.'],
  ['docs/storage.md', 'Append-only log, LMDB indexes, Cap\'n Proto, zero-copy, materialization, scrubbing. NEW: a materialized view is a derived table in ordinary storage — no second engine, and neither LMDB-as-view-store nor SQLite; derived extents and arrangements; an index is the degenerate materialized view; `File` chunk layout and the storage tiering decision; the log frame has no checksum field though scrub and `verify shard` require one; the zero-copy path has no reader-visibility discipline while relocation and scrub rewrite bytes under live mmap readers — cite the known hazard rather than ignoring it.'],
  ['docs/distribution.md', 'Server roles, range tree, replication, schema and constraint shards, cross-shard transactions, bulk mutations, splits, durability, cold shards, geo-diversity. NEW: elevation is automatic and failback is operator-initiated, with fencing epochs and a two-of-three ACK; `LogData` two secondaries batched, with geography relaxed for `system.logs.HttpRequest` only — via `system.shards.DurabilityPolicy`, which is named here and never declared; the range tree has no table, no fields and no key and must get them; the cross-shard protocol has no validation phase at commit and "the only outcome is an abort" is backwards; auth is now `UserData` sharded by user, and any role holder can authenticate.'],
  ['docs/tech-stack.md', 'Library and format decisions, with the OQ and spike that settled each. NEW: regex stays `regex-tdfa` with POSIX character classes rejected at schema commit rather than switching engines — record the reasoning, including that the classes are enumerated into a `Set Char` and transitions are an `IntMap` per code point, so a Unicode-correct class would be ~132k transitions per DFA state; this file is the only one still calling the physical address `RowId`; it restates the whole process topology it tells the reader to look up elsewhere.'],
  ['docs/dynamic-loading.md', 'GADT DSL + Data.Dynamic, process topology, generation swap, ceilings. NEW: the 11 µs LMDB read is cited to a spike section that failed to run — check `${ROOT}/spikes/storage/output.txt` and `${ROOT}/spikes/capnproto/output.txt` and cite whichever actually recorded it; the regex ceiling is closed differently now.'],
  ['docs/events.md', 'Event scheduler, trigger forms, queue tables, priority, handlers, backoff, repair queues. NEW and large: `every … where <cond>` is documented as both a per-tick row filter and a false-to-true condition with no rule to tell them apart, and under the stated rule connector polling fires exactly once; the scheduler writes the `QueueState` field that three documents reserve to the handler; `TriggerState` is an append-only LogData table holding a bit that must be overwritten, with no retain chain; `BackoffState` stores measured counters in a `Configuration` table; `SchedulerLimit` declares no candidate key; "adding a handler requires a schema-daemon restart" — there is no schema daemon; `urgent, normal, background :: Priority` uses syntax the grammar does not admit; the flagship `on … emit` example enqueues a nested anonymous payload record.'],
  ['docs/integrity.md', 'Nonconformance, enforcement modes, violations table, admin reporting, erasure and scrubbing. NEW: `Violation` is described as a materialized view, a stored LogData table, AND something you insert into by hand — pick one and say so; `Violation.state` is mutated although LogData is append-only with one stated exemption, so either the exemption is not one field or this table is wrong; the retention chain branches on `state`, which changes after the row is written while the branch is pinned at write time; `reason` is a reserved word used as a field name; a violation on a re-keyed row stays in the source shard and resolves forward.'],
  ['docs/connectors.md', 'External ingestion, sync protocol, conflict resolution, schema auto-discovery. NEW and large: rewrite both pseudo-schema blocks as real DataCode declarations (they use `Enum(...)`, `UUID`, `UUID?` and `_ms Int`); drop `connector_id` for a `:>`; one connector kind with a per-connector GTID dialect covering MariaDB and MySQL, whose schemes are incompatible; the position is a set of rows not a scalar; detect-and-verify the dialect at connect; an explicit seed origin `Streamed | Snapshot | Reseeded Text`; **re-seed from state is the recovery path** — diff-and-apply not rewrite, the snapshot must be complete per table or deletes leak, and a re-seed loses intervening event-functor firings, which is a per-queue Configuration choice; `binlog_row_image=FULL` is NOT required and `MINIMAL` works given a source-PK index; GTID is an optimization rather than a correctness prerequisite; the `Connector` table is declared three times across two files with three field sets.'],
  ['docs/auth.md', 'Token types, credential storage, envelope encryption, key custody, access control functors. NEW and large: `system.auth.Client` (Reference, the kind — Storefront/AdminIde/Cli/Server), `Registration` and `ClientToken` as separate tables, server unified as a Client that cannot be narrowed; hostname is an issuance-time selector only, never an authorization input; `authed_client` stays rejected; **auth is `UserData` sharded by user** — Credential, Registration, ClientToken and Contact rooted at User, login is a shard-directory lookup, any role holder can authenticate, and issuing a session must not be a row write; `Challenge` is LogData and therefore not in the user\'s shard, which needs resolving; `preHashed`/`unsafeHashed` for admitting a foreign digest, with a verification-only policy; `matches` has its arguments in the opposite order from every call site; the delivered one-time code has no path from generation to delivery; a WebAuthn public key cannot be stored `Hashed`.'],
  ['docs/cli.md', 'REPL, invocation, admin and DR commands. NEW: the `show` family gains `ReportClause*` and a `system.config.PageSize` default with `100 of 100+`; **a truncated result prints its own pasteable continuation** carrying the `at` peg, the effective ordering tuple including the key tiebreak, only when truncated, not in csv/raw, and degrading to the expanded form on mixed sort directions; `ShardRef` and DataId ranges; `cancel`; `export`; `erase row` uses a marker railroad.md refused to reserve; the `split shard` example uses a uuid and DataIds are not uuids; `--host db.example.com` does not parse; DataId literals here are 18 characters where the rendering is 20.'],
  ['docs/ide.md', 'Admin IDE — ER diagram, sidebar, functor editor, integrity panel. NEW: the Open Questions list is off by one from OQ-023 onward and cites an ANSWERED OQ as open; OQ-022\'s answer is stated as settled fact in Purpose and listed as open in the same file; the sidebar shows lowercase plural table names against the capitalization rule; functor kind 3 is still called "path equivalence".'],
  ['docs/api.md', 'Route registration, versioning, HTTP dispatch, request logging. NEW: an octet-stream response mode for `File`, with media type, Range requests and ETag — the content-type table currently has nothing for "the bytes"; `methods : [HttpMethod]` uses list syntax no production admits; `server_id`/`received_at` re-create stored columns the virtual columns already project; `TableRef`/`FormatRef`/`ServerId`/`TokenId`/`HttpMethod` are undeclared; the authentication rule requires a client token specifically and thereby forbids the login and webhook-ingress routes from existing; monotonic integer versions contradict OQ-026.'],
  ['docs/api-and-rendering.md', 'Content-type dispatch, HTML rendering, themes, information density. NEW: the binary format is called TBD and OQ-003 settled it as Cap\'n Proto with spike evidence; absence maps to `NOT_FOUND`/`Maybe` and collapses the whole Null family to JSON null; field-level access hiding contradicts row-scoped redaction; PageRank is defined as in-degree and total degree with determinism unstated; density windowing is inverted; rendering a Timestamp as relative time needs a clock the effect ladder forbids.'],
  ['docs/namespaces.md', 'Namespace tree, visibility levels, namespace ACL. NEW: `namespace app.commerce` is a statement that does not exist, is not reserved, and contradicts "no explicit creation syntax" in the same file; the tree names system tables in snake_case, lists two tables the event model deleted, keeps a top-level `reference/` branch annotated with replication behaviour, and shows connector namespaces for sources marked NOT DOING; name resolution inside a schema file is unspecified and `ImportDecl`\'s ModuleName is undefined; visibility is called "purely a presentation hint" while the same file treats it as authorization.'],
  ['docs/vision.md', 'What DataCode is, why, differentiators, non-goals. NEW: data elements are said to be the objects of the schema category — tables are; the core model is defined in terms of `view`, which the language withdrew; the differentiator table should acknowledge CQL/FQL as the closest prior art (see review/40-bibliography.md §1).'],
  ['docs/category-model.md', 'The governing monad, four functor kinds, path equivalence, transparency, absence. NEW: it states the functor representation OQ-001 corrected (a Haskell function encoded by typeclasses); path constraints are "not applied at query time" eighteen lines before the same file says the access variety runs on read; access control is described as pruning individual morphisms where the normative docs define whole-row redaction plus subtree grants; the closed-form behavior class is presented as settled where OQ-034 records it open; the denotative claim is stated in one coordinate where the design uses two (a query is pegged to a commit node AND a sample moment) — see review/40-bibliography.md §2; "access rules can be checked statically for consistency and completeness" is claimed here and in three other places, is not what the spike computes, and completeness is not a defined property.'],
]

const rewrites = await parallel(FILES.map(([f, brief]) => () =>
  agent(`${COMMON}

## THE CORRECTED GRAMMAR

\`docs/schema/railroad.md\` has already been rewritten in this pass. **Read it now** — it is the
authority for every example you write. For reference, the agent that rewrote it reported this as the
final grammar:

${grammarText.slice(0, 14000)}

## YOUR FILE: ${f}

${brief}

That brief is not exhaustive — it names the largest items. Your file's full finding list is in
review/10-findings.md as described above, and 00-report.md's decisions may touch your file in ways
the brief does not mention. Work through both.`,
    { label: `rewrite:${f.replace(/^docs\//, '').replace(/\.md$/, '')}`, phase: 'Rewrite', schema: RESULT_SCHEMA })
))

const done = rewrites.filter(Boolean)
log(`${done.length}/${FILES.length} files rewritten; ${done.reduce((n, r) => n + (r.findings_fixed || 0), 0)} findings fixed`)

phase('Indexes')

const indexBrief = `${COMMON}

## THE CORRECTED GRAMMAR

${grammarText.slice(0, 10000)}

## WHAT THE OTHER AGENTS DID

Twenty-eight files have just been rewritten in this pass. Their reports:

${JSON.stringify(done.map((r) => ({ file: r.file, structural: r.structural_changes, redundancy: r.redundancy_removed, oqs: r.new_open_questions, unresolved: r.unresolved })), null, 1).slice(0, 60000)}
`

const indexes = await parallel([
  () => agent(`${indexBrief}

## YOUR FILE: docs/open-questions.md

You own the decision record. Three jobs:

1. **Record every decision from 00-report.md's "Decisions taken" as a bullet under the OQ that
   covers its area.** CLAUDE.md is explicit: a settled decision belongs normatively in docs/ AND as
   a bullet under the existing OQ. OQ-005 is the decision record for schema syntax and will take
   most of them. Do NOT mint a new OQ number for a decision that was never in doubt.
2. **File the genuinely new open questions.** Collect them from the other agents' reports above and
   from review/50-validation.md §E item 9 and review/90-questions.md. The known ones: general
   transaction-graph reclamation (deliberately late, a background process); whether a re-key
   participates in merge reconciliation as a key alias (blocked on merge semantics being designed);
   and anything the rewrite agents surfaced. Number them sequentially from the highest existing.
   **Several designers each claimed "OQ-038" — it can only be spent once.**
3. **Fix the file's own defects**: answers that live only here and were never written into the
   normative doc; entries describing superseded behaviour; open questions written as settled;
   entries filed under the wrong urgency heading; OQ-030 housing retry policy in a table the same OQ
   removes 69 lines later.

Also close out what the review settled: OQ-006 (elevation automatic, failback operator-initiated),
OQ-008 (Client/Registration split), OQ-019, OQ-025, and narrow OQ-033/OQ-034/OQ-035 where the review
moved them.`, { label: 'index:open-questions', phase: 'Indexes', schema: RESULT_SCHEMA }),

  () => agent(`${indexBrief}

## YOUR FILE: docs/README.md

The entry point and the index of every document. Verify the table is complete and accurate against
the actual file list, that every link and anchor resolves, and that each row's "Covers" column
matches what the file now contains after this pass. Add anything new the rewrite introduced (the
\`File\` type, \`system.graph.Transaction\`, the \`Client\`/\`Registration\` split) to the right row's
description. Keep the Spikes table accurate.`, { label: 'index:readme', phase: 'Indexes', schema: RESULT_SCHEMA }),

  () => agent(`${indexBrief}

## YOUR FILE: docs/schema/README.md

Design philosophy, visibility layers, and the notation conventions the rest of the language assumes:
capitalization, \`:\` versus \`:>\`, clause order, \`where\`, termination and layout, addressing
validations.

Specific defects: it cites the withdrawn \`from A.name\` clause as the way to reference an inherited
field; "visible only to admin tokens" invents a token type and a role check the design rejected;
validations are addressed as \`minLen12\` everywhere but declared as \`minLen 12\`; the clause order
must now admit \`SubTableRows\`; \`:<\` needs a line beside \`:\` and \`:>\`; and the self-hosting
principle's table of system concerns should match the tables that now exist.`, { label: 'index:schema-readme', phase: 'Indexes', schema: RESULT_SCHEMA }),
])

phase('Verify')

const verify = await parallel([
  () => agent(`You are verifying a completed documentation rewrite of **DataCode**. Repository root:
${ROOT}. All 31 files under docs/ have just been rewritten to conform to docs/schema/railroad.md.

**Do not edit anything.** Report only.

TASK: grammar conformance sweep. Extract every fenced code block and inline snippet from all 31
files. For each that is DataCode schema, query, CLI or REPL syntax, check it derives from the EBNF in
docs/schema/railroad.md. Name the production for each conforming one; for each failure, quote the
snippet, name the production that fails, and say what it should be.

Also check: reserved words used in positions no production admits; words the file lists as
unreserved being used as though reserved; violations of the "constraints not expressible in the
grammar" bullets; capitalization convention; \`:\` versus \`:>\` versus \`:<\`.

Report the pass rate and every failure.`, { label: 'verify:grammar', phase: 'Verify' }),

  () => agent(`You are verifying a completed documentation rewrite of **DataCode**. Repository root:
${ROOT}. **Do not edit anything.** Report only.

Three sweeps over docs/:

1. **Links and anchors.** Extract every markdown link mechanically with grep. For each, does the
   target file exist, and does a heading in it slugify to the anchor? Report every dangling one.

2. **Decision coverage.** ${ROOT}/review/00-report.md's "Decisions taken" section holds ~30 settled
   decisions. For each, grep docs/ and confirm it is now stated normatively somewhere, in exactly one
   home, and that no file still describes the superseded behaviour. Report any decision that did not
   land, and any place the old behaviour survives.

3. **Residual contradictions.** Check the highest-value cross-file invariants specifically: whether
   \`LogData\` replication is now described consistently everywhere; whether \`Component\` \`:>\`
   table-valuedness is consistent; whether append-only exemptions are now stated consistently;
   whether any file still says \`system\` is a shard type; whether \`id\`, \`"uuid-..."\`, or 18-character
   DataIds survive anywhere.

Report findings with file:line. Be specific.`, { label: 'verify:consistency', phase: 'Verify' }),
])

return {
  grammar,
  rewrites: done,
  indexes: indexes.filter(Boolean),
  verify: verify.filter(Boolean),
}
