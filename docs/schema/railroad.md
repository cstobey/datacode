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
TypeDecl     ::= 'type' Ident ( ':' TypeExpr | '=' TypeExpr ) UsingClause? WhereClause*

TypeExpr     ::= Variant ( '|' Variant )*
Variant      ::= QName TypeArg*
               | '(' TypeExpr ( ',' TypeExpr )+ ')'
TypeArg      ::= QName | Literal

UsingClause  ::= 'using' QName

TypeSig      ::= TypeExpr ( '->' TypeExpr )*
TypeSigDecl  ::= Ident ':' TypeSig
```

`type A : B` declares a domain type (subtype of `B`); `type A = B | C` declares a sum type.
`TypeSigDecl` is a top-level Haskell-style signature for a function; it is distinguished
from `FieldDecl` by position — signatures appear at file top level, field declarations only
inside a table, view, or trait body.

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
               | 'from' QName
DefaultClause::= '=' Expr

WhereClause  ::= 'where' ( Expr | PredicateBlock )
PredicateBlock ::= Expr+       /* layout block: one predicate per line, indented */

WildcardField ::= '*' 'from' QName
```

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

A `FieldDecl`'s `WhereClause` is addressed by the field's path
(`<namespace>.<table>.<field>`), which is also the name of the field's computed type. There
is no production for naming it — see [README.md](README.md#addressing-validations).

---

## Tables, Views, Traits

```ebnf
TableDecl    ::= 'table' QName ( ':' TraitList )? '{' TableBody '}'
ViewDecl     ::= 'view'  QName ( ':' TraitList )? '{' TableBody '}'
TraitDecl    ::= 'trait' Ident ( ':' TraitList )? '{' TraitBody '}'

TraitList    ::= QName ( ',' QName )*

TableBody    ::= ( BodyItem ( ',' BodyItem )* ','? )?
TraitBody    ::= ( TraitItem ( ',' TraitItem )* ','? )?

BodyItem     ::= FieldDecl
               | WildcardField
               | UniqueDecl
               | AssertDecl
               | EventDecl
               | HandlerDecl
               | OrderByDecl
               | WhereClause
               | FunctionDecl

TraitItem    ::= FieldDecl | FunctionDecl | EventDecl | UiHint

OrderByDecl  ::= 'order' 'by' OrderTerm ( ',' OrderTerm )*
OrderTerm    ::= FieldPath ( 'asc' | 'desc' )?

UniqueDecl   ::= 'unique' Ident '{' FieldPath ( ',' FieldPath )* '}'
AssertDecl   ::= 'assert' Ident '{' Expr '}'

EventDecl    ::= 'on' Expr 'emit' QName RecordLit
HandlerDecl  ::= 'handler' QName

UiHint       ::= 'ui' '{' HintPair ( ',' HintPair )* ','? '}'
HintPair     ::= Ident '=' Literal
```

A `WhereClause` standing alone as a `BodyItem` is a view-level row filter (see
[queries.md](queries.md)); a `WhereClause` attached to a `FieldDecl` is a field validation.
Position disambiguates: a `where` that begins its own comma-separated item is a filter.

`AssertDecl` covers both varieties of path-equivalence functor: the name `access` selects
the access-control variety, any other name is a data constraint. No other name is special —
`event` in particular is not, having been replaced by `EventDecl`.

`EventDecl` registers an event functor on the producing table. Its `Expr` is a condition that
fires on a `False` → `True` transition, and its `RecordLit` is an ordinary row construction
against the named queue table, so the payload is typed by that table's own fields. Where the
condition mentions a `Behavior`, the transition moment is solved rather than observed. Retry
policy is deliberately absent — it is a row in `system.events.Queue`, not part of the
registration.

`HandlerDecl` appears on a queue table and names the functor that processes dequeued rows. The
two are separate productions because they describe opposite ends: `EventDecl` is the
producer's business, `HandlerDecl` is the queue's. See [../events.md](../events.md).

Constraints not expressible in the grammar:

- `HandlerDecl` is valid only on a table carrying `LogData`; a queue holds occurrences.
- A `TraitList` item is a bare `QName`: **traits take no arguments.** A trait is a declaration,
  not a tuning knob, and operational values live in `Configuration` rows instead. See
  [traits.md](traits.md#traits-are-not-configuration).
- A `TableDecl` must declare a `UniqueDecl`, a `'unique'`-marked `FieldDecl`, or inherit one
  from a trait, unless it carries `LogData`, `Component`, or `Keyless`. See
  [tables.md](tables.md#candidate-keys-are-mandatory).
- A `ViewDecl` must **not**. A view's candidate key is derived from its sources and the
  operators applied to them, never written; a `UniqueDecl` in a view body is rejected. Every
  view has one — at worst all of its attributes — and `:describe` reports it, marking the
  all-attributes case as degenerate. See
  [queries.md](queries.md#view-keys-are-computed-never-declared).
- A `FieldPath` in a `UniqueDecl` may not name a field whose type is `Secret`, `Doc`,
  `Behavior`, or an alternation containing a `Null`-derived variant.

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
ChainStep     ::= ( 'by' Ident )? ( 'for' DurationLit | 'forever' )
                | 'drop'

DurationLit   ::= NumLit Ident
```

`AggregateDecl` binds a name to an ordinary query — source, optional `group`, projection with
aggregate functions. It is a template, not a view: a view has one extent, while an aggregate is
instantiated once per grain by the chain that names it.

`DurationLit` is a numeric literal juxtaposed with an identifier naming a `Duration` constant
(`7 days`, `1 month`). No unit words are reserved, and no ambiguity arises with function
application, because a numeric literal is not applicable — `NumLit Ident` can only be a
duration. The same identifiers are ordinary `Duration` values elsewhere, which is what makes
`grain == hour` an ordinary comparison.

Constraints not expressible in the grammar:

- The **first** `ChainStep` of a chain carries no `by` — it is the source table's own
  retention. Every later step must carry one.
- Grain must strictly coarsen along a chain, and a step's retention must cover at least one
  complete bucket of its successor, or that successor's first bucket is truncated.
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
from a block. An `assert` is addressed by its own name and takes no `/`.

```
enforce app.auth.User.username / minLen12 forward
monitor app.commerce.Order.billingMatch
repair  app.commerce.Order.total / isRoundedToCents into app.events.RepairQueue
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
NotExpr      ::= 'not' NotExpr | CmpExpr
CmpExpr      ::= AddExpr ( CmpOp AddExpr )?
CmpOp        ::= '==' | '/=' | '<' | '<=' | '>' | '>=' | IsOp
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

JoinClause   ::= '><' TypeExpr ( 'via' FieldPath )?
GroupClause  ::= 'group' FieldPath
AtClause     ::= 'at' StringLit
LimitClause  ::= 'limit' NumLit

Projection   ::= '{' ProjItem ( ',' ProjItem )* '}'
ProjItem     ::= FieldPath Aggregate? ( 'as' Ident )?
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

`JoinClause` takes a `TypeExpr` so that outer joins are written with the same `|`
alternation as a nullable `:>` field: `Order >< Customer | MissingCustomer`.

`AtClause`'s `StringLit` is a version token (graph node hash prefix, tag, or branch name) or
an ISO-8601 moment; the two are told apart at resolution, not by the grammar. Where it is
omitted the sample moment defaults to request arrival. Every query is evaluated at exactly
one moment, resolved once by the coordinating server and passed to each shard as a value —
see [queries.md](queries.md#every-query-has-a-sample-moment).

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
AdminCommand ::= ServerCmd | ShardCmd | ConnectorCmd | TokenCmd
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
avg       by        connector conflict  count     DataCode  deep      delete
demote    deprecate describe  desc      drop      elect     elevate
else      emit      enforce   export    extend    External  False     flag
for       force     forever   forward   from      group     handler   if
import    in        indexed   into      is        issue     key       lag
let       limit     materialized        max       merge     migrate   min
monitor   not       on        order     otherwise pause     primary   prune
refresh   removing  repair    replay    replication         resolve   resume
retain    revoke    scoped    secondary seq       servers   set       shard
shards    show      shrink    since     split     sum       sync      table
tertiary  then      to        token     tokens    transaction  transactions
trait     True      type      ui        unique    using     verify    via
view      views     violations  visibility        waive     where     with
```

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

`aggregate`, `retain`, `forever`, and `otherwise` are the four added for retention.
`otherwise` is Haskell's guard fall-through and is used here for exactly that.

Duration unit names (`day`, `hour`, `month`, …) are **not** reserved. They are ordinary
identifiers bound to `Duration` constants in the standard library, which is what lets
`grain == hour` be an ordinary comparison rather than a special form.

`matches` is an ordinary function, not a keyword. `acknowledge`, `flag`, and `waive` are
reserved against future admin syntax but currently have no production — those operations are
ordinary mutations against `system.integrity.Violation`.

Type and trait names (`Text`, `Int`, `Null`, `NotFound`, `Doc`, `Duration`, `Moment`,
`Behavior`, `Reference`, `UserData`, `LogData`, `Configuration`, `Component`, `Extensible`,
`Keyless`, `DocKeys`, …) are ordinary identifiers resolved through the namespace tree, not
reserved words.
