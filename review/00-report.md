# DataCode design review — 2026-08-28

A deep pass over all 31 files in `docs/`, plus designs for the sixteen syntax and architecture
changes you asked for. Two multi-agent runs produced it: a 31-agent audit (nine document clusters
× two lenses, four cross-cutting sweeps, one adversarial verifier per cluster) and a 33-agent
design pass (one designer and one adversarial critic per question, plus an integrating grammar
reviewer). Every audit finding below survived a verification pass whose default was to refute it.

## Contents

| File | Holds |
|---|---|
| `00-report.md` | This report |
| `10-findings.md` | All 640 verified findings, grouped by file, with evidence and a fix each |
| `20-syntax-decisions.md` | The sixteen questions: recommendation, pushback, alternatives, critique |
| `30-integrated-grammar.md` | The conflict-resolved EBNF delta across all sixteen, plus the phase plan |
| `40-bibliography.md` | Annotated bibliography, organised by the design claim each source bears on |
| `90-questions.md` | What I need from you |

## Decisions taken

Four questions were put to Chris on 2026-08-28 and answered. They are recorded here because each
one changes several of the sixteen items below, and because two of them settle a Phase 0 blocker.

### A `:>` field to a `Component` sub-table is table-valued

`headers :> RequestHeader : Component { … }` holds **all** of that request's header rows, in
`ordinal` order. Consequences, each of which needs writing down:

- `tables.md:421-429` is correct as written. **Do not rewrite that example** — several proposals
  wanted to, and they were wrong.
- `queries.md:234-236`'s "the same construct as an inline component sub-table" becomes true rather
  than aspirational.
- **1:many inline declaration already exists** for owned children. `:<` (item 16) therefore shrinks
  to the case that actually needs it: children that are *not* owned — true linking tables, and
  children with independent lifetime.
- The asymmetry must be stated in `tables.md`: a `:>` whose target carries `Component` is
  table-valued; a `:>` to any other table is single-valued and wraps one `DataId`. This is what
  resolves `tables.md:326` against `traits.md:199` — a component has no `DataId`, so the field
  cannot be wrapping one, and the parent-prefix range scan is what it denotes instead.
- `settings :> Settings : Component = { theme = Dark }` (`tables.md:441-446`) is a 1:1 component, so
  `= { … }` becomes sugar for a one-element literal. State it, or the default clause and the field
  type disagree.
- A table-valued field is rejected in a key, in `unique`, in `order by`, and in `==`, and is excluded
  from `*` unconditionally.
- `ordinal` stays on **stored** components and is withdrawn from nested tables produced by `group`
  or by a projection sub-nesting — nothing was inserted in any order there.

### Membership is `` `elem` ``

`` status `elem` [Pending, Shipped] ``. `in` stays reserved for `let … in` and gains no second
meaning. One production is added — `TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'` — shared with
the multi-row insert of item 13.

One refinement that falls out and improves both items: **the multi-field form uses a `RecordLit`,
not a tuple.** `{ customer = c, order_num = n } `elem` <table>` reuses a production that already
exists, needs no `TupleLit`, binds by name rather than position, and makes the element shape
identical to the one the insert literal uses. One element shape everywhere.

### The client kind is `Client`; the registry is a separate table

Chris's reading is the right one and it dissolves the naming problem: the two things were being
conflated. Split them and no qualifier word is needed.

| Table | Trait | Holds |
|---|---|---|
| `system.auth.Client` | `Reference` | The **kind** — `Storefront`, `AdminIde`, `Cli`, `Server`. Low cardinality, schema, replicated everywhere. Schema-level reach attaches here. |
| `system.auth.Registration` | `Configuration` | One row per **registered device or installation**: `:> Client`, `:> User`, plus the per-platform identifiers. |
| `system.auth.ClientToken` | `Configuration` | The bearer credential issued at registration, `:> Registration`. |

