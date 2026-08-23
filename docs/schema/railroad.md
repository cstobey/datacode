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
NumLit       ::= '-'? [0-9]+ ( '.' [0-9]+ )?
BoolLit      ::= 'True' | 'False'

Comment      ::= '--' [^#xA]*
```

**Capitalization is a convention, not a grammar rule.** `Ident` admits either case in every
position, and the resolver distinguishes a type from a field by position, not by initial
letter. The convention is nonetheless normative style and is checked by the linter: types,
traits, tables, views, and sum-type variants are `UpperCamelCase` and singular; fields are
`lower_snake_case`; functions, predicates, and constraint names are `lowerCamelCase`;
namespace segments are `lowercase`. See [README.md](README.md#capitalization).

**Layout and termination.** Two rules, applied by the lexer before the grammar below sees
the token stream:

- **Inside a body** (`{ ... }`), declarations are separated by `,` and closed by `}`. The
  separator may be written trailing or leading; a comma immediately before `}` is permitted
  and ignored. A comma only separates at bracket depth 0 relative to the body — commas
  inside a nested `( )`, `{ }`, or `[ ]` belong to that nesting.
- **At top level**, there is no separator. A declaration ends at the next token in column 0.

**Continuation** in both cases is by indentation: a line indented deeper than the column at
which the current declaration began continues it; a line at that same column starts the next
declaration. This is what delimits a block-form `WhereClause`. The grammar below is written
layout-insensitively; the lexer inserts the implied separators.

---

## Schema Files

```ebnf
SchemaFile   ::= Statement*

Statement    ::= ImportDecl
               | TypeDecl
               | TraitDecl
               | TableDecl
               | ViewDecl
               | AggregateDecl
               | RetainDecl
               | StandaloneAssert
               | StandaloneUnique
               | EvolutionStmt
               | ModeStmt
               | FunctionDecl
               | TypeSigDecl

ImportDecl   ::= 'import' ModuleName ( '(' Ident ( ',' Ident )* ')' )?
```

---

## Types

```ebnf
TypeDecl     ::= 'type' Ident ( ':' TypeExpr | '=' TypeExpr | '=' FnType ) UsingClause? WhereClause*

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
signatures appear at file top level, field declarations only inside a table, view, or trait
body.

