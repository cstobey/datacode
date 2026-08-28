# Integrated Grammar and Architecture Review — 16 Proposals

Read against `docs/schema/railroad.md` (1036 lines) in full, plus the productions and reserved-word list it owns.

---

## (A) Conflict table

### A.1 — Same production, added three ways

| # | Conflict | Proposals | Resolution |
|---|---|---|---|
| 1 | **The bracket literal, defined three times.** D05 adds `ListLit ::= '[' (Expr (',' Expr)* ','?)? ']'` to `Atom` for `in`'s RHS. D13 adds `TableLit`, byte-identical, to `Atom` **and** `Source`, plus `Insert ::= Query TableLit`. D14's JSON-in requires a nested bracket literal inside a `RecordLit` for multi-row nested insert, and explicitly flags the dependency on D13. | D05, D13, D14 | **ONE production, named `TableLit`, in `Atom` and `Source`.** Both authors independently converged on the type being `Table a` (D05: "`[…]` is a `Table a` literal, not a list type"; D13: "`TableLit :: Table r`"), and both reject a `List a` type for the same reason (a list-typed column is a repeating group). `Table a` already exists (`queries.md:266-273`). Trailing comma permitted in both. `[`/`]` collide with no prefix, and `railroad.md:54` already names `[ ]` in the layout rule — a production for it **retires a dangling reference** rather than adding one. |
| 2 | **Element homogeneity: two incompatible rules.** D05 and D13 both require homogeneous elements (same field set). D13's critique shows this makes the batch form *not* a generalization of the single-row form: `T { a = 1 }` legally defaults `b`, but `T [ {a=1}, {a=2, b=3} ]` is illegal, so two legal statements become one illegal one. | D05, D13 | **Position-sensitive, one rule, stated once.** Where the position fixes the row type (insert target, `elem`/`in` RHS against a typed column, a nested column's element type), elements are checked independently against that type and omitted fields take their declared default — identical to the single-row form. Only in a *standalone* position (binding RHS, `let`) must elements agree, because a type has to be minted from them. This is the same shape as the empty-literal rule both proposals already adopted, so it is one rule with two consequences rather than two rules. |
| 3 | **Three mechanisms produce a nested table-valued column.** `group` (existing, `queries.md:215-249`); D14's `nest` clause; D16's `:<` reverse relation. A `Component` `:>` field arguably makes a fourth. | D11, D13, D14, D16 | **Nest in the projection, not in a clause.** `ProjItem ::= FieldPath Projection? NameClause?`. A `ProjItem` naming a table-valued path — a `:<` reverse relation, a `Component` `:>` field, or a `group`-generated `rows` — may carry a sub-projection that nests it. This subsumes `nest` entirely (D14's critique reaches the same design independently), preserves D14's own principle that "nesting is a claim of authorship and must be authored", eliminates the join-graph-must-be-a-tree analysis, the diamond rule, the clause-order rule, the filter-after-`nest` error, and the reserved word. `nest` is **cut**. |
| 4 | **`:describe … deep` proposed twice, identically.** | D14, D16 | Convergence, not conflict. One change: `MetaCommand ::= ':describe' QName 'deep'?`. `deep` is already reserved by `verify shard … deep` (`railroad.md:866`) and means the same thing. Ensure the doc edit lands once. |
| 5 | **`export` extended two ways.** D08 wants `export shard <ShardRef> to StringLit` with a resolved `Destination` retrofit; D14 designs `ExportCmd ::= 'export' Query 'to' Ident StringLit` with `system.export.Destination`. Both independently identify `railroad.md:868`'s unvalidated absolute path as an arbitrary-file-write primitive. | D08, D14 | **One `Destination` mechanism, two productions distinguished by the `shard` keyword** — the `erase QName` / `erase shard QName` precedent (`railroad.md:1012-1014`). Both `export` forms take `Ident StringLit` (destination name + path relative to its `root`). D08's retrofit is adopted, so DR exports gain the same containment and audit trail. |
| 6 | **`AdminCommand` restructured twice, incompatibly.** D08 collapses `TxnCmd` and `IntegrityCmd` into `ShowCmd ::= 'show' ShowTarget QueryClause*`; D06 adds a parallel `QueryCmd ::= 'show' 'queries' … \| 'cancel' …`. | D06, D08 | One `ShowCmd` with a `ShowTarget` alternation that includes `queries`; `cancel` is its own production. This also makes `queries` contextual and therefore **unreserved** — see (C). |
| 7 | **`show` inherits every new `QueryClause`.** With D08's `QueryClause*`, D14's `NestClause` and D11's closures become admissible in admin reports (`show shards nest`), and `at`/`diff`/`group`/`><` require the degraded reader to execute joins and resolve historical version tokens — which is exactly what D08 says the degraded path exists to avoid. | D06, D08, D11, D14 | Restrict to `ReportClause ::= WhereClause \| OrderByDecl \| LimitClause \| Projection`. Delivers everything the request asked for; nothing it did not. |

### A.2 — Reserved-word and lexical collisions

| # | Conflict | Proposals | Resolution |
|---|---|---|---|
| 8 | **`DataIdLit` silently misparses a legal numeric literal.** D08 proposes a 20-character Crockford-base32 terminal recognized under the `[0-9]` prefix, justified by "a 20-digit decimal exceeds `Int` range". `types.md:14` makes `Decimal` **arbitrary-precision**, so `12345678901234567890` lexes as a `DataIdLit` and `12345678901234567890.5` lexes as one with component ordinal `5`. The EBNF `B32+` also collides with every uppercase `Ident`. | D08 | **Reject the terminal.** Use `StringLit`, on the `AtClause` precedent (`railroad.md:680-681`: "a version token … or an ISO-8601 moment; the two are told apart at resolution, not by the grammar"). D08's own critique reaches this. The four broken positions (`revoke token`, `show transaction`, `resolve conflict`, `erase`) are fixed by typing them `StringLit`, which is what `ErasureCmd` already does correctly at `railroad.md:823`. Composite placement keys then work via `RecordLit`, which `DataIdLit` could not express at all. |
| 9 | **`<:` proposed nowhere, `:<` proposed once — but the check matters.** D16 evaluates `<:` and rejects it. | D16 | Confirmed correct, and the argument is stronger than D16 states: OQ-005 (`open-questions.md:391`) records that a table *is* a type and `table T : Trait` uses the same `:` as `type A : B`, so `comments <: Comment` is a **well-formed but false** subtyping sentence — a plausible misreading, not a parse error. `:<` joins the `:` munch family; `:` cannot begin an `Atom` (`railroad.md:482-490`) so no expression admits it. Delete D16's `Data.Sequence` `ViewL`/`ViewR` argument — in `Data.Sequence` the *single element* is on the left of `:<`, which is inverted from the intent. |
| 10 | **The `:` maximal-munch row is already wrong, and the amendment propagates it.** `railroad.md:583-589` lists `:` → `:`, `:>`. But `railroad.md:766-772` defines seven more `:`-prefixed tokens (`:use`, `:describe`, …). | D16 | Fix in the same edit: `:` → `:`, `:>`, `:<`, and the `MetaCommand` family. Otherwise the file that calls itself "the single source of truth for DataCode syntax" misstates its own lexer in the row being amended. |
| 11 | **`in` as a `CmpOp` collides with `let … in`, and the proposed fix is unsound.** D05's rule ("the first `in` at bracket depth 0 closes the binder") does not count `let` nesting, so `let a = let b = 1 in b + 1 in a * 2` — grammatical today — breaks. In D05's own proposed multi-binder block, the misparse **type-errors instead of parse-errors**, so the promised diagnostic cannot fire. | D05 | **Spell membership `` `elem` ``** — `InfixExpr ::= Atom ('`' QName '`' Atom)*` already exists (`railroad.md:480`), `Data.List` is auto-available, fixity lands correctly below `CmpExpr`. Zero `let` hazard, zero `LetExpr` widening, zero `CmpOp` entry. D05's own concession says `elem` wins if the sub-query RHS is dropped, and D05's stated decisive argument for the operator form — that a shadowed user-defined `elem` would evade the provenance check — is **false**: the restriction is a property of the `Query` subterm, which `walkTerm` reaches regardless of which function consumes it. D05's own implementation notes require exactly that walk. |
| 12 | **`depth` as a generated column collides with the recommended idiom that uses it.** D11 makes "a source column named `depth` in a closure join" a compile-time error, and D11's recommended cycle-prevention idiom declares `depth : Int = parent_depth manager` on the same table. | D11 | Cut with the closure operator (see #13). If recursion later lands, the depth column must be renameable through `NameClause`, not fixed. |
| 13 | **`+`/`*` closure quantifier.** Positionally unambiguous (neither is in the follow set of `via QName`, and `via` never occurs in `Expr` position), but the feature's flagship sharding lever is unwritable: `tables.md:207` rejects a `Null`-derived variant in a key, and every tree root's self-FK is nullable (`manager :> Employee \| NoManager`). The `Doc` case D11 calls "the single best cost property" is rejected by D11's own self-edge rule, since the proposed `parent` column is typed `:> Node \| Request` — different tables on the two ends. | D11 | **Defer the whole closure operator.** It is a genuine expressiveness addition (Aho–Ullman is real), orthogonal to every other proposal, and it needs the `Null`-in-key/tree-rooting tension settled first. Deferring also resolves #12, the `depth` name, and one OQ-038 claimant. |
| 14 | **`provenance` as a `FieldPath` tail shadows a real field, with a wrong-typed answer.** D15's rule "the field-level virtual column **wins** over traversal" means any table targeted by a `:>` that declares a field named `provenance` has it permanently unreachable through that FK — `Order.customer.provenance` silently returns the sum type instead. `provenance` is also live vocabulary for a *different* concept at `dynamic-loading.md:105` and `api-and-rendering.md:9`. | D15 | Cut the tail name. D15's own critique supplies the free answer: `Order where total.updated_at /= created_at` uses the already-specified per-field timestamp (`transaction-graph.md:650`) and the free `created_at` projection. If a mask is later wanted it goes on the **creating version only**, which also eliminates the merge-commit hole D15 leaves open. |
| 15 | **`nest`, `queries` reserved unnecessarily.** Both sit in positions where no bare identifier is admissible. | D06, D14 | Both **cut**. `show` already commits the parse to `AdminCommand`; no `QueryClause` alternative begins with a bare `Ident`. D14's own grammar delta makes exactly this argument for `ExportFormat`'s five literals and then declines to apply it to `nest`. |

### A.3 — Semantic contradictions between proposals

| # | Conflict | Proposals | Resolution |
|---|---|---|---|
| 16 | **`Default a` injected into every column type vs. a table literal that omits fields.** (Named explicitly in the brief.) A `Default`-wrapped column would make `phone is NotGiven` **False** on every defaulted row, and `TableLit`'s omitted-field rule writes defaults per element, so every literal-inserted row would carry wrapped values. | D13, D15 | **Dissolved by D15's own verdict** — D15 rejects `Default a` as a type on independent grounds (it forces `is` to carry two contradictory meanings; a fact that can change while the value does not is a column, not a variant). Record the interaction so the type is not revived: it is incompatible with the multi-row literal as well as with typed absence. |
| 17 | **Automatic nesting vs. row numbering within a nested column.** (Named in the brief.) D14's `nest` desugars to a `group` chain and specifies no ordering for the nested column; D11's `row_number` is in scope only where the projected query states `order by`. A nested column produced by `nest` therefore has no position at which numbering is expressible, while D14's critique separately shows the nested column inherits the source table's declared `order by` (`railroad.md:216`), which contradicts "one row per literal element, in literal order". | D11, D14 | Under the unified projection-nesting rule (#3), ordering inside a nested column is declared in the source term (`>< (OrderLine order by qty desc) as line`, or the reverse relation's own declared `order by`). Numbering inside a nested column is `numbered` applied to that column (see #18), which takes the ordered table as its argument rather than reading an enclosing clause. |
| 18 | **`row_number` as a contextual binding is ambient state.** A nullary term whose value depends on the enclosing query's ordering *and* extent is the reading `queries.md:392-396` and OQ-005 reject for `Moment`. Every other extent-dependent value takes its table as an argument (`count :: Table a -> Int`). It is also de-facto reserved: `railroad.md:906` forbids any declaration colliding with a binding in scope. | D11 | **`numbered <table>`**, an ordinary function returning the table plus a generated `n` column. Generated columns are established four times over (`rows`, `before`/`after`/`change`, `grain`, `ordinal`), so the "signature is unwritable" objection D11 raises against it does not distinguish it from `group` or `diff`. Zero grammar, zero reservation, no scope rule, no order-completion rule, and the ordering is a parameter rather than ambient. |
| 19 | **`ordinal` on computed nested tables.** `queries.md:230` gives a `group`-nested table `Component` by default; `tables.md:45` gives every `Component` an `ordinal`. Together they promise `rows.ordinal` on every grouped query, with no defined value. D13's nested component literal assigns ordinals in literal order; D16 relies on `ordinal` for stored components. | D11, D13, D16 | Adopt D11's withdrawal, scoped: `ordinal` is available on a **stored** `Component` table and unavailable on a nested table produced by `group` or by a projection sub-nesting. Nothing was inserted in any order, so there is no ordinal to report. |
| 20 | **Nested-table trait default is opposite in two proposals.** `group`'s nested table defaults to `Component` (`queries.md:230`, OQ-005 at `open-questions.md:383`). D16's `:<` defaults to the parent's replication trait. Same clause shape (`: TraitList` after a name), same position, opposite default — and D16 claims reader transfer *from* `group`. | D14, D16 | Default `:<` to the parent's trait (cascade-by-default is wrong for a construct authors will reach for constantly, and `traits.md:221` forbids outside references to a `Component`), and **delete the reader-transfer claim**. State the asymmetry deliberately in both `queries.md` and `tables.md`. Additionally: forbid `SubTableTraits` on a **bodiless** `:<` — with no body to terminate `TraitList`, `comments :< Comment : Component, owner :> User` munches `owner` as a second trait, and a bodiless `:<` naming an existing child has no business setting that child's trait. This also closes the accidental "`Reference` child with a `:>` into shard-local `UserData`" path D16 flags in its own open items. |
| 21 | **`Ephemeral` as a sixth replication trait vs. "materialization is a storage decision, never a trait".** D06 adds a replication trait for server-local runtime state. D10 argues at length that a `Derived`/`Materialized` trait must be rejected because "traits are schema-level and this is storage" and "it would make the same table materialized or not depending on which server you ask". The identical argument applies to `Ephemeral`. `traits.md:104` also already gives `LogData` the replication value *server-local*, so the column that actually differs is durability, not replication. | D06, D10 | **Do not add `Ephemeral` in this change.** D06's `show queries` can render from memory and merge through the existing broadcast/merge path that `show violations` already uses (`distribution.md:370-375`), with `railroad.md:850-853` as the explicit precedent for an administrative report having its own syntax. If a general "system state that exists but is not stored" concept is wanted, decide it on its own scope — D06's own first question names the right three candidates. |
| 22 | **Six new `system.*` sub-namespaces for operational tuning rows.** `system.runtime` (D06), `system.query` (D11), `system.regex` (D04), `system.export` (D14), `system.api` (D13), plus `system.config.PageSize` (D08) and `system.shards.WritePolicy` (D13). | D04, D06, D08, D11, D13, D14 | Consolidate. `system.config` already exists and already holds exactly this shape (`Ingest`, `EmailPolicy`, `AllowedPackage`). Operational caps go there: `system.config.PageSize`, `system.config.PatternPolicy`, `system.config.WritePolicy`. Reserve `system.shards.*` for placement/durability (`ExtentPolicy`, `DurabilityPolicy`, `Range`, `RejoinPolicy`, `BlobPolicy`) and `system.export.Destination` for the one case that is a security boundary rather than a number. |
| 23 | **Cross-proposal write-provenance rule is unstated.** D13's decomposition supplies a back-FK from the parent row; D14's write-through supplies constants from the `where`; D15 rules that a `where`-pinned value reads `Supplied`. If a mask ever ships, all three paths must agree. | D13, D14, D15 | Whatever the mask decision, state one rule in `queries.md#writing-through-a-derived-table`: **a value supplied by decomposition — a `where` constant equality or a generated back-FK — is attributed to the writer, not to the default.** The alternative makes provenance depend on which derived table a write came through, which is not stable under refactoring. |
| 24 | **Write-through admissibility does not cover `group` layers.** D14 asserts a nested binding "satisfies condition (2) by construction". `queries.md:543-550`'s three conditions are stated over `where`, projections, and `><` joins; `group` appears nowhere, and `Order group { customer } { customer, count rows as n }` is obviously not writable. Under D14's own desugaring, `nest` inserts `group` layers between the projection and the base tables. | D13, D14 | Under the unified projection-nesting rule (#3) the layers are explicit and the fourth condition is writable: each nested column must be an unaggregated table-valued path, each level's key must be a superkey of its parent's, and condition (3) must be restated **per level** against the nested source. This belongs in `queries.md`, once. |
| 25 | **Nine proposals claim OQ-038.** Highest existing is OQ-037 (`open-questions.md:298`). | D01, D04, D05, D06, D08, D11, D12, D14, D15 | Sequential assignment below (D.6). Several should not be filed at all: D04's is refuted by its own measurements (cost is bounded by the pattern's reachable DFA state set, not the subject, so the pattern budget already bounds it); D14's connector-shadow-`Secret` question is largely answered at `integrity.md:456-459`; D12's tag-collision question may not exist at all (see #26). |
| 26 | **`Reference` rows live in two places, and one proposal's new OQ depends on which.** `traits.md:330` says the `system` shard; `distribution.md:246` says the branch shard. | D12, D09 | **Pre-existing contradiction, blocking.** Under the `system`-shard reading there is one tag allocator and D12's proposed OQ-038 (cross-branch variant-tag collision) does not exist. Settle before filing. |
| 27 | **Two proposals build on a `retain`/`prune` mechanism that does not exist.** D01 states "`retain` is `LogData`-only" in four load-bearing places; `aggregates.md:322` heads a section **"`retain` on `UserData` is admissible and rare"** and its first sentence says the opposite. D01 also builds its entire discard path on "orphan-prune", but `PruneStmt ::= 'prune' QName` takes a schema object and "orphaned branch" means an unmerged transaction-graph branch (`transaction-graph.md:88-92`) — there is no row-level prune and no refcount anywhere. D01's `system.crypto.ScrubRule` automation is likewise unimplementable: `ScrubRule` is a regex over a field path or document key with no version or value predicate. | D01, D09, D14 | D01's `Blob` storage design survives; its **disposal story does not** and must be rewritten against the real mechanism (`aggregates.md:164-170`'s no-binding `retain … for N day, drop` chain, which `aggregates.md:377-379` confirms carries the `Component` subtree). D14's `.dc` export format has the mirror-image problem — a re-import replays no scrub nodes, reopening the hole OQ-036 (`open-questions.md:227`) explicitly closed. |
| 28 | **`Component` `:>` arity is undefined, and four proposals depend on the answer.** `tables.md:424` writes `headers :> RequestHeader : Component { name, value }` — plural field, but `tables.md:326` says `:>` "wraps the referenced table's `DataId`" and `traits.md:199` says a `Component` **has no `DataId`**, so the singular reading is not well-typed. `queries.md:234-236` says a `Component` nested table is "the same construct as an inline component sub-table" and is identified by `Ordinal`, which is meaningless for a 1:1 field. `traits.md:224` caps components per *parent*, not per field. | D11, D13, D14, D16 | **Blocking, and it is the pivot.** If the table-valued reading is correct — and the weight of evidence says it is — then 1:many inline declaration **already exists** for owned children, D16's motivating gap shrinks to non-owned children only, D13's nested component literal has a target, D14's nesting has a source, and D11's `ordinal` withdrawal is correctly scoped. D16's `doc_edits` instruct rewriting `tables.md:421-429`, which would delete the only illustration of the 1:many component form and legislate an open question inside a change advertised as additive sugar. **Do not apply that edit.** |
| 29 | **Two proposals rewrite the same normative sentence about virtual columns.** `transaction-graph.md:564-568`: "The virtual columns are projections of the row identifier", with `updated_at` called out at :578 as "the one that is not". D15 adds `provenance` (making two); D11 adds `parent` on `Component` tables; D16 names the same containment edge from both ends. | D11, D15, D16 | D15's tail name is cut (#14). D11's `parent` and D16's `:<` reverse name are **two mechanisms for the same edge** — take D16's, which names it from both ends and makes the join legal in either direction; D11's is subsumed. Amend the `:564-568` rule once. |
| 30 | **Three proposals independently claim `storage.md` as normative home for physical layout.** D01 (`## Chunked Payloads`), D10 (`## Materialization` / derived extents + arrangements), D15 (supplied-field mask in `### 1. Append-only transaction log`). | D01, D10, D15 | Compatible sections, incompatible framing: D01 and D10 both open with "THE NORMATIVE HOME for physical layout". Scope them — D01 owns chunked payloads, D10 owns derived extents and arrangements, and the append-only-log section stays the home for the frame format both build on. |
| 31 | **`ProjItem` gains a sub-projection while `*` interaction is undefined.** `railroad.md:674`: "A `ProjItem` naming a source field removes that field from any `*`". Whether `total.provenance` / `comments { … }` / `Order.customer { … }` counts as *naming* the base field is undefined, and D11's own example `{ *, total, total.provenance as total_origin }` reads as a silent workaround. | D11, D15, D16 | State it: a `ProjItem` whose head `FieldPath` names a source field removes that field from `*`, whether or not the item carries a sub-projection or a virtual-column tail. Reverse relations and other table-valued columns are **excluded from `*`** unconditionally (D16 and D14 both require this; Ecto's `preload` is the precedent). |
| 32 | **A cluster-wide `unique` argument is used to distinguish two designs it does not distinguish.** D12 rejects `unique` on a shadow table's `id` because a table-wide `unique` is "a constraint shard serializing every ingest" — but `tables.md:185-188` says the *root* table's own key is cluster-wide whichever columns it names, so both of D12's candidate designs pay it. | D09, D12 | Drop the argument. The real discriminator is `integrity.md:105-109`: a candidate key is a declaration-time rule, so it is **enforced unconditionally**, and enforcing a uniqueness MariaDB does not guarantee halts the binlog at an offset (`connectors.md:118-122`). Key a shadow table on exactly the source PRIMARY KEY. |

---

## (B) Integrated EBNF delta

Ready to paste into `docs/schema/railroad.md`. Written in the file's existing style. **New reserved words: one (`cancel`). Words unreserved: two (`DataCode`, `External`). Net: −1.**

### B.1 Lexical

```ebnf
/* '[' and ']' become single-character tokens. Both share a prefix with
   nothing, so the maximal-munch table below is unchanged by them.
   railroad.md:54 already names '[ ]' in the layout rule; this supplies the
   productions that reference was written against. */
```

Maximal-munch table — replace the `:` row and add the meta-command note:

| Prefix | Tokens |
|---|---|
| `:` | `:`, `:>`, `:<`, and the `MetaCommand` literals `:use`, `:describe`, `:history`, `:commit`, `:rollback`, `:explain`, `:help` |

Every other row is unchanged. `$`, `` ` ``, `[`, and `]` share a prefix with nothing and are single-character tokens.

### B.2 Expressions

```ebnf
Atom         ::= Literal
               | FieldPath
               | FuncApp
               | Lambda
               | IfExpr
               | LetExpr
               | RecordLit
               | TableLit                                  /* NEW */
               | '(' Expr ')'
               | '(' Query ')'

TableLit     ::= '[' ( Expr ( ',' Expr )* ','? )? ']'      /* NEW */
```

`CmpOp` is **unchanged**. Membership is `` x `elem` xs ``, an ordinary backtick infix over `Table a`.

### B.3 Fields, tables, dependent declarations

```ebnf
BodyItem     ::= FieldDecl
               | BackRefDecl                               /* NEW */
               | '*'
               | UniqueDecl
               | AssertDecl
               | EventDecl
               | HandlerDecl
               | OrderByDecl
               | FunctionDecl

BackRefDecl  ::= Ident ':<' QName SubTableTraits? ( 'via' Ident )? SubTableBody?
```

### B.4 Queries and mutation

```ebnf
Source       ::= QName
               | Ident
               | TableLit                                  /* NEW */
               | '(' Query ')'

ProjItem     ::= FieldPath Projection? NameClause?          /* Projection? is NEW */
               | Expr NameClause
               | ( QName '.' )? '*'

Mutation     ::= Insert | Update | Delete
Insert       ::= QName RecordLit
               | Query TableLit                            /* NEW */
Update       ::= Query RecordLit
Delete       ::= 'delete' Query
```

### B.5 REPL

```ebnf
MetaCommand  ::= ':use' QName
               | ':describe' QName 'deep'?                 /* 'deep'? is NEW */
               | ':history' QName HistoryOpt*
               | ':commit'
               | ':rollback'
               | ':explain' Query
               | ':help'
```

### B.6 CLI

```ebnf
CliFlag       ::= '--host' Value
                | '--port' NumLit
                | '--client-token' Value
                | '--user-token' Value
                | '--exec' StringLit
                | '--file' Path
                | '--shard' ShardRef
                | '--format' Format
                | '--limit' NumLit                          /* NEW */
```

### B.7 Administration — restructured

```ebnf
AdminCommand ::= ShowCmd | ServerCmd | ShardCmd | ConnectorCmd | TokenCmd
               | GrantCmd | MatViewCmd | ErasureCmd | ExportCmd | CancelCmd
               | DrCmd

ShardRef     ::= QName ( '/' StringLit | ShardRange )?      /* NEW */
ShardRange   ::= 'from' ( Literal | RecordLit ) ( 'to' ( Literal | RecordLit ) )?
               | 'to' ( Literal | RecordLit )

ShowCmd      ::= 'show' ShowTarget ReportClause*            /* NEW; folds TxnCmd + IntegrityCmd */
ReportClause ::= WhereClause | OrderByDecl | LimitClause | Projection

ShowTarget   ::= 'servers'       ( 'for' 'shard' ShardRef )?
               | 'shards'        ShardRef?
               | 'queries'       ( 'on' Host )?
               | 'replication' 'lag' ( 'for' 'shard' ShardRef )?
               | 'connectors'
               | 'connector' 'conflicts' QName
               | 'tokens'        ( 'type' TokenType )?
               | 'grants'        ( 'for' QName )?
               | 'materialized' 'views' ( 'shard' ShardRef )?
               | 'transactions'  ( 'shard' ShardRef )? ( 'since' 'seq' NumLit )?
               | 'transaction'   StringLit
               | 'violations'    ( 'for' ValidationRef )? ( 'shard' ShardRef )?

CancelCmd    ::= 'cancel' StringLit ReasonClause?           /* NEW */

ServerCmd    ::= 'elevate' 'secondary' Host 'to' 'primary'  'for' 'shard' ShardRef
               | 'demote'  'primary'   Host 'to' 'tertiary' 'for' 'shard' ShardRef

ShardCmd     ::= 'describe' 'shard' ShardRef
               | 'split' 'shard' ShardRef 'at' 'key' ( Literal | RecordLit )

ConnectorCmd ::= 'describe' 'connector' QName
               | 'add' 'connector' Ident StringLit RecordLit
               | ( 'pause' | 'resume' ) 'connector' QName
               | 'resolve' 'conflict' StringLit 'using' Resolution

Resolution   ::= QName | 'merge' RecordLit                  /* CHANGED: unreserves DataCode, External */

TokenCmd     ::= 'issue' 'client' 'token' 'for' QName 'scoped' 'to' QName
               | 'revoke' 'token' StringLit
TokenType    ::= 'client' | 'user'                          /* CHANGED: 'server' removed */

GrantCmd     ::= 'grant'  QName 'on' QName ( 'bypass' BypassKind+ )?
               | 'revoke' 'grant' QName 'on' QName
BypassKind   ::= 'access' | 'erasure'

MatViewCmd   ::= 'materialize' QName
               | 'refresh' 'view' QName ( 'at' StringLit )?
               | 'drop' 'materialized' 'view' QName

ErasureCmd   ::= 'erase'   QName StringLit ReasonClause
               | 'scrub'   FieldPath 'at' 'seq' NumLit ReasonClause
               | 'release' 'unique' FieldPath StringLit ReasonClause

ExportCmd    ::= 'export' Query 'to' Ident StringLit ( 'as' ExportFormat )? ReasonClause?
ExportFormat ::= 'json' | 'jsonl' | 'csv' | 'tsv'

DrCmd        ::= 'force' 'elect' 'primary' Host 'for' 'shard' ShardRef
               | 'verify' 'shard' ShardRef 'deep'?
               | 'replay' 'shard' ShardRef 'from' 'seq' NumLit 'to' 'seq' NumLit
               | 'export' 'shard' ShardRef 'to' Ident StringLit ( 'at' 'seq' NumLit )?
               | 'import' 'shard' ShardRef 'from' Ident StringLit
               | 'force' 'sync' Host 'for' 'shard' ShardRef
```

Removed: `TxnCmd`, `IntegrityCmd` (folded into `ShowCmd`); `'erase' 'shard' QName ReasonClause` (a data-subject erasure addresses a row and cascades through the FK chain — `railroad.md:838` already defines it that way, and OQ-036 at `open-questions.md:213-215` confirms erasing the root scopes the act); `'show' 'replication' 'lag'` from `DrCmd`; the three bespoke `( 'limit' NumLit )?` tails.

### B.8 Ambiguity checks

- `to` terminates a top-level `Query` in `ExportCmd`: `to` starts no `ReportClause`, and the only `to` inside a query is `DiffClause`'s, consumed immediately after a `StringLit`. Because `ExportCmd`'s destination is `Ident StringLit` and `ShardRange`'s bound is `Literal | RecordLit`, `export shard S to dest "f.json"` and `export shard S from "a" to "m" to dest "f.json"` are told apart by whether the token after `to` is an `Ident`.
- `TableLit` in both `Atom` and `Source` is a benign ambiguity — both readings denote the same value — resolved by the existing rule at `railroad.md:539-543`.
- `Insert ::= Query TableLit` versus `FuncApp ::= QName Atom+`: resolved by what the head name resolves to, exactly as `Insert ::= QName RecordLit` versus `FuncApp` is today. **Note this makes `count [ {a=1} ]` at the REPL parse as an insert into a table named `count`** (`ReplInput` admits no bare `Expr`); the parenthesized form is required, and `count`/`sum`/`min`/`max`/`avg` are deliberately unreserved.
- `:<` introduces no expression-position hazard: `:` cannot begin an `Atom`.
- `ProjItem`'s new `Projection?` is unambiguous because items are `,`-separated and no other production places `{` after a `FieldPath` in projection position.

### B.9 New "constraints not expressible in the grammar"

**Under Functions and Expressions:**

- A `TableLit` denotes a value of type `Table r`. It is never a `TypeExpr`, so no field may be list-typed; a repeating group is a sub-table.
- Where the position fixes the row type — an insert target, an `elem` right operand, a nested column — a `TableLit`'s elements are checked independently against that type and an omitted field takes its declared default, identically to the single-row `RecordLit` form. In a standalone position the elements must share one type, since one must be minted from them.
- Elements bind by name. There is no positional element form (`Atom` admits no tuple; `railroad.md:95`'s tuple is a `TypeExpr`).
- An empty `TableLit` is admissible only where its position determines the element type. Elsewhere it is a compile-time error naming the ambiguity.
- A `TableLit` is unordered as a value. In insert position its textual order is the order the generated mutations are applied, which is what assigns `Ordinal` and orders `DataId`s.

**Under Tables, bindings, traits:**

- A `BackRefDecl` declares nothing on the containing table. It declares or amends the table its `QName` names, adding a `:>` field back; `via` names that field. The generated field's origin address is the `BackRefDecl`'s path, so redeclaring the child cannot drop it.
- At most one `BackRefDecl` naming a given child may carry a `SubTableBody`; further ones must carry `via`. Declaring one table twice in a single commit is an error.
- `SubTableTraits` is **rejected** on a bodiless `BackRefDecl` — `TraitList` has no terminator there, and a bodiless `:<` names a child declared elsewhere whose trait is not its business.
- A `BackRefDecl` defaults the child to the containing table's replication trait, **not** to `Component`. This is deliberately the opposite of `group`'s nested-table default (`queries.md:230`); both are stated where they apply.
- A `BackRefDecl`'s `Ident` names a table-valued virtual column. It is excluded from `'*'` and rejected in a `UniqueDecl`, a `DefaultClause`, a `RecordLit`, an `OrderByDecl`, and with `'unique'` or `IndexedClause`.
- A `BackRefDecl` naming the containing table must be bodiless.
- A `BackRefDecl` that adds a `:>` to a populated child is refused unless the type carries a `Null`-derived variant.
- On a `Component` child the generated field is a virtual column projecting the identifier prefix and stores no bytes. `deprecate` of the reverse name drops the **name only**, never the edge — `traits.md:220` makes the parent the child's identity.

**Under Queries and Mutation:**

- A `ProjItem` whose head `FieldPath` is table-valued may carry a sub-`Projection`, which nests it. Table-valued paths are the `rows` a `group` generates, a `BackRefDecl` reverse relation, and a `Component` `:>` field.
- A `ProjItem` naming a source field removes that field from any `*` in the same `Projection`, whether or not it carries a sub-`Projection`. A table-valued column is excluded from `*` unconditionally.
- Ordering within a nested column is declared in its source term, never by an `OrderByDecl` after the projection.
- `ordinal` is available on a stored `Component` table and unavailable on a nested table produced by `group` or by a sub-`Projection`; nothing was inserted in any order.
- Within one `Insert`, two elements agreeing on a base table's candidate key denote one row of that base, and a non-key column of that base differing between them is rejected. Two elements agreeing on the target's full derived key are rejected as duplicates. Decomposition never upserts.
- A write target admits only `JoinClause`, `WhereClause`, and `Projection`. `at`, `diff`, `group`, `order by`, and `limit` are rejected in `Insert` and `Update` target position.
- Write-through admissibility is stated **per nesting level**: each level's group/nest key must be a superkey of its parent's, each nested column must be an unaggregated table-valued path, and every undefaulted field of each base must be projected or fixed by that level's `where`.
- A value supplied by decomposition — a `where` constant equality, or a generated back-FK — is attributed to the writer, not to a default.
- The decomposed row writes staged in one transaction may not exceed `system.config.WritePolicy.max_transaction_rows`.
- A `QName` followed by a `RecordLit` with no intervening `QueryClause` is an `Insert`; a `Query` carrying at least one `QueryClause` followed by a `RecordLit` is an `Update`; `Query TableLit` is always an `Insert`. *(Pre-existing ambiguity, stated for the first time.)*

**Under Administration:**

- A `ShardRef`'s bare `QName` names a shard family; `QName '/' StringLit` one concrete shard; a `ShardRange` every shard whose placement interval intersects it. Ranges are half-open, `[lower, upper)`.
- A `ShardRange`'s bounds are values of the family's placement key. `RecordLit` is the spelling for a composite key.
- `describe shard`, `show transactions`, `replay`, `export shard`, and `import shard` take the concrete form only.
- Every identifier argument in this section is a `StringLit`, not an `Ident`: a rendered `DataId` begins with a digit and cannot lex as an `Ident`.
- `ExportCmd`'s `Ident` names a `system.export.Destination` row; the `StringLit` is relative to its `root`, and a `..` segment, absolute prefix, or symlink resolving outside `root` is rejected. Default deny: no `Destination` row, no export.
- `ReasonClause` is mandatory on `ExportCmd` where any source carries `Personal`, and on all three `ErasureCmd` forms.
- A `Secret` column serializes as `Sealed` in every export format.
- `cancel`'s `StringLit` names a running query; bytes 6–7 of the rendered identifier name the coordinating server, so the command takes no host.
- A `ShowCmd` with no explicit `LimitClause` is capped at `system.config.PageSize`, resolved most-specific-first. The cap applies to the `table` and `json` output formats and not to `csv` or `raw`.

---

## (C) Reserved words

### C.1 Total across all sixteen proposals, before integration

| Word | Proposal | Kind |
|---|---|---|
| `nest` | D14 | new reserved word |
| `cancel` | D06 | new reserved word |
| `queries` | D06 | new reserved word |
| `conflicts` | D08 | already used at `railroad.md:798`, absent from the list |
| `row_number` | D11 | contextual binding — de-facto reserved by `railroad.md:906` |
| `depth` | D11 | generated column — collides as a source column name |
| `provenance` | D15 | `FieldPath` tail — shadows a real field, wrong-typed |
| `reverse` | D16 (critique alt.) | new reserved word, only if that alternative is taken |
| `issue`, `scoped` | D03 | **removals** |
| `DataCode`, `External` | D09 | **removals** |

**Eight names an application schema could no longer use; four freed.** Net +4 as proposed.

### C.2 Final list — kept

| Word | One-line justification |
|---|---|
| **`cancel`** | Appears in leading position, where `Query ::= Source` with `Source ::= Ident` and `FunctionDecl ::= Ident Param* '=' Expr` both begin. Genuinely ambiguous unreserved; no other candidate on the list is. |
| **`conflicts`** | Not an addition — it is already consumed by `show connector conflicts` (`railroad.md:798`) and is simply missing from the list, while every sibling plural (`shards`, `servers`, `grants`, `tokens`, `views`, `transactions`, `violations`) is present. A list fix. |

**Net change: +1, −2 = −1.** (`DataCode` and `External` are unreserved; `issue` and `scoped` are retained — see C.4.)

### C.3 Considered and rejected

| Word | Why it lost |
|---|---|
| **`queries`** | Contextual. `show` commits the parse to `AdminCommand`; no `ShowTarget` position admits a bare identifier. D06's stated reason is "consistency", the weakest on the list. |
| **`nest`** | Contextual, and then subsumed entirely. No `QueryClause` alternative begins with a bare `Ident`, so it need not be reserved — and under the unified projection-nesting rule the clause does not exist. D14's own grammar delta makes exactly this contextual argument for `ExportFormat`'s literals. |
| **`depth`** | The most common column name on hierarchical tables, and it collides with D11's own recommended acyclicity idiom (`depth : Int = parent_depth manager`). Cut with the closure operator. |
| **`provenance`** | Reserving it is the magic-`access` defect (`railroad.md:995-1000`) in a worse form: unreserved it silently shadows a real `provenance` field through any `:>`, returning a wrongly-typed value rather than an error. It is also live vocabulary for a different concept in two files. The capability is available free as `total.updated_at /= created_at`. |
| **`row_number`** | A contextual binding is de-facto reserved (`railroad.md:906`), and a nullary extent-dependent term is ambient state — the reading rejected for `Moment`. `numbered <table>` takes its ordering as a parameter and reserves nothing. |
| **`reverse`** | Only needed if D16's critique's child-side spelling is preferred to `:<`. `:<` costs no word and pairs with `:>`; take the operator. |
| **`has`, `owns`, `from`, `by`** | D16's alternatives for the dependent declaration. All plausible field names, `from` was already withdrawn once with `SourceClause`, and `by` already carries two meanings. |
| **`Default`** | Rejected as a type constructor, not merely as a word: it forces `is` to carry two contradictory meanings (`phone is NotGiven` becomes False on every defaulted row), and a fact that can change while the value does not is a column. |
| **`insert`, `values`, `into`** | Juxtaposition already *is* the insert. The multi-row form adds a bracket, not a word. Note that `functions.md:194-195` uses a bare `insert` that no production has ever admitted — a doc bug to fix. |
| **`prehashed`, `blob`, `chunk`, `chunked`, `range`, `maxLen`, `minLen`, `maxBytes`, `varchar`, `char`, `elem`, `contains`, `any`, `all`, `member`, `not in`, `epoch`, `fence`, `rejoin`, `quiesce`, `nested`, `flat`, `page`, `offset`, `cursor`, `after`, `recursive`, `closure`, `descendants`, `ancestors`, `connect`, `ingest`, `validation`, `origin`, `matching`, `like`, `quote`, `escape`, `search`, `kill`, `abort`, `terminate`, `query`, `schedule`, `cron`** | All correctly rejected by their own proposals, on the same three grounds: it is a plausible field name; it is a second spelling for something the language already has; or the position is contextual. |
| **`DataCode`, `External`** | **Withdrawn.** Reserved solely so one `ConnectorCmd` production could name them, which made `authority : DataCode \| External \| Symmetric` — the field whose values they are — unlexable. The magic-`access` defect in a new position. `Resolution ::= QName` resolves them as ordinary variants. |
| **`issue`, `scoped`** | D03 proposes withdrawing both with the `issue client token` production. **Do not**, yet: `ReplInput` admits no bare `Expr`, so `issueClientToken r` parses nowhere and the withdrawal removes the only way to obtain a client-token secret with nothing replacing it. Retarget `for StringLit` → `for QName` and revisit when a REPL expression form exists. |

---

## (D) Dependency-ordered implementation sequence

### Phase 0 — Settle five doc contradictions (blocking; no new syntax)

Every one of these is depended on by two or more proposals, and three of them were each asserted in opposite directions by different proposals in this set.

| # | Contradiction | Blocks |
|---|---|---|
| 0.1 | **`Component` `:>` arity** — one row or many. `tables.md:326`/`traits.md:199` (not well-typed as singular) vs. `tables.md:424` (plural example) vs. `queries.md:234-236` (same construct as `group`'s nested table, identified by `Ordinal`). | D11, D13, D14, D16 — it decides whether D16's construct closes a gap or adds a second spelling |
| 0.2 | **`retain` on `UserData`** — `aggregates.md:322` says admissible; D01 asserts `LogData`-only in four places; there is no row-level `prune` at all. | D01's entire disposal story; D09's connector-position derivation |
| 0.3 | **`Reference` row placement** — `traits.md:330` (`system` shard) vs. `distribution.md:246` (branch shard). | D12's proposed OQ; D09's `Domain : Reference, Extensible` |
| 0.4 | **What an evolution-added field reads on old rows** — `evolution.md:274` (`NotFound`) vs. `transaction-graph.md:655` (`NotGiven`). `NotFound` is wrong in both cases, being outside the field's declared type. | D15, D16, D12 |
| 0.5 | **`limit` has no semantics.** `LimitClause` is in `railroad.md` and the word appears **nowhere** in `queries.md`, its normative home. Without a default ordering rule, every cursor and pagination design is undefined. | D08 pagination, D11 numbering |

Delivers: a schema the rest of the work can be specified against. Costs a day of reading; saves rewriting three features.

### Phase 1 — Lexical and literal foundation (serial; everything downstream depends on it)

`[`/`]` tokens · `TableLit` in `Atom` and `Source` · the position-fixes-the-row-type rule · empty-literal rule · `` `elem` `` documented as the membership spelling · the `:` munch-table fix.

Delivers: literal sets (`status `elem` [Pending, Shipped]`), a table value usable as a join source and binding RHS, and the base D13 and D14 both need.

### Phase 2 — Query surface (parallel within the phase; depends on Phase 1)

- **2a.** `ProjItem ::= FieldPath Projection? NameClause?` — unified nesting. Absorbs D14's `nest` and D16's query-side reverse navigation. `*`-exclusion rule; nested-ordering rule; `ordinal` withdrawal on computed nested tables.
- **2b.** `numbered <table>` and its generated `n` column. Depends on 0.5.
- **2c.** `ShowCmd` / `ShowTarget` / `ReportClause` restructure; `--limit`; `system.config.PageSize`; the desugaring table naming which system table each `show` target reads. Depends on 0.5, and on `system.shards.Range` being *named* (it is described at `distribution.md:42-97` and has never been declared).
- **2d.** `Insert ::= Query TableLit`, decomposition by base-table key, base-major application order, `max_transaction_rows`. Depends on 2a for the nested form.

Delivers: nested JSON out, multi-row and multi-table insert, pagination and filtering on every `show`.

### Phase 3 — Declaration surface (parallel; depends on Phase 0 only)

- **3a.** `:<` / `BackRefDecl` (D16). **Blocked on 0.1** — if the table-valued reading wins, this shrinks to non-owned children and the `tables.md:424` example must *not* be rewritten.
- **3b.** `Blob` (D01). Zero grammar; the type, the chunk-component design, `digest`/`length`, the `Encrypted Blob`/`unique` interaction, and — rewritten — the disposal path against 0.2.
- **3c.** `minLen`/`maxLen` (D02). Two files, zero grammar. Defines eight existing uses that are defined nowhere. Ship the counting rule and the signatures; **drop** the `/ minLen12` → `/ minLen` address change, which is unsound against domain-type inheritance and is not needed by the feature.
- **3d.** `preHashed` + `HashPolicy.produces : Producible | VerifyOnly` (D07). Zero grammar. Drop the separate `HashAlgorithm` table (`CipherPolicy.algorithm` is the existing pattern) and the per-transaction `Forced` violation.
- **3e.** `Pattern` corrections (D04). No parameterisation: pin `multiline = False` (every `^…$` predicate is currently bypassable by an embedded newline), mandate the total `Text.Regex.TDFA.String.compile`, record ASCII-only POSIX classes, add the commit-time pattern budget, fix `functions.md:87`.

Delivers: 1:many inline declaration, large payloads, bounded text, credential import, a regex engine that is not a validation bypass.

### Phase 4 — Administration and operations (depends on Phase 2c)

`ShardRef`/`ShardRange` with `StringLit` and `RecordLit` bounds · `cancel` · `ExportCmd` + `system.export.Destination` + the `export shard` retrofit · `Resolution ::= QName` (unreserving `DataCode`/`External`) · `TokenType` without `server` · `erase shard` removal · every `Ident`-typed identifier argument retyped `StringLit`.

Delivers: addressable shards, a killable query, a contained export path, and the four grammar positions that cannot parse their own documented arguments today.

### Phase 5 — Storage and distribution (parallel with 1–4; longest lead, no grammar)

- **5a.** Derived extents and arrangements (D10). One on-disk format; the `an index is a materialized view whose payload is a locator` unification; the never-set-a-custom-LMDB-comparator rule, which is a one-line rule with silent-tree-corruption blast radius and should land regardless of everything else.
- **5b.** GTID connectors (D09). Reimplement-don't-fork against `mysql-haskell` 1.3.0 — verified independently in the critique. Ship the checkpoint as data in a prunable class, not as a derived `max` over a rollup that is stale by the raw retention window.
- **5c.** Epoch and fencing (D08) — **with a two-of-three ACK.** The role triple is exactly three, so a majority is two, and one extra message on a path that already fans out to both secondaries is what actually delivers "two epochs cannot both be current."
- **5d.** `Reference`-tag doc fix (D12). The tag encodes an *edge*, not a row identity; the row keeps its `DataId` and its declared key. Retire the "`system.shards.Node` is the one exception" framing only as far as `transaction-graph.md:593-594` already states it — do **not** generalize to "any closed replicated target", which would license 2-byte edges into runtime `Configuration` rows.

### Deferred

| Item | Why |
|---|---|
| Closure / recursion (D11) | Genuine new expressiveness, orthogonal to everything here, blocked on the `Null`-in-key vs. tree-rooting tension. |
| `in` as a `CmpOp` (D05) | `` `elem` `` covers it; revisit only if the `let` nesting rule can be stated soundly. |
| `Ephemeral` trait (D06) | Decide at its own scope with `show replication lag`, connector in-flight state, and the generation table on the table. |
| Supplied-field mask (D15) | Justified only by merge reconciliation and connector conflict granularity, neither of which is designed. Merge semantics must be written first or the mask is all-ones after any merge. |
| `.dc` export format (D14) | Blocked on D13's literal *and* on a scrub-replay rule for re-import. |
| Parameterised patterns (D04) | Its motivating example does not typecheck in the position it is written (a field `where` has no cross-field scope, and FK resolution is step 6 while validation is step 2); the repaired residue is already legal. |
| `Default a` (D15), `Text 255` (D02) | Rejected by their own authors. Record the reasoning; build nothing. |

---

## (E) The three riskiest proposals

**1. D03 — Client token types.** Highest blast radius and the failures are structural, not stylistic. Widening `authed_user` to `User | NotAuthenticated` does **not** fail closed: `constraints.md:142-168` documents `not`-of-a-self-rooted-query as one of the three assert shapes, so an anonymous request satisfies every absence assert, and `constraints.md:209-211` explicitly blesses `authed_user.role is Auditor || status is Published`, which makes every published row world-readable. The same widening type-errors every `created_by :> User = authed_user` audit column — five occurrences in the docs — and `railroad.md:913` puts the binding in scope in field defaults, which the proposal never considers. Its browser case is unrepresentable in its own schema and, where it is representable, resolves the client from the attacker-controlled `Host` header for exactly the population whose Host header is attacker-controlled: `Host: ide.example.com` yields an `Operator`-tier token reaching `system.auth`. And `ClientReach` duplicates `system.auth.Grant`, which `GrantCmd` can already express today with zero grammar change (`grant system.auth.Client.WebStorefront on app.commerce` parses now), while destroying the property `namespaces.md:152-155` names as the reason bypass lives in the grant: one queryable place.

**2. D08 — CLI fixes and split-brain rejoin.** The epoch scheme's headline claim is the one thing it does not deliver. "No quorum, no witness — whoever holds the highest epoch is right" is false under the partition it exists to handle: two secondaries each observe the primary dead, each appends `AuthorityNode { epoch = N+1, primary = self }` to its own copy of a log that has now forked, and `>` cannot order them. The step-2 comparison table has no row for `peer == own, peer also claims primary`. Raft §5.1 is cited for the term number while §5.2 — the majority vote that makes it mean anything — is omitted. On the strength of this the proposal then instructs rewriting a `force elect primary` warning that is currently **true** into a reassurance that is **false**. Separately, `DataIdLit` silently misparses a legal arbitrary-precision `Decimal`, and the recommended `recover/<shard>/<epoch>` branch creates branch rows and branch shards at `UserData` cardinality — parking acknowledged client writes on the one construct `distribution.md:263` calls non-durable. The fix is cheap (two-of-three ACK, one branch per incident) which is why this ranks second rather than first.

**3. D06 — Cancelling a running query.** A two-production admin command that arrives carrying a sixth replication trait, a rewrite of the LMDB read-transaction lifetime, a fan-out control protocol, and a first-ever `Moment`-typed stored column. Each of the three large pieces is independently contested: `Ephemeral` is a durability property wearing a replication trait's clothes and contradicts D10's explicit argument in this same batch; batch-scoped LMDB transactions change read semantics in three unpriced ways (the snapshot advances, so every batch after the first walks the version chain back to the pegged node; cursors are invalidated and must re-seek; a `retain` unlink mid-scan removes rows while the result is still reported complete) and touch OQ-004's headline zero-copy result; and the control frame rides a persistent bidirectional channel that OQ-012 — **not** marked answered — does not specify. Compounding it, the design cannot see the work most likely to be wedging a server: view refresh, compaction, `Doc` shredding, and connector polls all run on `system.events.MaintenanceQueue`, have no `authed_user`, and arrive through no HTTP request, so `show queries` reports an idle cluster while the maintenance queue saturates the disk. Ranked third only because the *command* is small and separable; the risk is that three unrelated architectural bets ship attached to it.

Runners-up, for the record: **D01** builds its disposal path on two mechanisms that do not exist (`retain`-is-`LogData`-only is contradicted by a section heading; row-level orphan-prune is not a thing) and on component ordinals that start at 1, are shared per parent, and are never reused, so `B / chunk_size` is never the chunk's ordinal. **D14**'s `.dc` format reopens the export/scrub/re-import hole OQ-036 explicitly closed. **D11**'s flagship sharding lever is unwritable under `tables.md:207`, and its best-cost `Doc` case is rejected by its own admissibility rule.