`Server` is a `Client` that cannot be narrowed, which is the unification asked for. OQ-008 narrows to
"which identifiers must each platform supply on `Registration`". The hostname is an **issuance-time
selector** only: at request time it is checked for equality with the origin recorded on the
registration, never consulted to decide reach. Getting that backwards lets a browser reach
`system.auth` by sending `Host: ide.example.com`.

`authed_client` stays rejected. Schema-level reach is what a `Client` row decides; row-level
filtering is what an assert decides; admitting the client into an assert body would put one decision
in two places, and the critic found three fail-open paths in the version that tried.

### The type is `File`, not `Blob`, and DataCode is the origin

DataCode serves the CSS and JS. No external CDN. Two consequences that change the design as
proposed:

- **`File` carries a media type, not just octets.** It has to, because the HTTP response needs one
  and `api.md` currently has no octet-stream response mode at all. That mode is now required work.
- **`File` content must be readable in `Read`, not only in `Effect`.** The motivating case is a
  stylesheet that is both served at a URL *and* inlined into rendered HTML for email, where mail
  clients demand inline CSS. A template hole is `Read` (`templates.md:128-130`), so an
  `Effect`-only `File` cannot serve the second path. The read is bounded by a
  `system.config` size cap; above it, the value is reachable only through the streaming handler.

Still open, and asked below: "the decision to store outside DataCode should be field specific" needs
one more turn, because storing bytes outside the graph while DataCode remains the origin is a real
departure from *the log is the graph* and the cost depends on which of three things is meant.

## Clusters

The corpus divides into nine clusters. Coupling runs left to right; `railroad.md` and
`open-questions.md` are cited by every one of them.

| Cluster | Files | Findings |
|---|---|---|
| Foundations | `README.md`, `vision.md`, `category-model.md`, `schema/README.md` | 30 |
| Schema core | `schema/railroad.md`, `types.md`, `tables.md`, `traits.md` | 79 |
| Query and evolution | `schema/queries.md`, `aggregates.md`, `evolution.md` | 68 |
| Functors and functions | `schema/functors.md`, `constraints.md`, `functions.md` | 62 |
| Documents, templates, namespaces | `schema/documents.md`, `templates.md`, `namespaces.md` | 71 |
| Engine | `transaction-graph.md`, `storage.md`, `distribution.md` | 76 |
| Runtime | `tech-stack.md`, `dynamic-loading.md`, `events.md` | 79 |
| Interfaces | `cli.md`, `ide.md`, `api.md`, `api-and-rendering.md` | 74 |
| Ops and security | `auth.md`, `integrity.md`, `connectors.md` | 67 |
| Cross-cutting sweeps | grammar conformance, links and anchors, OQ drift | 134 |

## Health verdict

The *decisions* are in good shape. `open-questions.md` is a genuinely strong decision record, the
load-bearing invariants hold up under attack, and the categorical framing is doing real work rather
than decorating an ordinary design — the structural reading of an assert's variety, the missing
`Effect → Tx` lift, and the key-declaration-is-the-sharding-declaration rule are each the kind of
move that pays for the theory.

What has drifted is the **mechanical layer**. `railroad.md` calls itself the single source of
syntax truth, and it has fallen behind the prose it governs: 76 verified findings are a snippet that
does not derive or a production that contradicts its own stated constraint, and several of those are
the *normative* spelling of a settled decision. The defects are concentrated rather than diffuse,
which is good news — most of it is one afternoon of grammar repair.

By category, over the 640 verified findings: 212 contradictions, 152 underspecified, 67
theory errors, 53 examples that do not parse, 49 redundancies that have drifted, 42 naming drifts,
24 OQ drifts, 23 grammar mismatches, 15 style, 2 broken links, 1 type error. 37 are blockers.

Second-largest is **system tables and types that are used but never declared**. Third is
**redundancy that has already drifted**: eleven rules are stated normatively in two or three files
and the copies now disagree.