`FnType` is admissible only in `TypeDecl`. **A `FieldDecl` may not write an arrow inline; it
names a declared function type**, which is what makes "every function in a field shares one
signature" a property of what a field *is* rather than a rule about function columns, and what
gives the signature a name for diagnostics to address. The rightmost `TypeExpr` names the
effect (`Read`, `Tx`, `Effect`); omitted, the function is `Pure`. See
[functions.md](functions.md#function-types).

`UsingClause` supplies a parameter row to a parameterised type constructor. It is currently
valid only on `Hashed`, where it names a row in `system.crypto.HashPolicy`:

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2 where minLen 12
```

It precedes `where` for the same reason `DefaultClause` does — `where` is the only clause
with an open-ended expression to its right, so everything with a fixed shape comes first.
See [types.md](types.md#hashed-types).

---

## Fields

```ebnf
FieldDecl    ::= Ident RefToken TypeExpr SubTableTraits? SubTableBody?
                 SourceClause? 'unique'? 'indexed'? DefaultClause? WhereClause?

RefToken     ::= ':' | ':>'
SubTableTraits ::= ':' TraitList
SubTableBody ::= '{' TableBody '}'
SourceClause ::= 'rename' 'from' QName
DefaultClause::= '=' ( Expr | SeqAlloc )
SeqAlloc     ::= 'next' Ident

WhereClause  ::= 'where' ( Expr | PredicateBlock )
PredicateBlock ::= Expr+       /* layout block: one predicate per line, indented */
```

`SourceClause` lost its bare `'from' QName` alternative, and `WildcardField
::= '*' 'from' QName` is gone entirely. Both existed only to let a view body name the table a
field or a wildcard was drawn from. A view is now a named `Query`, so its source is the query
and the two field-level spellings had nothing left to do — `ProjItem`'s `User.*` is what
replaced them. `rename from` stays: it is an evolution hint on a table field and never had
anything to do with views.

At most **one** `WhereClause` per declaration. Its body is a single predicate on the same
line, or a `PredicateBlock` — an indented run of predicates delimited by the layout rule,
implicitly conjoined. There is no repeated `where` and no `and` between block entries.

Constraints not expressible in the grammar, enforced at compile time:

- `:` — no `Variant` in the `TypeExpr` may name a table or view.
- `:>` — the **first** `Variant` must name a table or view. Later variants may name further
  tables/views or `Null`-derived types. See the head rule in [README.md](README.md).
- `SubTableBody` and `SubTableTraits` are only valid with `:>`. `SubTableTraits` mirrors
  `TableDecl`'s trait list and is how an inline sub-table declares `Component`.
- `indexed` is valid only where the `TypeExpr` is `Doc`. See
  [documents.md](documents.md).
- `unique` is rejected on a field whose type is `Secret` (including every `Hashed` type),
  because per-row salts make the constraint unenforceable in principle.
- Where the `TypeExpr` head is `Behavior`, the `DefaultClause` is **mandatory** and is the
  behavior's definition rather than a default — its `Expr` must be a `Lambda` of one
  parameter, bound to a `Moment`. `SourceClause`, `unique`, `indexed`, and `WhereClause` are
  all rejected on such a field, and it may not appear in a `RecordLit`. See
  [types.md](types.md#behaviors).
- Where the `TypeExpr` names a **function type**, `unique`, `indexed`, and `WhereClause` are all
  rejected, because function types have no equality. A function literal in a `DefaultClause` or
  `RecordLit` is admissible only on a `Reference` table; a `Configuration` table admits a
  `FunctorRef` and no literal. An `Effect` function type admits a name only, never a literal.
  See [functions.md](functions.md#functions-as-column-values).
- `SeqAlloc` is admissible **only** in a `DefaultClause`, and only on a field named by the
  `UniqueDecl` its `Ident` refers to. `next` is an allocation, not a value: it is rejected in a
  `WhereClause`, a `Behavior` definition, a projection, and a view. See
  [tables.md](tables.md#sequences).
- A `SubTableBody` in a `DefaultClause` **constructs** the row, in the same transaction. This is
  what distinguishes `settings :> Settings : Component = { … }` from `created_by :> User =
  authed_user`, which references an existing one; the sub-table body is the constructor. See
  [tables.md](tables.md#a-component-default-constructs-the-row).

A `FieldDecl`'s `WhereClause` is addressed by the field's path
(`<namespace>.<table>.<field>`), which is also the name of the field's computed type. There
is no production for naming it — see [README.md](README.md#addressing-validations).

---

## Tables, Views, Traits

```ebnf
TableDecl    ::= 'table' QName ( ':' TraitList )? '{' TableBody '}'
ViewDecl     ::= 'view'  QName ( ':' TraitList )? '=' Query
TraitDecl    ::= 'trait' Ident ( ':' TraitList )? '{' TraitBody '}'

TraitList    ::= QName ( ',' QName )*

TableBody    ::= ( BodyItem ( ',' BodyItem )* ','? )?
TraitBody    ::= ( TraitItem ( ',' TraitItem )* ','? )?

BodyItem     ::= FieldDecl
               | UniqueDecl
               | AssertDecl
               | EventDecl
               | HandlerDecl
               | OrderByDecl
               | FunctionDecl

TraitItem    ::= FieldDecl | FunctionDecl | EventDecl | UiHint

OrderByDecl  ::= 'order' 'by' OrderTerm ( ',' OrderTerm )*
OrderTerm    ::= FieldPath ( 'asc' | 'desc' )?

UniqueDecl   ::= 'unique' Ident '{' FieldPath ( ',' FieldPath )* '}'
AssertDecl   ::= 'assert' Ident '{' AssertBody '}'
AssertBody   ::= Expr | Query

EventDecl    ::= 'on' Expr 'emit' QName RecordLit
               | 'every' Expr 'emit' QName RecordLit WhereClause?
HandlerDecl  ::= 'handler' QName

UiHint       ::= 'ui' '{' HintPair ( ',' HintPair )* ','? '}'
HintPair     ::= Ident '=' Literal
```

A `WhereClause` is only ever a field validation attached to a `FieldDecl`. It was previously
also a `BodyItem`, standing alone as a view-level row filter; a view is now a named `Query`
and carries its filter there, so the standalone form is gone and with it the rule that
position disambiguated the two.

`AssertDecl` covers both varieties of path-constraint functor. **The variety is decided by
the body, not by the name**: an `AssertBody` that mentions `authed_user` is an access
constraint, and anything else is a data constraint. No name is special — `access` was
previously a magic `Ident` selecting the access variety and no longer is, and `event` was
replaced by `EventDecl` before that.

A `Query` in `AssertBody` position — directly, or as an `Atom` under `not` — asserts that its
result is **non-empty**. This is what expresses presence, and `not` of it expresses absence.
The query must be rooted at `self` and every subsequent source must be reached by a
`JoinClause` along a declared `:>` edge in either direction; an unanchored source is a
compile-time error, because an `assert` that scans would scan on every read. See
[constraints.md](constraints.md).

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

- `HandlerDecl` is valid only on a table carrying `Queue`, and a `Queue` table declares exactly
  one. It was previously valid on any `LogData` table; a log is not a work list.
- A `Queue` table declares exactly one `:>` field to a table carrying `QueueState`, and at most
  one field whose type is `Priority`. Both are recognized by *type*, not by name — the same
  structural reading that decides an assert's variety. That `QueueState` field is the sole
  exemption from `LogData` append-only, and only the queue's handler may write it. See
  [../events.md](../events.md#queue-tables).
- An `every` interval `Expr` must be `Read` and of type `Duration`. A literal below
  `system.events.SchedulerLimit.min_interval` is rejected at commit; a computed one is clamped
  at dispatch. A `Period` interval (`every 1 month`) is **rejected**: sampling compares an
  interval against elapsed time since the last fire, and a `Period` has no elapsed length to
  compare. A monthly job is `every 1 day` with a `where` on the day of month, which also says
  what should happen when a month has no 31st.
- A `TraitList` item is a bare `QName`: **traits take no arguments.** A trait is a declaration,
  not a tuning knob, and operational values live in `Configuration` rows instead. See
  [traits.md](traits.md#traits-are-not-configuration).
- A `TableDecl` must declare a `UniqueDecl`, a `'unique'`-marked `FieldDecl`, or inherit one
  from a trait, unless it carries `LogData`, `Component`, or `Keyless`. See
  [tables.md](tables.md#candidate-keys-are-mandatory).
- A `ViewDecl` has no body in which to declare one, which is the grammar enforcing the rule
  rather than a check: a view's candidate key is derived from its sources and the operators
  applied to them, never written. Every view has one — at worst all of its attributes — and
  `:describe` reports it, marking the all-attributes case as degenerate. See
  [queries.md](queries.md#view-keys-are-computed-never-declared).
- A `ViewDecl`'s `assert`s are written standalone, since there is no body to hold them. A
  view's field types come from its `Query`: a projected `FieldPath` keeps the source's type,
  and a projected expression mints a computed type named by the view field's path. See
  [queries.md](queries.md#view-field-types).
- A `FieldPath` in a `UniqueDecl` may not name a field whose type is `Secret`, `Doc`,
  `Behavior`, a function type, or an alternation containing a `Null`-derived variant.

```ebnf
StandaloneAssert ::= 'assert' QName '{' Expr '}'
StandaloneUnique ::= 'unique' QName '{' FieldPath ( ',' FieldPath )* '}'
```

In the standalone forms the `QName` is `<table>.<constraint-name>`.

---

## Aggregates and Retention

```ebnf
AggregateDecl ::= 'aggregate' Ident '=' Source QueryClause*

RetainDecl    ::= 'retain' QName ( 'as' QName )? ( 'using' FieldPath )? RetainBody
RetainBody    ::= RetainBranch+ | Chain
RetainBranch  ::= 'where' Expr Chain
                | 'otherwise'  Chain

Chain         ::= ChainStep ( ',' ChainStep )*
ChainStep     ::= ( 'by' GrainRef )? ( 'for' LengthLit | 'forever' )
                | 'drop'

GrainRef      ::= UpperIdent
LengthLit     ::= NumLit Ident
```

`AggregateDecl` binds a name to an ordinary query — source, optional `group`, projection with
aggregate functions. It is a template, not a view: a view has one extent, while an aggregate is
instantiated once per grain by the chain that names it.

`LengthLit` is a numeric literal juxtaposed with an identifier naming a `Duration` or `Period`
constant (`7 day`, `6 hour`, `1 month`). It **desugars to multiplication** — `7 day` is
`7 * day` — so the unit is an ordinary value and the factor exists in one place. No unit words
are reserved, and no ambiguity arises with function application, because a numeric literal is
not applicable: `NumLit Ident` can only be a length. The same identifiers are ordinary
`Duration` and `Period` values everywhere else.

A `GrainRef` is a `Grain` variant and so is `UpperIdent` — `by Hour`, `by IsoWeek`, `by Month`.
The capitalization is what distinguishes the bucket size from the retention length beside it in
the same step, and it is the ordinary variant-naming rule rather than a special one. This is
also what keeps `grain == Month` an ordinary comparison: `grain` is a virtual column of type
`Grain` and `Month` is one of its variants.

Constraints not expressible in the grammar:

- The **first** `ChainStep` of a chain carries no `by` — it is the source table's own
  retention. Every later step must carry one.
- Each step's grain must be the **alignment parent** of its predecessor's, transitively —
  `Minute → Hour → Day → Month → Quarter → Year` or `Day → IsoWeek → IsoYear`. Coarsening
  alone is insufficient: `IsoWeek → Month` is coarser and misaligned, and merging across it
  would place a straddling week in a month it is only partly inside. See
  [types.md](types.md#grains-align-they-do-not-merely-coarsen).
- A step's retention must cover at least one complete bucket of its successor, or that
  successor's first bucket is truncated. The comparison is against the successor grain's
  **maximum** span (`Month` is 28–31 days, so `for 30 day` does not cover one), which keeps the
  check decidable and conservative.
- `for` takes a length, never a grain — a `Grain` has no count, so `for Day` cannot say how
  many. Both `Duration` and `Period` lengths are admitted, so a raw step may be `for 6 hour`.
- The **last** `ChainStep` must be `forever` or `drop`. A chain that merely runs out is
  rejected, so discarding data is always something someone wrote.
- `as` is required if the chain has more than one step, and forbidden if it has one. A chain
  never reshapes; naming the aggregate once on the header is what makes a differing step
  unrepresentable rather than merely rejected.
- An aggregate used in a chain of more than one step must declare an associative merge with an
  identity. `count`, `sum`, `min`, and `max` do; `avg` is rewritten to `(sum, count)`
  silently; `percentile` does not and is rejected past one step.
- A `RetainBranch` predicate may reference only the aggregate's `group` fields and the time
  source, so that no bucket can straddle two branches with different retentions.
- At most one `otherwise`, and it comes last.

See [aggregates.md](aggregates.md).

---

## Schema Evolution

```ebnf
EvolutionStmt   ::= DeprecateStmt | PruneStmt | SplitStmt | MergeStmt
                  | ExtendStmt | ShrinkStmt | VisibilityStmt

DeprecateStmt   ::= 'deprecate' QName
PruneStmt       ::= 'prune' QName

SplitStmt       ::= 'split' QName 'into' '{' SplitTarget ( ',' SplitTarget )* ','? '}'
SplitTarget     ::= Ident '{' TableBody '}'

MergeStmt       ::= 'merge' QName ( ',' QName )+ 'into' QName '{' TableBody '}'

ExtendStmt      ::= 'extend' QName 'with' Variant
ShrinkStmt      ::= 'shrink' QName 'removing' Variant 'migrate' '(' Expr ')'

VisibilityStmt  ::= 'set' 'visibility' NamePattern VisibilityLevel
VisibilityLevel ::= 'system' | 'connector' | 'internal' | 'standard' | 'featured'
```

`SplitStmt` and the CLI's `split shard` are disambiguated by the `shard` keyword.

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

AddExpr      ::= MulExpr ( ( '+' | '-' ) MulExpr )*
MulExpr      ::= InfixExpr ( ( '*' | '/' ) InfixExpr )*
InfixExpr    ::= Atom ( '`' QName '`' Atom )*

Atom         ::= Literal
               | FieldPath
               | FuncApp
               | Lambda
               | IfExpr
               | LetExpr
               | RecordLit
               | '(' Expr ')'
               | '(' Query ')'

FuncApp      ::= QName Atom+
Lambda       ::= '\' Param+ '->' Expr
IfExpr       ::= 'if' Expr 'then' Expr 'else' Expr
LetExpr      ::= 'let' Ident '=' Expr 'in' Expr
RecordLit    ::= '{' ( RecordField ( ',' RecordField )* ','? )? '}'
RecordField  ::= Ident '=' Expr
```

**`=` versus `==`.** `=` is **binding only** and never appears as a comparison operator, as
in Haskell. It occurs in exactly five places, none of them expressions at depth 0:

| Production | Use |
|---|---|
| `DefaultClause` | field default |
| `FunctionDecl` | function definition |
| `TypeDecl` | sum-type declaration |
| `LetExpr` / `LetBinding` | local and query bindings |
| `RecordField` | row construction and row update |

Comparison is always `==`. Constructor matching (ignoring payload) is `is`; exact equality
including payload is `==`.

This is also what keeps the clause order unambiguous: a bare `=` cannot occur at bracket
depth 0 inside a `where` predicate — every `=` above is either inside a bracket, inside
`let ... in`, or in declaration position — so `total : Amount = 0 where isPositive` has
exactly one parse.

**Operator spelling** follows Haskell throughout: `==`, `/=`, `&&`, `||`, `not`, `True`,
`False`. There are no `!=`, `and`, or `or` tokens.

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

The compiled-pattern cache therefore keys on the `Configuration` row's version. TDFA is a DFA
engine, so a pathological pattern costs no more than a linear scan — the restriction exists to
keep patterns out of untrusted hands, not to bound backtracking.

**A parenthesized `Atom` is a `Query` if it contains a `QueryClause`** and an `Expr`
otherwise. The two cannot both apply: an `Expr` has no production admitting `where`, `><`,
`group`, `order by`, `at`, `limit`, or a bare `Projection` at that position.

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
| `\|` | `\|`, `\|\|` |
| `:` | `:`, `:>` |
| `>` | `>`, `>=`, `><` |
| `<` | `<`, `<=` |

`$` and `` ` `` share a prefix with nothing and are single-character tokens. `` ` `` is
valid only in matched pairs enclosing a `QName`.

The `\|` / `\|\|` pair deserves attention: `\|` is heavily loaded already (sum types, unions,
outer-join guards) and `\|\|` is boolean or. Munch resolves it, but a missing space in
`A \|\| B` where `A \| \| B` was meant will parse as a boolean expression rather than a type.

---

## Queries and Mutation

```ebnf
Query        ::= Source QueryClause*

Source       ::= QName
               | Ident
               | '(' Query ')'

QueryClause  ::= JoinClause
               | WhereClause
               | GroupClause
               | OrderByDecl
               | Projection
               | AtClause
               | LimitClause

JoinClause   ::= '><' JoinSource ( 'via' FieldPath )? ( 'as' Ident )?
JoinSource   ::= TypeExpr
               | '(' Query ')' ( '|' TypeExpr )*
GroupClause  ::= 'group' FieldPath
AtClause     ::= 'at' StringLit
LimitClause  ::= 'limit' NumLit

Projection   ::= '{' ProjItem ( ',' ProjItem )* '}'
ProjItem     ::= FieldPath Aggregate? ( 'as' Ident )?
               | Expr 'as' Ident
               | ( QName '.' )? '*'
Aggregate    ::= 'sum' | 'count' | 'min' | 'max' | 'avg'

LetBinding   ::= 'let' Ident '=' Query

Mutation     ::= Insert | Update | Delete
Insert       ::= QName RecordLit
Update       ::= Query RecordLit
Delete       ::= 'delete' Query
```

`Delete` has one spelling. It appends a tombstone version like any other mutation, so the row
remains readable at every earlier sample moment — see
[queries.md](queries.md#delete-appends-a-version) for why the `delete!` variant was withdrawn.

`JoinClause`'s `JoinSource` is a `TypeExpr` so that outer joins are written with the same `|`
alternation as a nullable `:>` field: `Order >< Customer | MissingCustomer`. The parenthesized
`Query` alternative exists for one purpose: **an outer-joined source must carry its own filter
inside the join term.**

```
-- WRONG: an account whose every suspension is lifted yields zero rows, not a
-- NoSuspension row, so an absence test on this reports the opposite of the truth
Account >< Suspension | NoSuspension where lifted is NotLifted

-- RIGHT: filter before the guard
Account >< (Suspension where lifted is NotLifted) | NoSuspension as suspension
```

A `WhereClause` at the outer level that references a field of an outer-joined source is
consequently a **compile-time error**, and the diagnostic names the parenthesized form as the
fix. This is SQL's `ON`-versus-`WHERE` trap, which is worth closing structurally here because
the same expression appears inside `assert`, where the symptom is not missing rows but an
inverted constraint.

`JoinClause`'s `as` names the joined source in the result. It is **mandatory when a source
joined against the reference direction is named anywhere in the query** — in a `where`, a
`Projection`, or a variant test. Joining `Account` to the `Suspension` rows that reference it
produces a column with no `:>` field to name it, and falling back to the bare table name
would read as though the table itself were the value. A reverse join whose source is never
named needs no `as`; in the forward direction the `:>` field already names the column and `as`
is always optional.

`ProjItem`'s three forms: a bare `FieldPath` keeps the source field's name and type; an `Expr`
requires `as`, since a computed column has no name to inherit; and `*` copies every field of
its source, qualified (`User.*`) to pick one side of a join. `*` binds at query time, so new
source fields appear automatically, while a named field binds stably — see
[queries.md](queries.md#the--selector-and-field-propagation).

`AtClause`'s `StringLit` is a version token (graph node hash prefix, tag, or branch name) or
an ISO-8601 moment; the two are told apart at resolution, not by the grammar. Where it is
omitted the sample moment defaults to request arrival. Every query is evaluated at exactly
one moment, resolved once by the coordinating server and passed to each shard as a value —
see [queries.md](queries.md#every-query-has-a-sample-moment).

---

## Templates

```ebnf
TemplateBody ::= ( TemplateText | Hole )*
Hole         ::= '{{' Query ( 'using' QName )? '}}'
TemplateText ::= /* any run of characters containing no '{{' */
```

That is the entire template language. There is no `if`, no `each`, and no `unless`, because the
**result count of a `Hole`'s `Query` is the control flow**: zero rows render nothing (the
conditional), one row renders once (plain interpolation), N rows render N times joined by the
template's separator (the loop). `self` is a query of one row, so `{{ self.order_num }}` is the
degenerate case of the same production rather than a second form.

`using` names the template applied per row. Omitted, the active theme's render function for the
row's type applies, which is what makes the template system and the theme system one mechanism.
It is the existing `UsingClause` token in a wider position — same meaning, "supply this
parameterizing thing".

The separator is a field on the template's `Reference` row, not part of the `Hole`. Two
templates differing only in separator are two rows, which is cheap, and it keeps a `Hole` at two
parts.

Constraints not expressible in the grammar:

- A `Hole`'s `Query` must be rooted at `self`, every subsequent source reached along a declared
  `:>` edge — the same anchoring rule as `AssertBody`, and for the same reason: a template
  renders per row on every read that reaches it.
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
                | '--shard' QName
                | '--format' Format

Format        ::= 'table' | 'json' | 'csv' | 'raw'
Value         ::= Ident | StringLit
Path          ::= StringLit | [^#x20#xA]+
```

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
               | ':describe' QName
               | ':history' QName HistoryOpt*
               | ':commit'
               | ':rollback'
               | ':explain' Query
               | ':help'

HistoryOpt   ::= 'since' StringLit
               | 'limit' NumLit
```

---

## Administration

```ebnf
AdminCommand ::= ServerCmd | ShardCmd | ConnectorCmd | TokenCmd | GrantCmd
               | MatViewCmd | TxnCmd | IntegrityCmd | DrCmd

ServerCmd    ::= 'show' 'servers' ( 'for' 'shard' QName )?
               | 'elevate' 'secondary' Host 'to' 'primary' 'for' 'shard' QName
               | 'demote' 'primary' Host 'to' 'tertiary' 'for' 'shard' QName

ShardCmd     ::= 'show' 'shards'
               | 'describe' 'shard' QName
               | 'split' 'shard' QName 'at' 'key' StringLit

ConnectorCmd ::= 'show' 'connectors'
               | 'describe' 'connector' QName
               | 'add' 'connector' Ident StringLit RecordLit
               | ( 'pause' | 'resume' ) 'connector' QName
               | 'show' 'connector' 'conflicts' QName ( 'limit' NumLit )?
               | 'resolve' 'conflict' Ident 'using' Resolution

Resolution   ::= 'DataCode' | 'External' | 'merge' RecordLit

TokenCmd     ::= 'show' 'tokens' ( 'type' TokenType )?
               | 'issue' 'client' 'token' 'for' StringLit 'scoped' 'to' QName
               | 'revoke' 'token' Ident
TokenType    ::= 'server' | 'client' | 'user'

GrantCmd     ::= 'show' 'grants' ( 'for' QName )?
               | 'grant'  QName 'on' QName ( 'bypass' 'access' )?
               | 'revoke' 'grant' QName 'on' QName

MatViewCmd   ::= 'show' 'materialized' 'views' ( 'shard' QName )?
               | 'refresh' 'view' QName ( 'at' StringLit )?
               | 'drop' 'materialized' 'view' QName

TxnCmd       ::= 'show' 'transactions' ( 'shard' QName )? ( 'since' 'seq' NumLit )? ( 'limit' NumLit )?
               | 'show' 'transaction' Ident

IntegrityCmd ::= 'show' 'violations' ( 'for' ValidationRef )? ( 'shard' QName )? ( 'limit' NumLit )?
```

`IntegrityCmd` is the only integrity command with its own syntax, and it exists only as a
convenience for the degraded-server case. Waiving a violation, acknowledging one, and raising
one by hand are ordinary mutations against `system.integrity.Violation` — it is a table, and
the self-hosting principle says system concerns that can be expressed as tables should be:

```
system.integrity.Violation where id == "05KG..." { state = Waived "legacy import, TICKET-4471" }
system.integrity.Violation { subject_table = ..., subject = ..., origin = Forced, ... }
```

---

## Disaster Recovery

```ebnf
DrCmd        ::= 'force' 'elect' 'primary' Host 'for' 'shard' QName
               | 'verify' 'shard' QName 'deep'?
               | 'replay' 'shard' QName 'from' 'seq' NumLit 'to' 'seq' NumLit
               | 'export' 'shard' QName 'to' StringLit ( 'at' 'seq' NumLit )?
               | 'import' 'shard' QName 'from' StringLit
               | 'show' 'replication' 'lag' ( 'for' 'shard' QName )?
               | 'force' 'sync' Host 'for' 'shard' QName
```

---

## Reserved Words

```
acknowledge  add    aggregate always    as        assert    asc       at
avg       by        bypass    connector conflict  count     DataCode  deep
delete    demote    deprecate describe  desc      drop      elect     elevate
else      emit      enforce   every     export    extend    External  False
flag      for       force     forever   forward   from      grant     grants
group     handler   if        import    in        indexed   into      is
issue     key       lag       let       limit     materialized        max
merge     migrate   min       monitor   next      not       on        order
otherwise pause
primary   prune     refresh   removing  repair    replay    replication
resolve   resume    retain    revoke    scoped    secondary seq       servers
set       shard     shards    show      shrink    since     split     sum
sync      table     tertiary  then      to        token     tokens
transaction  transactions     trait     True      type      ui        unique
using     verify    via       view      views     violations  visibility
waive     where     with
```

### Contextual Bindings

`self` and `authed_user` are **not** reserved words. They are bindings supplied by the
context an expression is evaluated in, resolved through the same namespace lookup as any
other identifier and shadowed by nothing, because no declaration may introduce a name that
collides with a binding in scope.

| Binding | Bound to | In scope |
|---|---|---|
| `self` | the row under evaluation | trait function bodies, `assert` bodies, `on`/`every` conditions and payloads, `Hole` queries, function-column bodies |
| `authed_user` | the requesting user token's row | `assert` bodies, field defaults |

`self` has been used in trait function bodies since [traits.md](traits.md) was written without
being listed anywhere; it is listed here now. `authed_user` replaces the earlier `user`, which
read like a table name and would have collided with the likeliest field name in any
permissions schema — including DataCode's own.

**There is no `authed_client` binding.** Client tokens restrict access at the schema level and
that restriction is configuration in `system.auth.*`, so admitting the client into an `assert`
would put one decision in two places. See [../auth.md](../auth.md).

`and` and `or` are **not** reserved — boolean conjunction and disjunction are the operators
`&&` and `||`. (In Haskell `and` and `or` are list functions, not operators; reserving the
words here would have misled.) `not` is a reserved prefix operator, as in Haskell.

Words that were considered and deliberately **not** reserved:

- **`delete!`**, as a hard delete alongside the soft `delete`. This one was reserved and has
  been **withdrawn**. The distinction it drew was not a distinction — both spellings left the
  record in the transaction graph and removed the row from the current state, which is what a
  delete is. The operation that would have earned the sigil is destroying bytes already in the
  append-only log; that is [OQ-036](../open-questions.md#oq-036-erasure-pii-scrubbing-and-shard-quarantine),
  it is administrative rather than a row mutation, and it will not be spelled as a `delete`.


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

`using` gained a position rather than being added — it already parameterized `Hashed` and now
names the template applied inside a `Hole`. Same meaning in both.

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

`aggregate`, `retain`, `forever`, and `otherwise` are the four added for retention.
`otherwise` is Haskell's guard fall-through and is used here for exactly that.

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

Type and trait names (`Text`, `Int`, `Null`, `NotFound`, `Doc`, `Duration`, `Period`, `Grain`, `Moment`,
`Behavior`, `Reference`, `UserData`, `LogData`, `Configuration`, `Component`, `Extensible`,
`Keyless`, `DocKeys`, …) are ordinary identifiers resolved through the namespace tree, not
reserved words.
