# Grammar and Railroad Diagrams

## How to render

The grammar below is **W3C-style EBNF**. Paste any section (or the whole file's EBNF
blocks, concatenated) into the Railroad Diagram Generator to get SVG railroad diagrams:

> **https://rr.red-dove.net/ui.html** — mirror: **https://bottlecaps.de/rr/ui**

Steps: open the link → *Edit Grammar* tab → paste → *View Diagram*. The *Download* tab
exports standalone SVG or an XHTML page with all diagrams.

This file is the single source of truth for DataCode syntax: the EBNF *is* the normative
grammar and *also* the diagram source, so the two cannot drift. Do not hand-maintain
diagrams alongside it.

Notation: `::=` defines a rule, `|` alternates, `( )` groups, `?` optional, `*` zero or
more, `+` one or more, `'x'` is a literal token, `[a-z]` is a character class, `#xNN` is a
codepoint.

---

## Lexical

```ebnf
Ident        ::= [a-zA-Z_] [a-zA-Z0-9_]*
QName        ::= Ident ( '.' Ident )*
FieldPath    ::= Ident ( '.' Ident )*
NamePattern  ::= QName ( '.' '*' )?
ModuleName   ::= Ident ( '.' Ident )*
Host         ::= Ident ( '.' Ident )* | StringLit

Literal      ::= StringLit | NumLit | BoolLit
StringLit    ::= '"' ( [^"\] | '\' [#x20-#x10FFFF] )* '"'
NumLit       ::= [0-9]+ ( '.' [0-9]+ )?
BoolLit      ::= 'True' | 'False'
LengthLit    ::= NumLit Ident

Comment      ::= '--' [^#xA]*
```