## The eight structural defects

Each of these would have cost a rewrite if it were found during implementation rather than now.

### 1. The assert grammar cannot express asserts

Four separate failures, one root cause: `AssertBody ::= Expr | Query` admits a query *or* an
expression, never a query inside an expression.

- **`not $ <Query>` has no parse.** `NotExpr ::= 'not' '$' Expr`, and `Expr` reaches `Query` only
  through the `'(' Query ')'` atom. `assert payable { not $ self >< Account >< Suspension … }`
  (`constraints.md:147`) is the normative spelling of an absence assert and it does not derive.
- **A bare `Query` cannot be an operand of `||`.** OQ-005 makes `||` inside one assert the
  *mandatory* spelling for access alternatives — "alternatives are `||` inside one assert rather
  than several asserts" — and `constraints.md:83-87` and `auth.md:108-112` both write it. No
  production admits it.
- **`StandaloneAssert ::= 'assert' QName '{' Expr '}'` admits only `Expr`.** A binding has no body,
  so standalone is its *only* form — which means no derived table can carry a presence or access
  assert at all. `auth.md`'s `secondFactorForAdmins` is exactly this shape.
- **`Binding ::= Ident` forbids a namespaced derived table.** `system.auth.ServiceAccount = …`
  appears in `auth.md`, `namespaces.md`, `aggregates.md` and `open-questions.md`, and parses in
  none of them. `TableDecl` uses `QName`; `Binding` should too.

Fix: `AssertBody ::= Expr`; add `'(' Query ')'`-free query atoms by admitting `Query` at `Atom`
under a non-emptiness coercion, or — cheaper and more Haskell-shaped — lift the existing
"a `Query` in boolean position asserts non-empty" rule from `AssertBody` to *every* `Bool`
position. That one change fixes all four and is also the best available answer to the `in`
operator (below).

### 2. Append-only has four exemptions, not one

"The `QueueState` field is the one exemption from append-only in the whole system" appears in
`traits.md`, `events.md` and `railroad.md` as a selling point. Three other fields are mutated:

| Field | Where | Mutated by |
|---|---|---|
| `system.integrity.Violation.state` | `integrity.md:209,313` | an ordinary operator mutation |
| `system.auth.Challenge.state` | `auth.md:149` | consuming the challenge |
| `system.events.TriggerState.held` | `events.md:186` | the scheduler, every tick |
| `Queue.scheduled_at` | `events.md:231` | retry backoff, against the queue's own rule 4 |

`TriggerState` is the worst of them: a `LogData` table holding one bit that must be overwritten per
`(trigger, row)` per tick, with no `retain` chain, so it is also unbounded.

Related and equally load-bearing: `system.integrity.Violation` is described as **a materialized view
over a query** (`integrity.md:53-58`), as **an ordinary `LogData` table sharded with its subject**
(`:258`), and as a table you **insert into by hand** (`:317`). Three authorities for one table.

### 3. `id` does not exist

Six documents filter, update and project on an `id` column. The virtual columns are `created_at`,
`origin_server`, `updated_at`, `ordinal` and `grain` — there is no `id`. Compounding it,
`"uuid-..."` is used as its value in `queries.md` while a `DataId` renders as 20 characters of
Crockford base32, and `cli.md`'s identifiers are 18 characters where `transaction-graph.md` and
`api.md` use 20.

### 4. Withdrawing `from` left a hole

`SourceClause` was withdrawn with `rename from`, because a projection expresses a rename. But the
*other* user of `from` was resolving a multiple-inheritance field collision by rename
(`traits.md:64`, restated at `schema/README.md:278`), and a projection cannot appear in a
`TableBody`. There is now no way to keep two colliding trait fields under different names.

### 5. `retain` chains contradict their own constraints

`drop` is a `ChainStep`, so it is subject to "every later step must carry `by`" and to "`as` is
required if the chain has more than one step". Every `, drop`-terminated chain in the repo —
including the one in `CLAUDE.md` — therefore violates both. `RetainDecl` needs `Chain ::= ChainStep
(',' ChainStep)* (',' 'drop')?` with `drop` as a terminal rather than a step.

### 6. Routing has no table

The **range tree** decides which server serves which key range and is invoked as authoritative in
three documents. It has no table name, no fields, no key, and no type for its heterogeneous bounds.
The **cluster shard directory** (`username → DataId → shard`) is invoked as free by three documents
and has no root, no primary, and no registration protocol. `system.auth.Grant` is written to by two
CLI commands and declared nowhere; so is `system.shards.DurabilityPolicy`.

Types used in normative declarations and defined nowhere: `TypeRef`, `TableRef`, `FormatRef`,
`ServerId`, `TokenId`, `HttpMethod`, `Html`, `NamespaceRef`, `TemplateBody`, `ChallengeCode`.
`api.md:43` also writes `methods : [HttpMethod]`, a list type the grammar has no production for.

### 7. `LogData` replication contradicts itself

`transaction-graph.md:117` and `traits.md:104` say `LogData` is server-local and does not replicate
to peers. `distribution.md:110-136` gives it two ACKing secondaries under a batched durability
class. Both are stated normatively. The batched reading is almost certainly the intended one — it is
newer and better argued — but `system.logs.HttpRequest` is described as per-server in three places
that depend on it.

### 8. The connector document is written in a different language

`connectors.md`'s two schema blocks use `Enum(...)`, `UUID`, `UUID?` and `_ms Int` — a nullable
marker, a type DataCode does not have, and a construct the project's first differentiator rejects.
You flagged this; it is worse than you said. `sync_status` is not merely a non-ADT enum, it is a
mutable column on a `LogData` table, and `connector_config` duplicates
`system.connectors.Connector`, which is itself declared twice more (in `events.md` and `cli.md`)
with three different field sets.

## Theory notes

Full citations in `40-bibliography.md`. Six claims need adjusting.

- **`vision.md:5` says data elements are the objects of the schema category.** `category-model.md`
  and Spivak say tables are, and instances are set-valued functors *on* the schema. Correct
  `vision.md`.
- **Spivak & Wisnesky's FQL requires key generation** for Σ-style migration. That is in direct
  tension with `queries.md`'s "keys are computed, never declared". Say which of Δ, Σ, Π a DataCode
  coercion is — the answer is almost certainly Δ (pullback along a schema morphism), which is the
  one that needs no key generation, and saying so strengthens the claim rather than weakening it.
- **Johnson & Rosebrugh give the exact criterion for a writable derived table**: a view update has a
  universal solution exactly when the view functor is a Grothendieck opfibration. That is sharper
  than the three conditions in `queries.md:543-550` and it is the categorical statement of the same
  fact. Cite it; it is the strongest available support for the write-through design.
- **"Access rules can be checked statically for consistency and completeness"** appears in four
  places, is not what `spikes/functor-dsl` computes, and no OQ tracks it. Consistency (no
  contradiction) is decidable for the anchored fragment; *completeness* of an access policy is not
  a defined property. Weaken the claim or define the property.
- **The denotative claim is stated in one coordinate and the design uses two.** A query is pegged to
  a `(commit node, sample moment)` pair, so DataCode is denotational in schema-position *and* in
  time. `category-model.md:97-99` states only the second. This is a strengthening, not a defect —
  Elliott's discipline applied twice is a better story than applied once.
- **The zero-copy read path has no reader-visibility discipline.** Relocation and scrub rewrite
  bytes under live `mmap` readers with nothing stated about it. Crotty et al., "Are You Sure You
  Want to Use MMAP in Your DBMS?" (CIDR 2022) is the standard reference for exactly this hazard and
  should be cited and answered, not ignored.