**Capitalization is a convention, not a grammar rule.** `Ident` admits either case in every
position, and the resolver distinguishes a type from a field by position, not by initial
letter. The convention is nonetheless normative style and is checked by the linter: types,
traits, tables, derived tables, and sum-type variants are `UpperCamelCase` and singular; fields are
`lower_snake_case`; functions, predicates, and constraint names are `lowerCamelCase`;
namespace segments are `lowercase`. See [README.md](README.md#capitalization).

**`NumLit` carries no sign.** `-` is always the subtraction operator, never the first
character of a literal, because a sign inside the token makes `total - 1` lex as `total`
followed by the literal `-1` — a juxtaposition, which `FuncApp` reads as an application
rather than a subtraction. Negation is the prefix `-` in `AddExpr`, at Haskell's fixity, and
a negative literal in argument position is parenthesized: `inRange (-20) 19`.

**`LengthLit` is a numeric literal juxtaposed with an identifier** naming a `Duration` or
`Period` constant (`7 day`, `6 hour`, `1 month`). It **desugars to multiplication** — `7 day`
is `7 * day` — so the unit is an ordinary value and the factor exists in one place. No unit
words are reserved, and no ambiguity arises with function application, because a numeric
literal is not applicable: `NumLit Ident` can only be a length. It is an `Atom`, so it reaches
every expression position — an `every` interval, a `for` retention, and a field default are one
production. Maximal munch applies: a `NumLit` immediately followed by an `Ident` is always a
`LengthLit`, so an argument list passing the two separately parenthesizes them.

**Layout and termination.** Two rules, applied by the lexer before the grammar below sees
the token stream:

- **Inside a body** (`{ ... }`), declarations are separated by `,` and closed by `}`. The
  separator may be written trailing or leading; a comma immediately before `}` is permitted
  and ignored. A comma only separates at bracket depth 0 relative to the body — commas
  inside a nested `( )`, `{ }`, or `[ ]` belong to that nesting.
- **At top level**, there is no separator. A declaration ends at the next token in column 0.

**Continuation** in both cases is by indentation: a line indented deeper than the column at
which the current declaration began continues it; a line at that same column starts the next
declaration. This is what delimits a block-form `WhereClause` and a `let` block. The grammar
below is written layout-insensitively; the lexer inserts the implied separators.

`[` and `]` are single-character tokens sharing a prefix with nothing. They bracket a
`TableLit` — the one production that reaches them — which is what the layout rule above has
always assumed.

---

## Schema Files

```ebnf
SchemaFile   ::= Statement*
ScriptFile   ::= ( Statement | Mutation | LetBinding | MetaCommand )*

Statement    ::= ImportDecl
               | TypeDecl
               | TraitDecl
               | TableDecl
               | Binding
               | RetainDecl
               | StandaloneAssert
               | StandaloneUnique
               | EvolutionStmt
               | ModeStmt
               | FunctionDecl
               | TypeSigDecl

ImportDecl   ::= 'import' ModuleName ( '(' Ident ( ',' Ident )* ')' )?
```

A schema commit takes a `SchemaFile`. `--file` takes a `ScriptFile`, which is the wider form
the disaster-recovery procedure needs: configuration is rows
([traits.md](traits.md#traits-are-not-configuration)), rows are written by a `Mutation`, and a
`.dc` script that reconstructs a deployment must therefore carry both declarations and writes.
`:commit` is admissible for the same reason — a script that must land in more than one
transaction has to be able to say so. See [../cli.md](../cli.md).

---

## Types

```ebnf
TypeDecl     ::= 'type' Ident ( ':' TypeExpr | '=' TypeExpr | '=' FnType ) UsingClause? WhereClause?

FnType       ::= TypeExpr ( '->' TypeExpr )+
TypeExpr     ::= Variant ( '|' Variant )*
Variant      ::= QName TypeArg*
               | '(' TypeExpr ( ',' TypeExpr )+ ')'
TypeArg      ::= QName | Literal

UsingClause  ::= 'using' QName

TypeSig      ::= TypeExpr ( '->' TypeExpr )*
TypeSigDecl  ::= Ident ':' TypeSig
```

`type A : B` declares a domain type (subtype of `B`); `type A = B | C` declares a sum type;
`type A = B -> Read C` declares a **function type**. `TypeSigDecl` is a top-level
Haskell-style signature for a function; it is distinguished from `FieldDecl` by position —
signatures appear at file top level, field declarations only inside a table or trait body.

**A DataCode signature is written with one colon**, matching `FieldDecl`'s `:` and the "`:` is
*is a kind of*" rule the whole language turns on. There is no `::` token. Illustrative Haskell
in these documents (`commit :: Tx a -> Effect a`) keeps Haskell's spelling and is fenced as
Haskell; a DataCode standard-library signature is not.

`FnType` is admissible only in `TypeDecl`. **A `FieldDecl` may not write an arrow inline; it
names a declared function type**, which is what makes "every function in a field shares one
signature" a property of what a field *is* rather than a rule about function columns, and what
gives the signature a name for diagnostics to address. The rightmost `TypeExpr` names the
effect (`Read`, `Tx`, `Effect`); omitted, the function is `Pure`. See
[functions.md](functions.md#function-types).

`UsingClause` supplies a parameter row to a parameterised type constructor. It is valid on the
two `Secret` constructors, each naming a row in its own policy table:

| Constructor | Policy table |
|---|---|
| `Hashed` | `system.crypto.HashPolicy` |
| `Encrypted` | `system.crypto.CipherPolicy` |

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2 where minLen 12
type TotpSecret : Encrypted Text using system.crypto.CipherPolicy.totp_v1
```

It precedes `where` for the same reason `DefaultClause` does — `where` is the only clause
with an open-ended expression to its right, so everything with a fixed shape comes first.
See [types.md](types.md#hashed-types) and [types.md](types.md#encrypted-types).

At most **one** `WhereClause` per `TypeDecl`, as everywhere else. The production carried a
`WhereClause*` until this pass, which licensed `type Email : Text where a where b` in the same
file as the prose forbidding it — and, because this EBNF is also the diagram source, rendered a
loop where an optional branch belongs. `FieldDecl` was already correct.

---

## Fields

```ebnf
FieldDecl    ::= Ident RefToken TypeExpr SubTableTraits? SubTableBody? SubTableRows?
                 'unique'? IndexedClause? DefaultClause? WhereClause?

RefToken     ::= ':' | ':>'
SubTableTraits ::= ':' TraitList
SubTableBody ::= '{' TableBody '}'
SubTableRows ::= TableLit
IndexedClause::= 'indexed' ( 'using' QName )?
DefaultClause::= '=' ( Expr | SeqAlloc )
SeqAlloc     ::= 'next' Ident

WhereClause  ::= 'where' ( Expr | PredicateBlock )
PredicateBlock ::= Expr+       /* layout block: one predicate per line, indented */
```

`SourceClause` (`rename from QName`, and earlier a bare `from QName`) and `WildcardField`
(`'*' 'from' QName`) are gone. A rename is a projection that mentions the source field under a
new name, which is both shorter and the same mechanism used for every other reshaping. See
[evolution.md](evolution.md#rename-a-field).

`SubTableRows` **seeds** an inline `Reference` sub-table where it is declared, so a small code
table and its rows are one schema act rather than a declaration plus N scattered inserts:

```
f :> T : Reference { name : Text unique } [ { name = "a" }, { name = "b" } ] = T where name == "a"
```

Every part of that is a schema act, which is why all of it belongs in one schema commit: an
inline sub-table is already sugar for "declare a sibling, then reference it"
([tables.md](tables.md#inline-sub-tables)), inserting a `Reference` row is already a schema
transaction, and the default names a `Reference` row, which the stratification below permits.
The parse is unambiguous because nothing else in a `FieldDecl` begins with `[`.

At most **one** `WhereClause` per declaration. Its body is a single predicate on the same
line, or a `PredicateBlock` — an indented run of predicates delimited by the layout rule,
implicitly conjoined. There is no repeated `where` and no `and` between block entries.

Constraints not expressible in the grammar, enforced at compile time:

- `:` — no `Variant` in the `TypeExpr` may name a table.
- `:>` — the **first** `Variant` must name a table or derived table. Later variants may name
  further tables or `Null`-derived types. See the head rule in [README.md](README.md).
- `SubTableBody`, `SubTableTraits`, and `SubTableRows` are only valid with `:>`.
  `SubTableTraits` mirrors `TableDecl`'s trait list and is how an inline sub-table declares
  `Component`.
- `SubTableRows` is admissible only where `SubTableTraits` names `Reference`. On a `Component`
  or `Configuration` sub-table the rows would be *data* written by a schema commit, which is
  the cross-table in-commit write [../events.md](../events.md) refuses.
- **A `:>` field whose target carries `Component` is table-valued.** It denotes every one of
  that parent's rows in the target, in `ordinal` order. A `:>` to any other table is
  single-valued and wraps one `DataId`. A component has no `DataId`, so the field cannot be
  wrapping one; the parent-prefix range scan is what it denotes instead. See
  [tables.md](tables.md#component-sub-tables).
- A **table-valued** field is rejected in a `UniqueDecl`, in a candidate key, in an
  `OrderByDecl`, and as an operand of `==`, and is excluded from `'*'` unconditionally.
- `IndexedClause` is valid only where the `TypeExpr` is `Doc`. Its `using` names a
  `Text -> Bool` function over a document key; a key that fails it spills instead of interning.
  See [documents.md](documents.md#key-shape-rules).
- `unique`, `IndexedClause`, and `OrderByDecl` are rejected on a field whose type is `Secret` —
  every `Hashed` and every `Encrypted` type. A per-row salt makes `unique` unenforceable in
  principle, and an arrangement over ciphertext cannot mean what it says.
- Where the `TypeExpr` head is `Behavior`, the `DefaultClause` is **mandatory** and is the
  behavior's definition rather than a default — its `Expr` must be a `Lambda` of one
  parameter, bound to a `Moment`. `unique`, `indexed`, `order by`, and `WhereClause` are all
  rejected on such a field, and it may not appear in a `RecordLit`. The full rule and its
  reasoning live at [types.md](types.md#restrictions).
- Where the `TypeExpr` names a **function type**, `unique`, `indexed`, and `WhereClause` are all
  rejected, because function types have no equality. A function literal in a `DefaultClause` or
  `RecordLit` is admissible only on a `Reference` table; a `Configuration` table admits a
  `FunctorRef` and no literal. An `Effect` function type admits a name only, never a literal.
  See [functions.md](functions.md#functions-as-column-values).
- `SeqAlloc` is admissible **only** in a `DefaultClause`, and only on a field named by the
  `UniqueDecl` its `Ident` refers to. `next` is an allocation, not a value: it is rejected in a
  `WhereClause`, a `Behavior` definition, a projection, and a `Binding`. See
  [tables.md](tables.md#sequences).
- A `RecordLit` `DefaultClause` on a `:>` field whose target carries `Component`
  **constructs** the row, in the same transaction. Because the field is table-valued,
  `= { theme = Dark }` is sugar for the one-element literal `= [ { theme = Dark } ]`. On any
  other `:>` field the `DefaultClause` must resolve to an existing row — that is what distinguishes
  `settings :> Settings : Component = { … }` from `created_by :> User = authed_user`. The
  construction is a `RecordLit`, not a `SubTableBody`: `SubTableBody` precedes `DefaultClause`
  in the production and holds `FieldDecl`s, while a default holds `RecordField`s. See
  [tables.md](tables.md#a-component-default-constructs-the-row).
- **A schema object may not name a data row.** A `:>` `DefaultClause` is stratified by the
  target's trait, because which row stands behind a name is a deployment fact and staging must
  not share production's:

  | Target | Default admissible? | Why |
  |---|---|---|
  | `Reference` | **Yes** | The FK stores a 2-byte variant tag, not a `DataId`. A `Reference` row *is* schema, replicated everywhere, versioned by schema node. |
  | `Configuration` | **No** | Replicated everywhere but a deployment fact. Resolve by *name* at runtime, as `CipherPolicy.key_name` does. |
  | `UserData`, `LogData` | **No** | Shard-local *and* deployment-specific: the same schema commit means nothing in staging. |

  A literal `DataId` (`owner :> User = "05KG…"`) parses — there is no `DataId` terminal, so it
  is a `StringLit` told apart at resolution, on the `AtClause` precedent — and the
  stratification is what rejects it. A `Query` default against a `Reference` target resolves
  **once, at schema commit**, and the resulting tag is frozen into the node; it is not
  re-evaluated on read, and it must resolve to exactly one row, which the `unique` in the
  sub-table body is what guarantees.
- **Every field added to an existing table carries a `DefaultClause`**, and omitting one is a
  compile-time error. The rule binds the **effective field set** — body fields plus fields
  inherited from a trait — and binds generators as well as authors. The admissibility criterion
  is `Pure` **and stable for the life of the row**: reproducible at read from the old row plus
  the schema node, and identical to what an insert after the add would have stored. Rejected
  there: `SeqAlloc` (it allocates rather than evaluates), `authed_user` (transaction-ambient
  input rather than row data — it does resolve, to whoever is reading), a lazily evaluated `Query`,
  a `RecordLit` construction, and a `FieldPath` into a stored or mutable field. Admitted:
  literals, nullary variants, constructor application over admissible arguments, a `Pure`
  `FuncApp`, `IfExpr`/`LetExpr`/parentheses over admissible sub-expressions, and a `FieldPath`
  into an immutable virtual column (`created_at`, `origin_server`, `ordinal`, `grain`). The
  rationale, and the full form-by-form table, are in
  [evolution.md](evolution.md#redeclare-a-table).
- A `:>` field to a **`Component`** target needs no `DefaultClause` when added, because it is
  table-valued and its old-row value is the empty table — inside the declared type, no write,
  no ambient input. Only the constructing `= { … }` form is rejected there, since a
  construction needs a transaction and a row committed last year has none.
- The default must **satisfy the field's own `WhereClause`**. Under the rule above it becomes
  the value of every existing row, so a default failing its own predicate marks 100% of them in
  one commit — a schema error, not a migration choice.
- **No `unique` field may be added to a populated table.** Every admissible default is
  constant, and no injective row-local expression is spellable.
- The rejection diagnostic names the **two-step** path: a `Statement` adding the field, then a
  `Mutation` writing the values. Both are admissible in a `ScriptFile`; only the first is a
  `SchemaFile` statement, so the diagnostic must not say "a bulk mutation" and stop.
- Defaults may not form a cycle within one declaration (`a : Int = b, b : Int = a`), checked at
  schema commit exactly as the function-column call graph is. The evolution case needs no
  check: a default at node N can only mention fields existing at N, so every edge points
  strictly backwards.

A `FieldDecl`'s `WhereClause` is addressed by the field's path
(`<namespace>.<table>.<field>`), which is also the name of the field's computed type. There
is no production for naming it — see [README.md](README.md#addressing-validations).

---

## Tables, bindings, traits

```ebnf
TableDecl    ::= 'table' QName ( ':' TraitList )? '{' TableBody '}'
Binding      ::= QName ( ':' TraitList )? Param* '=' Query
TraitDecl    ::= 'trait' Ident ( ':' TraitList )? '{' TraitBody '}'

TraitList    ::= QName ( ',' QName )*

TableBody    ::= ( BodyItem ( ',' BodyItem )* ','? )?
TraitBody    ::= ( TraitItem ( ',' TraitItem )* ','? )?

BodyItem     ::= FieldDecl
               | BackRefDecl
               | '*'
               | UniqueDecl
               | AssertDecl
               | EventDecl
               | HandlerDecl
               | OrderByDecl
               | FunctionDecl

TraitItem    ::= FieldDecl | FunctionDecl | EventDecl | UiHint | '*'

BackRefDecl  ::= ':<' QName SubTableTraits? ( 'via' Ident )? SubTableBody?

OrderByDecl  ::= 'order' 'by' OrderTerm ( ',' OrderTerm )*
OrderTerm    ::= FieldPath ( 'asc' | 'desc' )?

UniqueDecl   ::= 'unique' Ident '{' FieldPath ( ',' FieldPath )* '}'
AssertDecl   ::= 'assert' Ident '{' Expr '}'

EventDecl    ::= 'on' Expr 'emit' QName RecordLit
               | 'every' Expr 'emit' QName RecordLit WhereClause?
HandlerDecl  ::= 'handler' QName

UiHint       ::= 'ui' '{' HintPair ( ',' HintPair )* ','? '}'
HintPair     ::= Ident '=' Literal
```

`Binding` names a query. It replaces `ViewDecl` and `AggregateDecl`, which named one each. A
zero-parameter binding is a derived table; a binding with parameters is a template that a
`RetainDecl` instantiates. `TableDecl` keeps its keyword because it declares storage and
constraints, which a binding declares neither of. See
[queries.md](queries.md#local-bindings).

**A `Binding`'s name is a `QName`, matching `TableDecl`.** It took a bare `Ident` until this
pass, which put every derived table at the root of the namespace tree and made
`system.auth.ServiceAccount = …` — written in four documents — unparseable. A derived table is
a table, and every table belongs to a namespace. `LetBinding` stays an `Ident`, because a local
binding has no namespace position.

`'*'` as a `BodyItem` carries forward every field of the previous version of the table that the
body does not mention. See [evolution.md](evolution.md#redeclare-a-table). It is admissible in
a `TraitBody` for the same reason and with the same meaning: without it a trait could not be
evolved additively, since omission deprecates, and a trait gaining a field is one of the two
paths the added-column default rule has to cover.

`BackRefDecl` declares a child table that holds a foreign key back to this one. It is sugar for
"declare that other table and give it a `:>` back to me" — the two produce the same graph, and
`:<` only removes the second statement. Its scope is children that are **not owned**: true
linking tables, and children with independent lifetime and their own shard placement. Owned
1:many children need no `:<`, because a `:>` to an inline `Component` sub-table is already
table-valued.

**The name goes on the right, with `via`, and the parent retains nothing** — no column, no
virtual column, no reverse relation:

```
table app.pm.Document : UserData {
  title : Text unique,
  :< Comment via document { body : Text, author :> User }
}
```

A reverse column was designed and **withdrawn**, on three arguments. It is a second spelling
for a join, which [queries.md](queries.md#joining-against-the-reference-direction) already
covers with `as` mandatory. It puts a `'*'`-exclusion special case in the language that exists
only because the feature does. And the syntax would not look like what it costs: a non-owned
child has its own `DataId` and possibly its own shard, so `Order { *, comments { … } }` hides a
cross-shard fan-out where `Order >< Comment as c` looks like the join it is. Nesting stays
available through the join plus a sub-projection, where the cost is visible.

`via` already means "names its FK back to the containing row"
([queries.md](queries.md#naming-the-nested-table)), and omitting it already has a default: the
parent's table name in `lower_snake_case`, the rule `group`'s nested tables and split fragments
both use. Putting the name on the right buys three things over a left-hand identifier: no
phantom field name sitting in a body where it is not a field, no new meaning for `via`, and
`deprecate` addresses the thing that exists (`deprecate app.pm.Comment.document`) rather than a
name on a table that does not hold it. The parse stays unambiguous because the item begins with
`:<`, so no left-hand identifier is needed to tell it from a `FieldDecl`.

`:<` rather than `<:`: `<:` is the subtyping operator in type theory, Scala and Julia, and
DataCode's `:` already *means* subtype — `type Email : Text` is `Email <: Text`. So
`comments <: Comment` would be a well-formed sentence saying the wrong thing, which is worse
than a parse error. `:<` joins the `:` munch family beside `:>` and reads as its mirror.

A `WhereClause` is only ever a field validation attached to a `FieldDecl`. It was previously
also a `BodyItem`, standing alone as a view-level row filter; a binding carries its filter in
its `Query`, so the standalone form is gone and with it the rule that position disambiguated
the two.

`AssertDecl` covers both varieties of path-constraint functor. **The variety is decided by
the body, not by the name**: a body that mentions `authed_user` is an access
constraint, and anything else is a data constraint. No name is special — `access` was
previously a magic `Ident` selecting the access variety and no longer is, and `event` was
replaced by `EventDecl` before that.

An assert body is an `Expr`. There is no separate `AssertBody` production: the rule that used
to live there — **a `Query` in boolean position asserts that its result is non-empty** — is now
stated once for every `Bool` position (see [Functions and Expressions](#functions-and-expressions)),
which is what makes `not $ <query>` parse, what lets a query be an operand of `||`, and what
gives a `StandaloneAssert` the same expressive range as an in-body one. The narrower rule
admitted a query *or* an expression and never a query inside an expression, so the one shape
OQ-005 makes mandatory for access alternatives was the one shape the grammar rejected.

`EventDecl` registers an event functor on the producing table, in one of two trigger forms.
Both fire on a `False` → `True` transition of a condition, and both take a `RecordLit` that is
an ordinary row construction against the named queue table, so the payload is typed by that
table's own fields. Retry policy is deliberately absent — it is a `system.events.QueuePolicy`
row, not part of the registration.

- **`on`** observes the transition. Across the write for a condition over stored fields; at a
  solved moment for a condition over a closed-form `Behavior`.
- **`every`** samples for it. Its `Expr` is the interval — any `Read` expression of type
  `Duration`, so a `LengthLit` (`every 15 minute`), a field of the row (`every
  poll_interval`), and a `Configuration` path are one production. The `WhereClause` carries the
  sampled condition, or restricts which rows are sampled, or both. Sampling still fires only on
  a transition, which costs a `system.events.TriggerState` row per `(trigger, row)`; schema
  commit **warns** when the condition is one the solver could have closed.

`every` is a `BodyItem` rather than a `Statement` deliberately: a timer job always has rows that
parameterize it, and attaching the declaration to that table is what keeps the payload typed
against a row it can name. There is no top-level cron form.

`HandlerDecl` appears on a queue table and names the functor that processes dequeued rows. The
two are separate productions because they describe opposite ends: `EventDecl` is the
producer's business, `HandlerDecl` is the queue's. See [../events.md](../events.md).

Constraints not expressible in the grammar:

- A `Query` reaching a `Bool` position inside a functor body — an `assert`, a field
  `WhereClause`, an `on` or `every` condition, or a template `Hole` — must be rooted at `self`,
  and every subsequent source must be reached by a `JoinClause` along a declared `:>` edge in
  either direction. An unanchored source is a compile-time error, because a constraint that
  scans would scan on every read. See [constraints.md](constraints.md#anchoring).
- `HandlerDecl` is valid only on a table carrying `Queue`, and a `Queue` table declares exactly
  one. It was previously valid on any `LogData` table; a log is not a work list.
- A `Queue` table declares exactly one `:>` field to a table carrying `QueueState`, and at most
  one field whose type is `Priority`. Both are recognized by *type*, not by name — the same
  structural reading that decides an assert's variety. Only the queue's handler may write that
  `QueueState` field. See [../events.md](../events.md#queue-tables).
- An `every` interval `Expr` must be `Read` and of type `Duration`. A literal below
  `system.events.SchedulerLimit.min_interval` is rejected at commit; a computed one is clamped
  at dispatch. A `Period` interval (`every 1 month`) is **rejected**: sampling compares an
  interval against elapsed time since the last fire, and a `Period` has no elapsed length to
  compare. A monthly job is `every 1 day` with a `where` on the day of month, which also says
  what should happen when a month has no 31st.
- A `TraitList` item is a bare `QName`: **traits take no arguments.** A trait is a declaration,
  not a tuning knob, and operational values live in `Configuration` rows instead. See
  [traits.md](traits.md#traits-are-not-configuration).
- A `TableDecl` must declare a `UniqueDecl`, a `'unique'`-marked `FieldDecl`, or inherit a
  `'unique'`-marked `FieldDecl` from a trait, unless it carries `LogData`, `Component`, or
  `Keyless`. See [tables.md](tables.md#candidate-keys-are-mandatory).
- `TraitItem` admits no `UniqueDecl`, `AssertDecl`, or `OrderByDecl`. A trait therefore supplies
  at most a single-column candidate key, and carries no access rule and no default ordering of
  its own.
- A `Binding` has no body in which to declare one, which is the grammar enforcing the rule
  rather than a check: a derived key comes from the sources and the operators applied to them,
  never written. Its asserts and uniqueness constraints are consequently standalone, and its
  field types come from its `Query`. See
  [queries.md](queries.md#keys-are-computed-never-declared).
- A `Binding`'s `TraitList` overrides the replication trait it would otherwise inherit from its
  sources; sources that disagree are an error.
- `'*'` is admissible in a `TableBody` or `TraitBody` only where a previous version exists. In a
  body containing `'*'`, an omitted field is carried forward rather than deprecated; use
  `DeprecateStmt` to drop one.
- A `FieldPath` in a `UniqueDecl` may not name a field whose type is `Secret`, `Doc`,
  `Behavior`, a function type, a table-valued `:>`, or an alternation containing a
  `Null`-derived variant.
- A `BackRefDecl` declares nothing on the containing table. It declares or amends the table its
  `QName` names, adding a `:>` field back; `via` names that field. The generated field's origin
  address is the `BackRefDecl`'s path, so redeclaring the child cannot drop it.
- At most one `BackRefDecl` naming a given child may carry a `SubTableBody`; further ones must
  carry `via`. Declaring one table twice in a single commit is an error.
- `SubTableTraits` is **rejected** on a bodiless `BackRefDecl`. `TraitList` has no terminator
  there, so `:< Comment : Component, owner :> User` would munch `owner` as a second trait — and
  a bodiless `:<` names a child declared elsewhere, whose trait is not its business.
- A `BackRefDecl` defaults the child to the containing table's replication trait, **not** to
  `Component`. This is deliberately the opposite of `group`'s nested-table default, because
  cascade-by-default is wrong for a construct authors reach for constantly, and because nothing
  outside a parent's subtree may reference a component. Both defaults are stated where they
  apply.
- A `BackRefDecl` naming the containing table must be bodiless.
- A `BackRefDecl` that adds a `:>` to a populated child is refused unless the type carries a
  `Null`-derived variant.

```ebnf
StandaloneAssert ::= 'assert' QName '{' Expr '}'
StandaloneUnique ::= 'unique' QName '{' FieldPath ( ',' FieldPath )* '}'
```

In the standalone forms the `QName` is `<table>.<constraint-name>`. Standalone is the only
form a `Binding` has, since a binding has no body — which is why the two assert productions
must share one body grammar, and now do.

---

## Retention

```ebnf
RetainDecl    ::= 'retain' QName ( 'as' QName )? ( 'using' FieldPath )? RetainBody
RetainBody    ::= RetainBranch+ | Chain
RetainBranch  ::= 'where' Expr Chain
                | 'otherwise'  Chain

Chain         ::= ( ChainStep ',' )* Terminal
ChainStep     ::= ( 'by' GrainRef )? 'for' LengthLit
Terminal      ::= ( 'by' GrainRef )? 'forever'
                | 'drop'

GrainRef      ::= Ident
```

**`drop` is a terminal, not a step.** It was a `ChainStep` alternative until this pass, which
made every `drop`-terminated chain in the corpus illegal twice over: `drop` cannot carry a `by`,
so it broke "every later step must carry one", and it counted toward the step count that decides
whether `as` is required. `forever` is different — it is a *retention length*, so `by Month
forever` is a real level meaning "keep monthly buckets indefinitely", and it ends the chain
because nothing can succeed it.

Making the terminal mandatory also puts "a chain that merely runs out is rejected" into the
grammar rather than into a constraint bullet, so discarding data is always something someone
wrote.

`RetainDecl`'s `as` names a **one-parameter `Binding`** whose parameter is a `Grain`. The chain
applies it once per level, so the grain is an argument rather than an injected column. There is
no `aggregate` keyword. See [aggregates.md](aggregates.md#a-rollup-is-a-parameterized-binding).

A `GrainRef` names a `Grain` variant — `by Hour`, `by IsoWeek`, `by Month` — and resolves by
type, the same structural reading that recognizes a `QueueState` field. It is an ordinary
`Ident`: the earlier `UpperIdent` was never defined in the lexical block and contradicted
"capitalization is a convention, not a grammar rule" in the same file. `by` and `for` are what
separate the bucket size from the retention length beside it in the same step; the capital is
the ordinary variant-naming convention, checked by the linter. This is also what keeps
`grain == Month` an ordinary comparison: `grain` is a virtual column of type `Grain` and
`Month` is one of its variants.

Constraints not expressible in the grammar:

- The **first** `ChainStep` of a chain that retains raw rows carries no `by` — it is the source
  table's own retention. Every later step, and the `forever` terminal, must carry one. A branch
  whose first step *does* carry `by` retains no raw data and rolls every row up as it is
  written; that is a legitimate policy, and it is what the `UserData` branch in
  [aggregates.md](aggregates.md#retain-on-userdata-is-admissible-and-rare) writes.
- A `Chain` that is a bare `drop` is rejected — it would discard at write, which is not a
  retention policy. A bare `forever` is the ordinary "keep everything at raw resolution".
- Each step's grain must be the **alignment parent** of its predecessor's, transitively —
  `Minute → Hour → Day → Month → Quarter → Year` or `Day → IsoWeek → IsoYear`. Coarsening
  alone is insufficient: `IsoWeek → Month` is coarser and misaligned, and merging across it
  would place a straddling week in a month it is only partly inside. See
  [types.md](types.md#grains-align-they-do-not-merely-coarsen).
- A step's retention must cover at least one complete bucket of its successor, or that
  successor's first bucket is truncated. The comparison is against the successor grain's
  **maximum** span (`Month` is 28–31 days, so `for 30 day` does not cover one), which keeps the
  check decidable and conservative. The maximum span of a `Grain` and of a `Period` is a
  checker-internal quantity, not a surface conversion — the "no `Period`/`Duration` conversion"
  rule at [types.md](types.md#three-kinds-of-time-quantity) stays true of user expressions.
- `for` takes a length, never a grain — a `Grain` has no count, so `for Day` cannot say how
  many. Both `Duration` and `Period` lengths are admitted, so a raw step may be `for 6 hour`.
- `as` is required if any branch's chain carries a `by` — on a `ChainStep` or on the `forever`
  terminal — and forbidden otherwise. A chain never reshapes; naming the binding once on the
  header is what makes a differing step unrepresentable rather than merely rejected. `drop` is
  not a level, so `retain system.logs.Debug for 7 day, drop` needs no binding.
- The named `Binding` takes exactly one parameter, of type `Grain`.
- Every aggregate function it applies must declare an associative merge with an identity if the
  chain has more than one level. `count`, `sum`, `min`, and `max` do; `avg` is rewritten to
  `(sum, count)` silently; `percentile` does not and is rejected past one level.
- A `RetainBranch` predicate may reference only the binding's group keys and the time source, so
  that no bucket can straddle two branches with different retentions.
- At most one `otherwise`, and it comes last.

See [aggregates.md](aggregates.md).

---

## Schema Evolution

```ebnf
EvolutionStmt   ::= DeprecateStmt | PruneStmt
                  | ExtendStmt | ShrinkStmt | VisibilityStmt

DeprecateStmt   ::= 'deprecate' NamePattern
PruneStmt       ::= 'prune' QName

ExtendStmt      ::= 'extend' QName 'with' Variant
ShrinkStmt      ::= 'shrink' QName 'removing' Variant 'migrate' '(' Expr ')'

VisibilityStmt  ::= 'set' 'visibility' NamePattern VisibilityLevel
VisibilityLevel ::= 'system' | 'connector' | 'internal' | 'standard' | 'featured'
```

`SplitStmt` and `MergeStmt` are gone. A split is a set of `Binding`s projecting one source, and
a merge is a `Binding` joining them — both are ordinary queries, so the derived-key rules check
losslessness that the dedicated statements could only assert. `split` and `merge` stay reserved
for `split shard` and `resolve conflict ... using merge`. See
[evolution.md](evolution.md#split-and-merge-a-table).

`DeprecateStmt` takes a `NamePattern` rather than a bare `QName` so that a polluted key table can
be cleaned in one statement. On an interned document key it demotes: the key spills from then on
and existing rows still resolve. On an `Extensible` `Reference` value it is a denylist — a
connector meeting that value records a violation instead of extending the table. See
[documents.md](documents.md#demoting-an-interned-key).

`PruneStmt` removes a **schema object** or an orphaned branch. It does not remove log rows:
those are discarded only by a `retain` chain, and a `LogData` table with no chain is never
pruned. `prune` naming a `LogData` table is rejected, with the `retain` form in the
diagnostic. See [aggregates.md](aggregates.md#pruning-is-only-ever-a-consequence).

---

## Enforcement Modes

```ebnf
ModeStmt      ::= 'enforce' ValidationRef ( 'always' | 'forward' )
                | 'monitor' ValidationRef
                | 'repair'  ValidationRef 'into' QName

ValidationRef ::= QName ( '/' Ident )?
```

`ValidationRef` addresses a validation by the path that already names it: a field path names
the field's computed type and the predicates on it, and `/ <predicate>` selects one predicate
from a block. An `assert` is addressed by its own name and takes no `/` — including under
`repair`, which is what lets an unsatisfiable path constraint hand the row to a functor that
inserts the missing one, with no new syntax.

```
enforce app.auth.User.username / minLen12 forward
monitor app.commerce.Order.billingMatch
repair  app.crm.Contact.postal_code / isDeliverable into app.events.RepairQueue
repair  app.pm.Document.hasSettings into app.events.DefaultRowQueue
```

`always` is the default and need not be written. `forward` grandfathers: the predicate binds
new and changed values, existing ones are recorded and left alone.

The `/` here is unambiguous with division because `ValidationRef` is not an `Expr` — no
production admits both at this position.

`repair`'s `into` names an ordinary queue table, the same binding `EventDecl`'s `emit` makes.
The two keep different spellings because the statements have different shapes: `emit` takes a
payload literal, while a repair's payload is fixed — it is the violating row.

Modes are not written inside `where` blocks. See [../integrity.md](../integrity.md) for why,
and for the rule that adding a predicate to a populated field requires stating one.

---

## Functions and Expressions

```ebnf
FunctionDecl ::= Ident Param* '=' Expr
Param        ::= Ident

Expr         ::= OrExpr ( '$' Expr )?
OrExpr       ::= AndExpr ( '||' AndExpr )*
AndExpr      ::= NotExpr ( '&&' NotExpr )*
NotExpr      ::= 'not' '$' Expr
               | 'not' NotExpr
               | CmpExpr
CmpExpr      ::= AddExpr ( CmpOp AddExpr )?
CmpOp        ::= '==' | '/=' | '<' | '<=' | '>' | '>=' | '=~' | IsOp
IsOp         ::= 'is' 'not'?

AddExpr      ::= '-'? MulExpr ( ( '+' | '-' ) MulExpr )*
MulExpr      ::= InfixExpr ( ( '*' | '/' ) InfixExpr )*
InfixExpr    ::= Atom ( '`' QName '`' Atom )*

Atom         ::= Literal
               | LengthLit
               | FieldPath
               | FuncApp
               | RecordUpdate
               | Lambda
               | IfExpr
               | LetExpr
               | RecordLit
               | TableLit
               | QueryAtom
               | '(' Expr ')'

FuncApp      ::= QName Atom+
RecordUpdate ::= FieldPath RecordLit
Lambda       ::= '\' Param+ '->' Expr
IfExpr       ::= 'if' Expr 'then' Expr 'else' Expr
LetExpr      ::= 'let' LetBind+ 'in' Expr
LetBind      ::= Ident '=' Expr
RecordLit    ::= '{' ( RecordField ( ',' RecordField )* ','? )? '}'
RecordField  ::= Ident '=' Expr
TableLit     ::= '[' ( Expr ( ',' Expr )* ','? )? ']'
QueryAtom    ::= Source QueryClause+
```

**A `Query` is an expression.** `QueryAtom` is the one production that says so, and it requires
at least one `QueryClause`, so it never collides with a bare `FieldPath` or with `FuncApp`.
Three things follow, and each replaces a shape that had no parse:

- `not $ <query>` derives, because `$`'s operand is an `Expr` and an `Expr` now reaches a query.
  This is the normative spelling of an absence assert.
- A bare query is an operand of `||` and `&&`, which is the *mandatory* spelling for access
  alternatives — alternatives are `||` inside one assert rather than several asserts. No
  `QueryClause` begins with `||` or `&&`, so the operand boundary is unambiguous.
- `AssertBody`, `Atom ::= '(' Query ')'`, and `Expr`'s `'$' Query` tail all retire, because
  `'(' Expr ')'` and `QueryAtom` between them cover every case those three were carrying.

**Where a `Bool` is required and the term is a `Query`, it denotes its non-emptiness.** That
rule used to be scoped to `AssertBody` position; lifting it to every `Bool` position is what
repairs all three shapes above with one change. `not` of it expresses absence. The anchoring
requirement that travels with it is stated under
[Tables, bindings, traits](#tables-bindings-traits).

**`=` versus `==`.** `=` is **binding only** and never appears as a comparison operator, as
in Haskell. It occurs in exactly five places, none of them expressions at depth 0:

| Production | Use |
|---|---|
| `DefaultClause` | field default |
| `FunctionDecl` | function definition |
| `TypeDecl` | sum-type declaration |
| `LetBind` / `LetBinding` | local and query bindings |
| `RecordField` | row construction and row update |

Comparison is always `==`. Constructor matching (ignoring payload) is `is`; exact equality
including payload is `==`.

This is also what keeps the clause order unambiguous: a bare `=` cannot occur at bracket
depth 0 inside a `where` predicate — every `=` above is either inside a bracket, inside
`let ... in`, or in declaration position — so `total : Amount = 0 where isPositive` has
exactly one parse.

**Operator spelling** follows Haskell throughout: `==`, `/=`, `&&`, `||`, `not`, `True`,
`False`. There are no `!=`, `and`, or `or` tokens.

**`let` binds one or more names**, layout-delimited, one per line, and a right-hand side may be
a query — an `Expr` reaches one through `QueryAtom`. `LetExpr` admitted a single `Ident` and an
`Expr` that could not reach a query until this pass, which left the two-binding login example in
[../auth.md](../auth.md) — the canonical shape for "resolve a user, then resolve their
credential" — with no production at all.

**Membership is `` `elem` ``**, an ordinary backtick infix over a `Table a`:

```
status `elem` [Pending, Shipped]
{ customer = c, order_num = n } `elem` app.commerce.Order
```

**There is no `in` operator**, and none is added. `in` is already reserved by `let … in`, and
admitting it as a comparison creates a real ambiguity: the proposed disambiguation ("the first
`in` at bracket depth 0 closes the binder") does not count `let` nesting and breaks
`let a = let b = 1 in b + 1 in a * 2`, which parses today. `elem` costs one bracket-literal
production and no reserved word. The multi-field form uses a `RecordLit` rather than a tuple —
it reuses a production that already exists, binds by name rather than position, and makes the
element shape identical to the one the insert literal uses. One element shape everywhere.

**`=~` is regex match**, `Text -> Text -> Bool`, evaluated by `Text.Regex.TDFA`. It had been
lexed and used since the first draft of [functions.md](functions.md) without appearing in any
production; it is a `CmpOp`. Its **right operand is restricted by trait**: a `StringLit`, a
`FieldPath` into a `Reference` table, or a `FieldPath` into a `Configuration` table. Anything
else — a user-supplied value, a field of the row being matched — is a compile-time error
naming the three. The two admissible table sources differ in one respect worth knowing:

| RHS | Resolved | Malformed pattern |
|---|---|---|
| `StringLit` | compile time | rejected at schema commit |
| `Reference` path | compile time — a `Reference` insert *is* a schema commit | rejected at schema commit |
| `Configuration` path | runtime | runtime error on the affected rows |

The compiled-pattern cache therefore keys on the `Configuration` row's version. The restriction
exists to keep patterns out of untrusted hands — provenance and transparency: a pattern is
schema, reviewable and versioned — plus a commit-time pattern budget that bounds the cost. It
had been justified instead by "TDFA is a DFA engine, so a pathological pattern costs no more
than a linear scan," and that is **false**: TDFA builds its DFA lazily and caches states, and a
ten-character pattern was measured exhausting a 3 GB heap. The restriction survives its
justification; the justification is replaced.

Three engine properties are normative rather than incidental:

- Matching is pinned to `multiline = False`. The library default is `True`, which makes `^…$` a
  *line* anchor, so every anchored validation would be bypassable by embedding a newline.
- **POSIX character classes are rejected in a pattern.** TDFA implements them ASCII-only, so
  `é` does not match `^[[:alpha:]]$` and an internationalised validation silently rejects valid
  data. Write the class out, or use an ordinary `Text` predicate.
- Case sensitivity is a property of the **pattern**, not of `=~`. A `StringLit` pattern is
  case-sensitive, because literals are exact; a `Reference` pattern row carries its own
  `case_sensitive` field, which is the "a declaration that must name a policy names a row" rule
  the `Hashed … using` shape already establishes.

**A right-hand side is a `Query` if it contains a `QueryClause`** and an `Expr` otherwise. The
two cannot both apply: an `Expr` reaches a query only through `QueryAtom`, which is that same
condition written as a production. The rule applies in five places — inside parentheses, on the
right of `$`, on the right of a `Binding`'s `=`, on the right of a `LetBind`'s, and inside a
template `Hole`:

```
count (Orders group { customer })
count $ Orders group { customer }
ActiveOrder = Order where status is Active     -- Query
taxRate     = 0.07                             -- Expr
```

**Backtick infix.** Any named function may be written infix by enclosing it in backticks, as
in Haskell, with Haskell's default fixity for the form: `infixl 9`, tighter than every
operator and looser than juxtaposition.

```
attempt `matches` user.password
(f x) `matches` y == z          -- parses as ((f x) `matches` y) == z
```

This is what makes two-argument predicates read as the assertions they are rather than as
function calls, which matters most where a functor is being read for review rather than
written.

**`$` application.** `$` is low-precedence right-associative application, `infixr 0`, exactly
as in Haskell — looser than `||`, so everything to its right is one argument. Its practical
effect is an opening parenthesis that closes at the end of the expression:

```
not $ isDisposableDomain e || isBlockedDomain e
-- equivalent to
not (isDisposableDomain e || isBlockedDomain e)
```

`NotExpr` carries an explicit `'not' '$' Expr` alternative for this. `not` is a prefix
operator here rather than a function, so `$` could not fall out of the operator table the way
it does in Haskell — without the alternative, `not $ …` was written throughout
[functions.md](functions.md) and [../auth.md](../auth.md) but parsed nowhere. Bare `not` still
binds tightly: `not a || b` is `(not a) || b`.

**Lexing.** Several operators share a prefix; maximal munch applies in every case:

| Prefix | Tokens |
|---|---|
| `=` | `=`, `==`, `=~` |
| `/` | `/`, `/=` |
| `-` | `-`, `--` (comment) |
| `\|` | `\|`, `\|\|` |
| `:` | `:`, `:>`, `:<`, and the `MetaCommand` literals `:use`, `:describe`, `:history`, `:commit`, `:rollback`, `:explain`, `:help` |
| `>` | `>`, `>=`, `><` |
| `<` | `<`, `<=` |

`$`, `` ` ``, `[`, and `]` share a prefix with nothing and are single-character tokens. `` ` ``
is valid only in matched pairs enclosing a `QName`. There is no `::` token.

The `\|` / `\|\|` pair deserves attention: `\|` is heavily loaded already (sum types, unions,
outer-join guards) and `\|\|` is boolean or. Munch resolves it, but a missing space in
`A \|\| B` where `A \| \| B` was meant will parse as a boolean expression rather than a type.

Constraints not expressible in the grammar:

- A `TableLit` denotes a value of type `Table r`. It is never a `TypeExpr`, so no field may be
  list-typed; a repeating group is a sub-table.
- Where the position fixes the row type — an insert target, an `` `elem` `` right operand, a
  nested column — a `TableLit`'s elements are checked independently against that type and an
  omitted field takes its declared default, identically to the single-row `RecordLit` form. In
  a standalone position the elements must share one type, since one must be minted from them.
- Elements bind by name. There is no positional element form: `Atom` admits no tuple, and the
  tuple in `Variant` is a `TypeExpr`.
- An empty `TableLit` is admissible only where its position determines the element type.
  Elsewhere it is a compile-time error naming the ambiguity.
- A `TableLit` is unordered as a value. In insert position its textual order is the order the
  generated mutations are applied, which is what assigns `Ordinal` and orders `DataId`s.
- A `QueryAtom` in a `FuncApp` argument list must be parenthesized or introduced by `$`, so
  juxtaposition never silently absorbs a `QueryClause` into an argument.
- `RecordUpdate` is told from `FuncApp` by one token of lookahead past the brace: a `RecordLit`
  is never an argument to a function, so `order { total = … }` is functional record update —
  the shape a function body writes. The same lookahead separates a `Projection` from a row
  update in query position.

---

## Queries and Mutation

```ebnf
Query        ::= Source QueryClause*

Source       ::= QName
               | TableLit
               | '(' Query ')'

QueryClause  ::= JoinClause
               | WhereClause
               | GroupClause
               | OrderByDecl
               | Projection
               | AtClause
               | DiffClause
               | LimitClause

JoinClause   ::= '><' JoinSource ( 'via' QName )? ( 'as' Ident )?
JoinSource   ::= TypeExpr
               | '(' Query ')' ( '|' TypeExpr )*
GroupClause  ::= 'group' Projection
AtClause     ::= 'at' StringLit
DiffClause   ::= 'diff' StringLit 'to' StringLit
LimitClause  ::= 'limit' NumLit

Projection   ::= '{' ProjItem ( ',' ProjItem )* '}'
ProjItem     ::= FieldPath Projection? NameClause?
               | Expr NameClause
               | ( QName '.' )? '*'
NameClause   ::= 'as' Ident ( ':' TraitList )? ( 'via' Ident )?

LetBinding   ::= 'let' Ident '=' Query

Mutation     ::= Insert | Update | Delete
Insert       ::= QName RecordLit
               | Query TableLit
Update       ::= Query RecordLit
Delete       ::= 'delete' Query
```

A `Source` `QName` of one segment is a `let`-bound local or a name in the current namespace;
the grammar needs no separate `Ident` alternative for it.

`Delete` has one spelling. It appends a tombstone version like any other mutation, so the row
remains readable at every earlier sample moment — see
[queries.md](queries.md#delete-appends-a-version) for why the `delete!` variant was withdrawn.

`JoinClause`'s `JoinSource` is a `TypeExpr` so that outer joins are written with the same `|`
alternation as a nullable `:>` field. The parenthesized `Query` alternative exists so that an
outer-joined source can carry its own filter inside the join term, which is mandatory. See
[queries.md](queries.md#filter-before-guard).

`GroupClause` takes a `Projection`, whose items are the group keys. Every column they do not
mention collapses into a generated table-valued column named `rows`, which the following
`Projection` shapes and aggregates. See [queries.md](queries.md#grouping).

**Nesting is a sub-`Projection` on a `ProjItem`, not a clause.** A `ProjItem` whose head
`FieldPath` is table-valued may carry its own `Projection`, which nests it. That one rule
covers every source of a nested column — the `rows` a `group` generates, a `Component` `:>`
field, a `:<` child reached by a join — so a `nest` clause is unnecessary and none exists. It
also keeps nesting a claim of authorship: a nested column appears because someone wrote the
sub-projection.

`NameClause` covers three jobs at once, because all three name the same thing:

| Part | Applies to | Effect |
|---|---|---|
| `as Ident` | any `ProjItem` | Names the column |
| `: TraitList` | a table-valued column | Overrides its inherited traits |
| `via Ident` | a table-valued column | Names its FK back to the containing row |

There is no `Aggregate` production. Aggregate functions are ordinary functions applied to a
table-valued column (`count rows`, `sum rows.bytes_sent`), so a user-defined one is admissible
wherever the built-in ones are, and `sum`, `count`, `min`, `max`, and `avg` are not reserved.
Row numbering is the same shape: `numbered <table>` is an ordinary function returning the table
plus a generated `n` column, taking its ordering as a parameter rather than reading it from an
enclosing clause.

Constraints not expressible in the grammar:

- `via` in a `JoinClause` resolves to a declared `:>` field, or to a `Null`-derived **type**,
  which means the join has no condition. `A >< B` where no `:>` edge connects the two is a
  compile-time error naming both fixes. See [queries.md](queries.md#cross-products).
- `JoinClause`'s `as` is **mandatory when a source joined against the reference direction is
  named anywhere in the query** — in a `where`, a `Projection`, or a variant test. Such a column
  has no `:>` field to name it, and the bare table name would read as though the table were the
  value. In the forward direction `as` is always optional.
- A `ProjItem` whose head `FieldPath` names a source field removes that field from any `*` in
  the same `Projection`, whether or not it carries a sub-`Projection`. This is what makes
  `{ *, status as account_status }` a rename. See [queries.md](queries.md#the--selector).
- A table-valued column is excluded from `*` **unconditionally**. Nesting is authored, never
  inherited.
- Inside a `Projection`, a `{ … }` following a `FieldPath` is a sub-`Projection`, never a
  `RecordUpdate`. A row update is a `Mutation`, and a `Mutation` is not a `ProjItem`.
- `: TraitList` and `via` are admissible only where the item is table-valued.
- A group key named `rows` is rejected.
- Ordering within a nested column is declared in its source term — `>< (OrderLine order by qty
  desc) as line`, or the child's own declared `order by` — never by an `OrderByDecl` after the
  projection.
- `ordinal` is available on a **stored** `Component` table and unavailable on a nested table
  produced by `group` or by a sub-`Projection`. Nothing was inserted in any order there, so
  there is no ordinal to report.
- **`limit` requires a total order**, and it comes from an explicit `order by`, else the
  source's declared one, else the candidate key ascending. **Any stated order is extended by the
  candidate key as a final tiebreak**, because `order by placed_at desc` is not total: fifty
  orders sharing a timestamp put a page boundary mid-tie, and a resume predicate then either
  skips the rest of the tie or repeats it. `limit` on a degenerate-keyed source that declares no
  ordering is a compile-time error. See [queries.md](queries.md#ordering).
- **There is no offset**, and none is added. Pagination is a cursor: given a total order,
  "resume after the last row" is `where (ordering tuple) > (last values)`, an ordinary `where`,
  so DataCode gets cursor pagination for free and would have to *add* a production to get
  offset. Offset is O(offset) and hides it — every shard must produce and discard its prefix so
  the coordinator can merge, and nothing in the syntax says so.
- A `QName` followed by a `RecordLit` with no intervening `QueryClause` is an `Insert`; a
  `Query` carrying at least one `QueryClause` followed by a `RecordLit` is an `Update`; a
  `Query` followed by a `TableLit` is always an `Insert`. Without the first rule
  `Order { status = Shipped }` derives from both productions, and the two readings differ
  catastrophically — create one row, or append a version to every row in the table.
- Within one `Insert`, two elements agreeing on a base table's candidate key denote one row of
  that base, and a non-key column of that base differing between them is rejected. Two elements
  agreeing on the target's full derived key are rejected as duplicates. Decomposition never
  upserts.
- A write target admits only `JoinClause`, `WhereClause`, and `Projection`. `at`, `diff`,
  `group`, `order by`, and `limit` are rejected in `Insert` and `Update` target position.
- Write-through admissibility is stated **per nesting level**: each level's key must be a
  superkey of its parent's, each nested column must be an unaggregated table-valued path, and
  every undefaulted field of each base must be projected or fixed by that level's `where`. See
  [queries.md](queries.md#writing-through-a-derived-table).
- A value supplied by decomposition — a `where` constant equality, or a generated back-FK — is
  attributed to the writer, not to a default.

`AtClause`'s `StringLit` is a version token (graph node hash prefix, tag, or branch name) or
an ISO-8601 moment; the two are told apart at resolution, not by the grammar. Where it is
omitted the sample moment defaults to request arrival. Every query is evaluated at exactly
one moment, resolved once by the coordinating server and passed to each shard as a value —
see [queries.md](queries.md#every-query-has-a-sample-moment).

`DiffClause`'s two `StringLit`s are version tokens only — never moments — because a diff must be
reproducible and a moment is not a graph position. It is rejected alongside an `AtClause` in the
same query, and rejected on a query whose derived key is degenerate, since nothing would then
identify a row across the two points. The result adds three generated columns, `before`, `after`,
and `change`; see [queries.md](queries.md#diffing-two-transaction-points).

---

## Templates

```ebnf
TemplateBody ::= ( TemplateText | Hole )*
Hole         ::= '{{' Expr ( 'using' QName )? '}}'
TemplateText ::= /* any run of characters containing no '{{' */
```

That is the entire template language. There is no `if`, no `each`, and no `unless`, because the
**result count of a `Hole`'s `Query` is the control flow**: zero rows render nothing (the
conditional), one row renders once (plain interpolation), N rows render N times joined by the
template's separator (the loop). `self` is a query of one row, so `{{ self.order_num }}` is the
degenerate case of the same production rather than a second form.

A `Hole` takes an `Expr`, which reaches a query through `QueryAtom`, so the Query-versus-`Expr`
rule at [Functions and Expressions](#functions-and-expressions) is what decides which a hole is
— a fifth position for that rule. This is what makes `{{ money self.total }}` parse: formatting
is an ordinary function call, which is the whole reason the template language needs no filters,
and a `FuncApp` is not a `Query`. The `Hole` production took a `Query` alone until this pass, so
every formatted hole in [templates.md](templates.md) was ungrammatical. An `Expr` hole is the
one-row degenerate case.

`using` names the template applied per row. Omitted, the active theme's render function for the
row's type applies, which is what makes the template system and the theme system one mechanism.
It is the existing `UsingClause` token in a wider position — same meaning, "supply this
parameterizing thing".

The separator is a field on the template's `Reference` row, not part of the `Hole`. Two
templates differing only in separator are two rows, which is cheap, and it keeps a `Hole` at two
parts.

Constraints not expressible in the grammar:

- A `Hole`'s `Query` must be rooted at `self`, every subsequent source reached along a declared
  `:>` edge — the same anchoring rule an `assert` body carries, and for the same reason: a
  template renders per row on every read that reaches it.
- A `Hole` is `Read`. `Tx` and `Effect` are both rejected, so rendering cannot write or call out.
- The negative branch has no syntax and needs none: outer-join a `Null`-derived catch-all and
  the render function for the absence variant handles the empty case. The
  filter-inside-the-join-term rule above applies unchanged.
- Escaping follows the output type. Emitting unescaped markup requires an `Html` value, which
  only a template or a render function produces, so there is no raw-output form.
- Templates naming templates must form an acyclic graph, checked at schema commit like any other
  function-column call graph.

See [templates.md](templates.md).

---

## CLI Invocation

```ebnf
CliInvocation ::= 'datacode' CliFlag*

CliFlag       ::= '--host' Value
                | '--port' NumLit
                | '--client-token' Value
                | '--user-token' Value
                | '--exec' StringLit
                | '--file' Path
                | '--shard' ShardRef
                | '--format' Format
                | '--limit' NumLit

Format        ::= 'table' | 'json' | 'csv' | 'raw'
Value         ::= Ident | StringLit
Path          ::= StringLit | [^#x20#xA]+
```

`--limit` sets the page size for the session, overriding `system.config.PageSize`. It applies
to a `ShowCmd` and to a `Query` that declares no `LimitClause` of its own; an explicit `limit`
in the statement wins. `--shard` takes a `ShardRef`, so a session can be pinned to one concrete
shard rather than to a family.

---

## REPL

```ebnf
ReplInput    ::= MetaCommand
               | Statement
               | Query
               | Mutation
               | LetBinding
               | AdminCommand

MetaCommand  ::= ':use' QName
               | ':describe' QName 'deep'?
               | ':history' QName HistoryOpt*
               | ':commit'
               | ':rollback'
               | ':explain' Query
               | ':help'

HistoryOpt   ::= 'since' StringLit
               | 'limit' NumLit
```

`:describe … deep` follows the containment edges — inline sub-tables, `:<` children — rather
than listing only the table's own fields. `deep` is the word `verify shard … deep` already
reserved and means the same thing there.

---

## Administration

```ebnf
AdminCommand ::= ShowCmd | ServerCmd | ShardCmd | ConnectorCmd | TokenCmd | GrantCmd
               | MatViewCmd | ErasureCmd | ExportCmd | CancelCmd | DrCmd

ShardRef     ::= QName ( '/' StringLit | ShardRange )?
ShardRange   ::= 'from' ( Literal | RecordLit ) ( 'to' ( Literal | RecordLit ) )?
               | 'to' ( Literal | RecordLit )

ShowCmd      ::= 'show' ShowTarget ReportClause*
ReportClause ::= WhereClause | OrderByDecl | LimitClause | Projection

ShowTarget   ::= 'servers'      ( 'for' 'shard' ShardRef )?
               | 'shards'       ShardRef?
               | 'queries'      ( 'on' Host )?
               | 'replication' 'lag' ( 'for' 'shard' ShardRef )?
               | 'connectors'
               | 'connector' 'conflicts' QName
               | 'tokens'       ( 'type' TokenType )?
               | 'grants'       ( 'for' QName )?
               | 'materialized' 'views' ( 'shard' ShardRef )?
               | 'transactions' ( 'shard' ShardRef )? ( 'since' 'seq' NumLit )?
               | 'transaction'  StringLit
               | 'violations'   ( 'for' ValidationRef )? ( 'shard' ShardRef )?

ServerCmd    ::= 'elevate' 'secondary' Host 'to' 'primary'  'for' 'shard' ShardRef
               | 'demote'  'primary'   Host 'to' 'tertiary' 'for' 'shard' ShardRef

ShardCmd     ::= 'describe' 'shard' ShardRef
               | 'split' 'shard' ShardRef 'at' 'key' ( Literal | RecordLit )

ConnectorCmd ::= 'describe' 'connector' QName
               | 'add' 'connector' Ident StringLit RecordLit
               | ( 'pause' | 'resume' ) 'connector' QName
               | 'resolve' 'conflict' StringLit 'using' Resolution

Resolution   ::= QName | 'merge' RecordLit

TokenCmd     ::= 'issue' 'client' 'token' 'for' StringLit 'scoped' 'to' QName
               | 'revoke' 'token' StringLit
TokenType    ::= 'client' | 'user'

GrantCmd     ::= 'grant'  QName 'on' QName ( 'bypass' BypassKind+ )?
               | 'revoke' 'grant' QName 'on' QName
BypassKind   ::= 'access' | 'erasure'

MatViewCmd   ::= 'materialize' QName
               | 'refresh' 'view' QName ( 'at' StringLit )?
               | 'drop' 'materialized' 'view' QName

ErasureCmd   ::= 'erase'   QName StringLit ReasonClause
               | 'erase'   'shard' ShardRef ReasonClause
               | 'scrub'   FieldPath 'at' 'seq' NumLit ReasonClause
               | 'release' 'unique' FieldPath StringLit ReasonClause

ExportCmd    ::= 'export' Query 'to' Ident StringLit ( 'as' ExportFormat )? ReasonClause?
ExportFormat ::= 'json' | 'jsonl' | 'csv' | 'tsv'

CancelCmd    ::= 'cancel' StringLit ReasonClause?

ReasonClause ::= 'reason' StringLit
```

**One `show`, one set of report clauses.** `TxnCmd` and `IntegrityCmd` were separate
productions carrying their own `( 'limit' NumLit )?` tails, and `show replication lag` sat in
`DrCmd`; folding all three into `ShowCmd` gives every administrative report the same filtering,
ordering, projection and paging with no per-command syntax. `ReportClause` is deliberately
narrower than `QueryClause`: `at`, `diff`, `group` and `><` would make a degraded server
execute joins and resolve historical version tokens, which is what the degraded path exists to
avoid.

`ShardRef` addresses one shard, a shard family, or a range of shards, so an operation no longer
has to name a family and hope. `ShardRange` bounds are values of the family's placement key,
and a `RecordLit` is the spelling for a composite one.

`Resolution ::= QName` unreserves `DataCode` and `External`. They were reserved solely so this
one production could name them, which made `authority : DataCode | External | Symmetric` — the
field whose values they are — unlexable. They are ordinary variants resolved by name, the same
correction the magic `access` identifier got.

`CancelCmd` stops a running query, named by the identifier `show queries` prints. That
identifier carries its coordinating server, so the command takes no host. `cancel` is the one
reserved word this section adds, and it is reserved because it leads a statement, where
`Query ::= Source` and `FunctionDecl ::= Ident Param* '=' Expr` both begin.

`ErasureCmd` covers the only operations that remove anything, and none of them appears in
`Query` or `Mutation` — the removal path is administrative by construction, which is the
constraint that withdrew `delete!` rather than giving it these semantics.

Constraints not expressible in the grammar:

- **Every argument naming a row is a `StringLit`, never an `Ident`** — a token, a transaction, a
  conflict, an erasure subject, a cancelled query. A rendered `DataId` begins with a digit and
  cannot lex as an `Ident`, so the three positions that took one (`revoke token`,
  `show transaction`, `resolve conflict`) could not parse their own documented arguments;
  `erase` and `release` already took a `StringLit`, and that is the shape now applied
  everywhere. `add connector`'s `Ident` is not affected: it names a connector being created, not
  a row being addressed. There is no `DataId` terminal — telling one from an ISO-8601 moment or
  a version token is resolution's job, on the `AtClause` precedent — and a composite placement
  key is a `RecordLit`, which no lexical terminal could express.
- `show queries` reads no table. Running queries are server state, not rows, so the report
  renders from memory and merges across servers through the same broadcast path
  `show violations` uses on a degraded cluster. No replication trait is involved, and none is
  added for it.
- A `ShardRef`'s bare `QName` names a shard family; `QName '/' StringLit` one concrete shard; a
  `ShardRange` every shard whose placement interval intersects it. Ranges are half-open,
  `[lower, upper)`.
- `describe shard`, `show transactions`, `replay`, `export shard`, and `import shard` take the
  concrete form only.
- A `ShowCmd` with no explicit `LimitClause` is capped at `system.config.PageSize`, resolved
  most-specific-first. The cap applies to the `table` and `json` output formats and not to `csv`
  or `raw`, because a pipe cannot carry a truncation footer and a silently truncated export is
  worse than a slow one.
- `TokenType` has no `server` alternative. A server is a `Client` kind that cannot be narrowed,
  so its credential is a client token; two names for one thing is what the `Client`/`Registration`
  split removed. See [../auth.md](../auth.md).
- `ExportCmd`'s `Ident` names a `system.export.Destination` row, and the `StringLit` is relative
  to that row's `root`. A `..` segment, an absolute prefix, or a symlink resolving outside
  `root` is rejected. Default deny: no `Destination` row, no export. The `export shard` form in
  `DrCmd` takes the same pair, so disaster-recovery exports get the same containment and the
  same audit trail.
- `ReasonClause` is mandatory on every `ErasureCmd` form, and on an `ExportCmd` whose source
  carries `Personal`. Each writes a graph node carrying the target, the authority, and the
  reason, for the same reason a `Waived` violation carries one.
- A `Secret` column serializes as `Sealed` in every export format.
- `erase` requires the named table to carry `Personal`
  ([traits.md](traits.md#personal)). `erase shard` names a shard root and cascades through the
  foreign-key chain.
- `release` is rejected where the named `unique` is or contains a root table's placement key, and
  where the owning row is neither deleted nor erased. See
  [../distribution.md](../distribution.md#a-reserved-value-is-released-only-deliberately).
- `export` is unambiguous between its two forms because `shard` is reserved and so cannot head a
  `Query`'s `Source`. `to` terminates the `Query`: no `ReportClause` begins with `to`, and the
  only `to` inside a query is `DiffClause`'s, consumed immediately after a `StringLit`.

Automatic scrubbing has no command. It is driven by `system.crypto.ScrubRule`, an ordinary
`Configuration` table, on the self-hosting principle that keeps violation waivers out of this
grammar. See [../integrity.md](../integrity.md#scrub-rules-are-configuration).

`show violations` is the only integrity command with its own syntax, and it exists only as a
convenience for the degraded-server case. Waiving a violation, acknowledging one, and raising
one by hand are ordinary mutations against `system.integrity.Violation` — it is a table, and
the self-hosting principle says system concerns that can be expressed as tables should be:

```
system.integrity.Violation where subject == "05KG..." { state = Waived "legacy import, TICKET-4471" }
system.integrity.Violation { subject_table = ..., subject = ..., origin = Forced, ... }
```

---

## Disaster Recovery

```ebnf
DrCmd        ::= 'force' 'elect' 'primary' Host 'for' 'shard' ShardRef
               | 'verify' 'shard' ShardRef 'deep'?
               | 'replay' 'shard' ShardRef 'from' 'seq' NumLit 'to' 'seq' NumLit
               | 'export' 'shard' ShardRef 'to' Ident StringLit ( 'at' 'seq' NumLit )?
               | 'import' 'shard' ShardRef 'from' Ident StringLit
               | 'force' 'sync' Host 'for' 'shard' ShardRef
```

`show replication lag` moved to `ShowCmd`, where it picks up filtering and paging like every
other report. Elevation is automatic — a shard whose primary dies promotes a secondary on its
own — so `force elect` is the operator override, and moving authority *back* is `demote`, which
stays manual: elevation restores availability, failback only rebalances.

---

## Reserved Words

```
acknowledge  add    always    as        assert    asc       at        by
bypass    cancel    conflict  conflicts connector deep      delete    demote
deprecate describe  desc      diff      drop      elect     elevate   else
emit      enforce   erase     erasure   every     export    extend    False
flag      for       force     forever   forward   from      grant     grants
group     handler   if        import    in        indexed   into      is
issue     lag       let       limit     materialize         materialized
merge     migrate   monitor   next      not       on        order     otherwise
pause     primary   prune     reason    refresh   release   removing  repair
replay    replication         resolve   resume    retain    revoke    scoped
scrub     secondary seq       servers   set       shard     shards    show
shrink    since     split     sync      table     tertiary  then      to
token     tokens    transaction         transactions        trait     True
type      ui        unique    using     verify    via       view      views
violations          visibility          waive     where     with
```

**Six words were unreserved** when aggregate functions became ordinary functions: `aggregate`,
`sum`, `count`, `min`, `max`, and `avg`. `aggregate` now names a *concept* — any function from a
table to a scalar — rather than a declaration, and the other five are library functions like any
other. `view` survives only in `refresh view` and `drop materialized view`; there is no `view`
declaration. `split` and `merge` survive only in `split shard` and `resolve conflict ... using
merge`.

**Two more were unreserved with `Resolution ::= QName`:** `DataCode` and `External`. See
[Administration](#administration) for why — they were reserved so one production could name
them, and that made the field whose values they are unlexable. **`key` went with them**, as a
contextual literal — see below.

**`cancel` is the one word added**, and it is added because it is genuinely ambiguous otherwise:
it appears in leading position, where `Query ::= Source` and `FunctionDecl ::= Ident Param* '='
Expr` both begin. `conflicts` is not an addition but a list repair — `show connector conflicts`
has always consumed it, while every sibling plural (`shards`, `servers`, `grants`, `tokens`,
`views`, `transactions`, `violations`) was already listed.

### Contextual literals

Some tokens are keywords only in one fixed position and are **not** reserved, because no
identifier is admissible where they occur: `VisibilityLevel`'s `system`, `internal`, `standard`
and `featured`; `Format`'s `json`, `csv` and `raw`; `ExportFormat`'s `jsonl` and `tsv`;
`TokenType`'s `client` and `user`; `ShowTarget`'s `queries`; `ShardCmd`'s `key`;
`CliInvocation`'s `datacode`; and `BypassKind`'s `access`. `user` in particular must stay
usable — `authed_user` is spelled the way it is precisely so `user` remains the obvious field
name in a permissions schema, and `key` is the obvious field name on any table of interned
document keys.

`key` was in the reserved list until this pass, and freeing it is what applying the rule
consistently produces: it occurs once, after `at` in `split shard … at key`, where no identifier
is admissible.

### Words a schema wants and does not get

Three plausible field names stay reserved. A declaration using one as a field name is the
defect, not the reservation:

- **`order`** — `order by` is the ordering declaration in both a `TableBody` and a `Query`, and
  those are positions where a bare identifier *is* admissible. Genuinely ambiguous.
- **`handler`** — `HandlerDecl` is a `BodyItem`, which begins with an identifier exactly as a
  `FieldDecl` does. Genuinely ambiguous.
- **`reason`** — contextual, and reserved anyway. This is the one deliberate exception to the
  rule above: an operation that destroys evidence must carry why in a position the grammar
  guarantees, not in an optional record literal that can be left off.

`erasure` is the one `BypassKind` literal that is reserved. `access` had to be freed because it
had been a magic `Ident` the compiler treated specially (below); `erasure` never was, no schema
in the corpus wants it as a field name, and it stays with the rest of the
`erase`/`release`/`scrub`/`reason` family.

### Contextual Bindings

`self` and `authed_user` are **not** reserved words. They are bindings supplied by the
context an expression is evaluated in, resolved through the same namespace lookup as any
other identifier and shadowed by nothing, because no declaration may introduce a name that
collides with a binding in scope.

| Binding | Bound to | In scope |
|---|---|---|
| `self` | the row under evaluation | trait function bodies, `assert` bodies, `on`/`every` conditions and payloads, `Hole` queries, function-column bodies |
| `authed_user` | the requesting user token's row | `assert` bodies, field defaults evaluated at insert |

`self` has been used in trait function bodies since [traits.md](traits.md) was written without
being listed anywhere; it is listed here now. `authed_user` replaces the earlier `user`, which
read like a table name and would have collided with the likeliest field name in any
permissions schema — including DataCode's own.

`authed_user` is scoped to defaults **evaluated at insert** because it is transaction-ambient
input rather than row data — the same shape as *time is a parameter, never ambient*. On a field
added to an existing table it would resolve on the read path instead, to whoever is reading, so
`created_by` would differ between two readers of one row. Silent divergence is worse than
failure, which is why the added-column rule rejects it outright.

**There is no `authed_client` binding.** Client tokens restrict access at the schema level and
that restriction is configuration in `system.auth.*`, so admitting the client into an `assert`
would put one decision in two places. Which rows a request may reach is what an assert decides;
what a client kind may reach at all is what a `system.auth.Client` row decides. See
[../auth.md](../auth.md).

`and` and `or` are **not** reserved — boolean conjunction and disjunction are the operators
`&&` and `||`. (In Haskell `and` and `or` are list functions, not operators; reserving the
words here would have misled.) `not` is a reserved prefix operator, as in Haskell.

Words that were considered and deliberately **not** reserved:

- **`delete!`**, as a hard delete alongside the soft `delete`. This one was reserved and has
  been **withdrawn**. The distinction it drew was not a distinction — both spellings left the
  record in the transaction graph and removed the row from the current state, which is what a
  delete is. The operations that would have earned the sigil are `erase` and `scrub`; both are
  `ErasureCmd` productions, administrative rather than row mutations, and neither is spelled as
  a variant of `delete`.

- **`write`**, as in an `enforce … on write` spelling of the grandfathering mode. `write` is
  a likely field name in any permissions table, including DataCode's own. The mode is spelled
  `forward` instead — one word, symmetric with `always`, no collision.
- **`open`**, as a modifier marking an extensible `Reference` table. `open` is a likely
  boolean field name. Extensibility is a marker trait (`Extensible`) instead, which needs no
  keyword at all and composes through the existing trait list.

- **`becomes`**, as in `on status becomes Shipped`. It would have been sugar for transition
  semantics that every `on` condition already has, and a keyword that only restates the
  default rule is not worth reserving. `on status is Shipped` means the same thing.

- **`never`**, as a retention terminal meaning "discard when this expires". In a construct
  full of durations it reads as "never delete" — the opposite of what it would mean. The
  terminal is `drop`, which is already reserved and already means "remove this".

`on`, `emit`, and `handler` are the three words added for event registration. `on` is short
and unlikely as a field name; `emit` and `handler` name the two ends of a queue and appear in
no other position.

`every` and `next` are the two words added since. `every` is the second trigger form and sits
where `on` does, so no new position is introduced. `next` marks a sequence allocation and is
admissible only in a `DefaultClause`; it is a plausible field name in the abstract, but a field
named `next` would be a link in a hand-rolled linked list, which the transaction graph makes
unnecessary.

`using` gained a position rather than being added — it already parameterized `Hashed`, now also
parameterizes `Encrypted`, and names the template applied inside a `Hole`. Same meaning in all
three.

Words considered and **not** reserved for these:

- **`schedule`** or **`cron`**, as a top-level timer declaration. A timer job always has rows
  that parameterize it, so `every` on the producing table covers it and the payload stays typed
  against a row it can name. A rowless job is server maintenance, which is not user syntax.
- **`each`**, **`if`**, and **`else`**, inside a template. A hole's query result count already
  supplies all three, and the negative branch is a typed absence variant. See
  [templates.md](templates.md).
- **`sequence`** or **`serial`**, as a field modifier. The scope of a sequence is the scope of
  the uniqueness it serves, so `next <UniqueName>` reads the scope off a declaration that
  already exists rather than restating it.

`retain`, `forever`, and `otherwise` are the three words retention added. `otherwise` is
Haskell's guard fall-through and is used here for exactly that. `materialize` is an admin
command, not schema syntax, for the reason `retain` and `enforce` are separate statements: it
is operational policy that changes over time and is not the schema author's decision. See
[../storage.md](../storage.md#materialization).

Unit names (`day`, `hour`, `week`, `month`, `year`, …) are **not** reserved. They are ordinary
identifiers bound to `Duration` and `Period` constants in the standard library, which is what
lets `7 day` desugar to a multiplication rather than needing a special form. Grain variants
(`Hour`, `IsoWeek`, `Month`, …) are likewise ordinary identifiers — variants of the `Grain` sum
type — which is what keeps `grain == Month` an ordinary comparison.

**No unit name is bound in the plural**, as a constant or a function. The plural forms were
previously bound to `Duration -> Decimal` conversions *and* used as the unit word in `7 days`,
which put one identifier on two meanings; conversion is now `/ day` and the plural namespace is
kept empty so the collision cannot recur.

- **`access`**, as the assert name selecting the access-control variety. It was never a
  reserved word — it was a magic `Ident` that the compiler treated specially, which is the
  worst of both: no lexical status, but unusable as an ordinary constraint name. The variety
  is now decided by whether the body mentions `authed_user`, which is the difference
  [functors.md](functors.md) already said was the defining one. `access` is an ordinary
  constraint name again.

`grant`, `grants`, and `bypass` are the three added for `GrantCmd`. `revoke`, `on`, and
`scoped` were already reserved by `TokenCmd`, which is the family this joins.

`matches` is an ordinary function, not a keyword. `acknowledge`, `flag`, and `waive` are
reserved against future admin syntax but currently have no production — those operations are
ordinary mutations against `system.integrity.Violation`.

`erase`, `reason`, `release`, and `scrub` are the four words `ErasureCmd` added; `erasure` is
the fifth of the family and comes from `GrantCmd`'s `BypassKind`, not from `ErasureCmd`. `row`
was considered as a marker (`erase row …`) and **not** reserved — it is the likeliest identifier
in any schema, and `erase <table> <id>` is unambiguous without it because `shard` is already
reserved.

`diff` is the one word added for temporal comparison, and it sits where `at` does, so no new
position is introduced. Words considered and **not** reserved for it:

- **`union`**, **`except`**, and **`intersect`**, as general set operators over two queries. The
  need they were reaching for is answered by `diff` at two graph points and by composition over
  rollup levels, and admitting them would raise key-reconciliation questions the language does
  not otherwise have to answer.
- **`window`**, **`over`**, and **`partition`**. A rollup level is a real table and queries
  compose, so a shifted self-join expresses period-over-period comparison directly. There is no
  window-function construct and none is planned.
- **`now`**, as a query-level binding for relative moments (`at now - 30 day`). `at` takes a
  version token or a moment literal, and a diff takes graph points, so nothing currently needs
  it. It stays available if relative sampling is wanted later.

Words considered and **not** reserved for the literal, nesting, membership and paging work:

- **`in`**, as a membership operator. It is already reserved by `let … in`, and the proposed
  disambiguation does not count `let` nesting, so `let a = let b = 1 in b + 1 in a * 2` — which
  parses today — would break. Membership is `` `elem` ``: one bracket-literal production, no
  word, Haskell's own spelling.
- **`elem`**, **`contains`**, **`any`**, **`all`**, **`member`**. Ordinary library functions.
  Backtick infix is what makes `elem` read as an operator without being one.
- **`insert`**, **`values`**, **`into`** as an insert syntax. Juxtaposition already *is* the
  insert; the multi-row form adds a bracket, not a word.
- **`nest`**, as a query clause producing a nested column. Contextual, and then subsumed
  entirely: nesting is a sub-`Projection` on a `ProjItem`, so the clause does not exist. That
  also removed a join-graph-must-be-a-tree analysis, a diamond rule, a clause-order rule and a
  filter-after-`nest` error.
- **`row_number`**, as a contextual binding. A nullary term whose value depends on the enclosing
  query's ordering *and* extent is ambient state — the reading rejected for `Moment` — and a
  contextual binding is de-facto reserved anyway, since no declaration may collide with one.
  `numbered <table>` takes the ordered table as an argument instead.
- **`depth`**, as a generated column on a recursive join. The most common column name on
  hierarchical tables, and it collides with the acyclicity idiom that would use it. It goes with
  the closure operator, which is deferred: recursion is real new expressiveness and is blocked
  on the tension between "a `Null`-derived variant is rejected in a key" and every tree root's
  self-FK being nullable.
- **`provenance`**, as a `FieldPath` tail reporting whether a value was supplied or defaulted.
  Unreserved it silently shadows a real `provenance` field through any `:>`, returning a
  wrongly-typed value rather than an error; reserving it is the magic-`access` defect in a worse
  form. `Order where total.updated_at /= created_at` is the free approximation.
- **`offset`**, as the pagination counterpart to `limit`. There is no offset and none is added:
  a cursor is an ordinary `where` over the ordering tuple, so DataCode gets stable pagination
  for free and would have to add a production to get the unstable kind.
- **`queries`** and **`cancel`**'s siblings (`kill`, `abort`, `terminate`). `queries` is
  contextual — `show` commits the parse to `AdminCommand`. Only `cancel` is reserved, and only
  because it leads a statement.
- **`reverse`**, **`has`**, **`owns`**, as spellings for the dependent declaration. `:<` costs
  no word and pairs with `:>`; the other three are plausible field names, and `from` was already
  withdrawn once with `SourceClause`.
- **`maxLen`**, **`minLen`**, **`varchar`**, **`char`**, and a `Text 255` type syntax. A length
  cap is a **validation**, not a type: a type-level cap makes over-length connector data
  untypeable, and ingestion defaults to `monitor` precisely so one bad row cannot halt a binlog.
  A cap you cannot set to `monitor` converts a data problem into an outage. `where maxLen 255`
  needs no syntax at all.
- **`preHashed`**, for credential import. An ordinary function applied to a policy and a digest,
  so `FuncApp` already admits it.
- **`Default`**, as a type constructor wrapping every defaulted value. Rejected on the merits,
  not on the word: `is` would have to carry two contradictory meanings. Given
  `phone : Phone | NotGiven = NotGiven`, either `phone is NotGiven` is **False** on every
  defaulted row — breaking the absence check, which is the single most load-bearing thing in a
  language with no NULL — or `is` sees through the wrapper and the feature does nothing.

`reveal` is an ordinary `Effect` function, not a keyword, exactly as `matches` is an ordinary
function.

Type and trait names (`Text`, `Int`, `Null`, `NotFound`, `Erased`, `Doc`, `File`, `Duration`,
`Period`, `Grain`, `Moment`, `Behavior`, `Hashed`, `Encrypted`, `Reference`, `UserData`,
`LogData`, `Configuration`, `Component`, `Extensible`, `Keyless`, `Personal`, `DocKeys`, …) are
ordinary identifiers resolved through the namespace tree, not reserved words.