- **The prepared-node protocol has no validation phase at commit.** Neither participant re-checks
  its read set before the commit node lands, and "the only outcome is an abort" is backwards —
  without a re-check the outcome is a *lost* conflict, not an abort. Gray & Lamport's
  consensus-on-transaction-commit is the right frame.

## The sixteen requested changes

Detail and full argument in `20-syntax-decisions.md`; the conflict-resolved grammar is in
`30-integrated-grammar.md`. **Net reserved-word change across all sixteen: −1.**

| # | Your ask | Verdict | Cost |
|---|---|---|---|
| 1 | Large files in the database | **Adopt a `File` type; DataCode is the origin; `Read`-readable** | 0 productions, 0 words |
| 2 | `Text 255` / `Text 1 255` | **Reject the syntax; use `where maxLen 255`** | 0, 0 — the feature exists |
| 3 | Client token types, `authed_client`, unify with server | **Adopt unification; reject `authed_client`; `Client` + `Registration`** | −2 words |
| 4 | Regex templates, alnum arguments, the library | **Keep the restriction, fix its stated reason; defer parameterisation** | 0, 0 |
| 5 | `in` operator with array and query RHS | **Spell it `` `elem` ``; multi-field is a `RecordLit`** | 1 production, 0 words |
| 6 | Kill long-running queries | **Adopt `cancel`; defer the `Ephemeral` trait it arrived with** | 2 productions, 1 word |
| 7 | Pre-hashed password ingest | **Adopt `preHashed <policy> "<digest>"`** | 0, 0 |
| 8 | CLI: shard split, pagination, DataIds, split-brain | **Three of four adopted; `split shard` was never removed** | ~6 productions, 0 words |
| 9 | Connectors: GTID, syntax, `connector_id` | **All three right; GTID needs no library fork** | 1 changed, −2 words |
| 10 | LMDB or SQLite for materialized views | **Neither — a view is a derived table in ordinary storage** | 0, 0 |
| 11 | Row-number column; recursive query | **`numbered <table>`; defer recursion** | 0, 0 |
| 12 | Reference autoinc; MariaDB autoinc | **Premise half right; key shadows on the source PK** | 0, 0 |
| 13 | Multi-table insert from virtual tables | **Adopt as a table *literal*, `[ {…}, {…} ]`** | 3 productions, 0 words |
| 14 | Automatic nesting, JSON in/out, dump to file | **Adopt; nest in the projection, not a `nest` clause** | 3 productions, 0 words |
| 15 | `Default` as an injected type | **Reject; and the free replacement does not fully cover it** | 0, 0 |
| 16 | `<:` backreference for linking tables | **Adopt, spelled `:<`; now scoped to non-owned children** | 1 production, 0 words |

### Where I am pushing back

**Item 2 — bounded `Text`.** `Text 255` and `Text 1 255` are *already grammatical*
(`Variant ::= QName TypeArg*`, `TypeArg ::= QName | Literal`), so this is not a grammar question.
It is a question of whether a length cap is a **type** or a **validation**, and it must be a
validation, for a reason that decides it: a type-level cap makes over-length connector data
*untypeable*, and `integrity.md`'s whole ingestion posture is that connector-sourced rules default
to `monitor` so one bad row cannot halt a binlog. A cap you cannot set to `monitor` converts a data
problem into an outage. `where maxLen 255` is already used in six files. What is genuinely missing:
`maxLen` and `minLen` are used eight times and **defined nowhere**, and "255 characters" has never
been pinned to code points, bytes, or grapheme clusters. Fix those two things and the feature ships
with no syntax at all.

**Item 5 — `in`.** `in` is already reserved by `let … in`, and admitting it as a comparison operator
creates a real ambiguity: `let x = a in b` cannot be told from a `let` whose binder body is a
membership test. The proposed disambiguation ("the first `in` at bracket depth 0 closes the
binder") does not count `let` nesting and breaks `let a = let b = 1 in b + 1 in a * 2`, which parses
today. DataCode already has backtick infix at Haskell's fixity, and `Data.List` is auto-available,
so `` status `elem` [Pending, Shipped] `` costs one bracket-literal production and nothing else.
Your multi-field ask is served by a tuple LHS, not an array LHS — a list is homogeneous and a row is
not.

**Item 8 — `split shard`.** You are remembering the withdrawal of the `split`/`merge` *table*
statements (OQ-005). `split shard … at key` is alive and OQ-007 is ✓ ANSWERED keeping it: a
`UserData` split moves write authority, so it cannot be automatic. You are directionally right about
something else though — `split shard` is quietly much narrower than the docs imply, because
splitting a shard with one root row yields a **shard group sharing a primary**, which splits storage
and read capacity but never write authority. The example on `cli.md:118` is broken regardless: it
uses a uuid, and DataIds are not uuids.

**Item 11 — row numbers.** You already have most of it and the missing piece is smaller than a
window function. `group` *nests* rather than aggregating away, so "position within a partition" is
position within the generated `rows` column — an ordinary table. Making `row_number` a virtual
column would be a correctness hazard, because virtual columns are key-eligible and a row number
changes when an unrelated row is inserted; a materialized view keyed on position would renumber its
whole extent on one insert. `numbered <table>` — an ordinary function returning the table plus a
generated `n` column, exactly as `group` generates `rows` and `diff` generates `before`/`after` —
costs no grammar, no reserved word, and takes its ordering as a parameter instead of reading it from
an enclosing clause. It gives you `lag`/`lead` by self-join on `n-1` and running totals; it does not
give you `rank`/`dense_rank` (they differ on ties) or frame clauses. **Recursion is a separate and
larger thing**: there is no recursive production anywhere, OQ-001 lists recursive types as an open
DSL ceiling, and transitive closure is famously not expressible in first-order relational algebra —
so it needs a real construct, and the obvious one (`via manager+`) is blocked on a tension you have
not settled: `tables.md:207` rejects a `Null`-derived variant in a key, and every tree root's
self-FK is nullable.

**Item 15 — `Default`.** The proposal is elegant and I recommend against it, on one argument:
`is` would have to carry two contradictory meanings. Take `phone : Phone | NotGiven = NotGiven`. If
`Default` wraps the value, `phone is NotGiven` is **False** on every defaulted row — the absence
check, which is the single most load-bearing thing in a language with no NULL, breaks silently. If
`is` sees through `Default`, the feature does nothing. The only escape is a constructor that `is`
treats specially, which is the magic-`access`-identifier defect OQ-005 already withdrew once.

Being straight about the replacement: the free answer, `Order where total.updated_at /= created_at`,
finds fields **changed since the row was created**. It does *not* distinguish "supplied at insert"
from "defaulted at insert", because both land at the row's `created_at`. If what you want is
genuinely "which values did a human supply", that costs a supplied-field bitmask on the row version,
and I would hold it until merge semantics are written — otherwise the mask reads all-ones after any
merge and the feature it is justified by does not work. Worth asking: was the `Default` keyword
actually about a *record-literal expression* — `{ total = default }`, meaning "write whatever the
schema's default currently is"? That is a much smaller thing and needs no type.

**Item 16 — `:<`.** Adopt it, but spell it `:<`, not `<:`. `<:` is the subtyping operator in type
theory, Scala, F<:, and Julia, and DataCode's `:` already *means* subtype — `type Email : Text` is
`Email <: Text`. So `comments <: Comment` is a well-formed sentence saying the wrong thing, which is
worse than a parse error. `:<` joins the `:` munch family beside `:>`, reads as its mirror, and
costs no reserved word.

But **settle one thing first**: is a `:>` field to a `Component` sub-table single-valued or
table-valued? `tables.md:424` writes `headers :> RequestHeader : Component { name, value }` — plural
name, obviously many. `tables.md:326` says `:>` wraps the referenced table's `DataId`, and
`traits.md:199` says a `Component` has no `DataId`, so the singular reading is not well-typed.
`queries.md:234-236` calls a nested table "the same construct as an inline component sub-table". If
the table-valued reading is right — and the weight of evidence says it is — then **1:many inline
declaration already exists** for owned children, and `:<` shrinks to the case that actually needs
it: children that are *not* owned. That is still worth having, and it is a much smaller change. This
one question also decides items 11, 13 and 14.

### Where the request was already served

**Item 10 — LMDB or SQLite.** Neither, and the question dissolves: `storage.md:257-259` already says
materialization is a storage decision and that a table, a query and a derived table are one kind of
thing. Taken seriously, a view's rows *are* rows — they already have a format, an index, a locator
indirection, a compactor, a scrubber, a backup story and a wire protocol. SQLite adds a second of
each, plus a serialization boundary that breaks the zero-copy claim for that path. The only genuinely
new physical concepts are a **derived extent** (droppable, unreplicated) and an **arrangement** (one
LMDB sub-db per view and order) — and an arrangement is also what an index is, which is the physical
content of "materialization replaces the user-defined index". DuckDB is worth having as an
Arrow/Parquet *export target* from a tertiary; never as an engine.

**Item 9 — GTID.** All three of your complaints are right. On the library: `mysql-haskell` 1.3.0
exposes no GTID support at all — `BinLogTracker` is filename-plus-offset and there is no
`COM_BINLOG_DUMP_GTID` — but `Database.MySQL.Connection` is an exposed module with `MySQLConn(..)`,
`writeCommand` and `putToPacket`, so DataCode can speak GTID against the published API in roughly
150 lines with **no fork**. Note that MariaDB (`domain-server-sequence`, `@slave_connect_state`) and
MySQL (`uuid:txn`, GTID SET) are incompatible schemes; decide whether that is one connector with two
modes or two connector kinds. The GTID is also the natural idempotency key, which is what makes a
replayed event a no-op rather than a duplicate.

**Item 4 — regex.** The library is `regex-tdfa` (module `Text.Regex.TDFA`), added to `build-depends`
and fetched by `cabal build`; `functions.md:117` already lists it as always-available. The
substantive finding is that **the docs' stated reason for restricting the `=~` right-hand side is
false**: "TDFA is a DFA engine, so a pathological pattern costs no more than a linear scan"
(`railroad.md:535-537`) does not hold — TDFA builds its DFA lazily and caches states, and a
ten-character pattern was measured exhausting a 3 GB heap. Keep the restriction; replace the
justification with the real one (provenance, transparency, and a commit-time pattern budget). Also
worth knowing: TDFA defaults to `multiline = True`, so every `^…$` predicate written so far is
bypassable by an embedded newline, and its POSIX character classes are ASCII-only.

On "alnum arguments": alnum is the wrong safety property. Digits are alnum and `a{800}` is the
attack. The property you want is **positional** — an argument may only ever occupy an atom position
in the parsed pattern — which is a structural rule, not a character-class rule. That said, the
motivating example does not typecheck where it was written, and the repaired residue is already
expressible today by putting the pattern in a `Reference` row and reaching it by FK from an assert.
So: defer parameterisation, ship the corrections.

## Implementation plan

Phase 0 is blocking. Phases 1–5 are ordered by dependency; 5 runs in parallel with the rest.

### Phase 0 — settle five contradictions (no new syntax)

Each is depended on by two or more of the sixteen items, and three were asserted in opposite
directions by different designers in this batch.

| # | Question | Blocks |
|---|---|---|
| 0.1 | ~~Is a `Component` `:>` field one row or many?~~ **Answered: table-valued.** Write the rule and its six consequences into `tables.md`. | items 11, 13, 14, 16 |
| 0.2 | Does `retain` reach `UserData`, and is there any row-level `prune`? | items 1, 9 |
| 0.3 | Do `Reference` rows live on the `system` shard or the branch shard? | items 9, 12 |
| 0.4 | What does an evolution-added field read on old rows — the default, `NotFound`, or `NotGiven`? | items 12, 15, 16 |
| 0.5 | What does `limit` mean? It is in the grammar and appears nowhere in `queries.md`. | items 8, 11 |

Also in Phase 0, because they are pure repair and everything downstream reads the grammar: the
eight structural defects above.

### Phase 1 — lexical and literal foundation

`[` and `]` as tokens · `TableLit ::= '[' ( Expr ( ',' Expr )* ','? )? ']'` in `Atom` and `Source` ·
the position-fixes-the-row-type rule for elements · `` `elem` `` documented as the membership
spelling · the `:` maximal-munch row corrected to include `:<` and the seven `MetaCommand` literals.

Delivers literal sets, a table value usable as a join source and a binding right-hand side, and the
base that items 13 and 14 both need.

### Phase 2 — query surface

- **2a** `ProjItem ::= FieldPath Projection? NameClause?` — one nesting rule that absorbs the
  `nest` clause *and* the query side of `:<`, with the `*`-exclusion and nested-ordering rules.
- **2b** `numbered <table>` and its generated `n` column.
- **2c** `ShowCmd`/`ShowTarget`/`ReportClause` restructure, `--limit`, `system.config.PageSize`, and
  a desugaring table naming which system table each `show` target reads.
- **2d** `Insert ::= QName RecordLit | Query TableLit`, decomposition by base-table key,
  `max_transaction_rows`.

### Phase 3 — declaration surface

`:<` (blocked on 0.1) · `Blob` (disposal path rewritten against 0.2) · `minLen`/`maxLen` defined ·
`preHashed` · the regex corrections.

### Phase 4 — administration

`ShardRef`/`ShardRange` · `cancel` · `ExportCmd` with `system.export.Destination` · `Resolution ::=
QName` (unreserving `DataCode` and `External`) · every `Ident`-typed identifier argument retyped
`StringLit`, because a rendered `DataId` begins with a digit and cannot lex as an `Ident`.

### Phase 5 — storage and distribution (no grammar, longest lead)

Derived extents and arrangements · GTID connectors · epoch and fencing with a two-of-three ACK ·
the `Reference`-tag documentation fix.

### Deferred, with reasons

| Item | Why |
|---|---|
| Recursion / closure | Real new expressiveness, orthogonal, blocked on the `Null`-in-key vs. tree-rooting tension |
| `in` as an operator | `` `elem` `` covers it; revisit only if the `let` rule can be stated soundly |
| `Ephemeral` trait | Decide at its own scope, with `show replication lag` and the generation table on the table |
| Supplied-field mask | Justified only by merge reconciliation, which is not designed |
| `.dc` export format | Blocked on the table literal *and* on a scrub-replay rule for re-import |
| Parameterised regex | Motivating example does not typecheck; repaired residue is already legal |
| `Default a`, `Text 255` | Rejected on the merits. Record the reasoning; build nothing. |

## Doc rewrite

When the docs are rewritten, four rules do most of the work:

1. **Repair `railroad.md` first and regenerate every example against it.** A linter that extracts
   fenced blocks and parses them against the EBNF is the durable fix; without one this drifts again.
2. **Delete the eleven duplicated rules.** `bypass access` is stated normatively in four files;
   `Queue`/`QueueState` in two; grain alignment in three; the violation retention chain in three;
   the `system`-is-a-namespace rule in three; connector configuration in three. Each pair has
   already drifted.
3. **Declare the missing tables and types, or stop referring to them.** Twelve types and seven
   system tables are load-bearing and undeclared.
4. **Move `open-questions.md`'s answered content into the normative files.** Several answers exist
   only in the OQ entry, which `CLAUDE.md` already forbids.

`10-findings.md` gives every one of these an exact location and a proposed edit.
