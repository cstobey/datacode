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
valid only on `Hashed`, where it names a row in `system.crypto.hash_policies`:

```
type Password : Hashed Text using system.crypto.password_v2 where minLen 12
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
               | OrderByDecl
               | WhereClause
               | FunctionDecl

TraitItem    ::= FieldDecl | FunctionDecl | UiHint

OrderByDecl  ::= 'order' 'by' OrderTerm ( ',' OrderTerm )*
OrderTerm    ::= FieldPath ( 'asc' | 'desc' )?

UniqueDecl   ::= 'unique' Ident '{' FieldPath ( ',' FieldPath )* '}'
AssertDecl   ::= 'assert' Ident '{' Expr '}'

UiHint       ::= 'ui' '{' HintPair ( ',' HintPair )* ','? '}'
HintPair     ::= Ident '=' Literal
```

A `WhereClause` standing alone as a `BodyItem` is a view-level row filter (see
[queries.md](queries.md)); a `WhereClause` attached to a `FieldDecl` is a field validation.
Position disambiguates: a `where` that begins its own comma-separated item is a filter.

`AssertDecl` covers both varieties of path-equivalence functor: the name `access` selects
the access-control variety, any other name is a data constraint. The name `event` is
currently also overloaded onto `AssertDecl` as a placeholder for event functor registration
— **that is not settled syntax** and this production will change. See OQ-030 in
[../open-questions.md](../open-questions.md).

```ebnf
StandaloneAssert ::= 'assert' QName '{' Expr '}'
StandaloneUnique ::= 'unique' QName '{' FieldPath ( ',' FieldPath )* '}'
```

In the standalone forms the `QName` is `<table>.<constraint-name>`.

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
repair  app.commerce.Order.total / isRoundedToCents into app.events.repair_queue
```

`always` is the default and need not be written. `forward` grandfathers: the predicate binds
new and changed values, existing ones are recorded and left alone.

The `/` here is unambiguous with division because `ValidationRef` is not an `Expr` — no
production admits both at this position.

`repair`'s `into` binding is provisional and will be revised with the event functor syntax
(OQ-030).

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
Delete       ::= ( 'delete' | 'delete!' ) Query
```

`JoinClause` takes a `TypeExpr` so that outer joins are written with the same `|`
alternation as a nullable `:>` field: `Order >< Customer | MissingCustomer`.

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
one by hand are ordinary mutations against `system.integrity.violations` — it is a table, and
the self-hosting principle says system concerns that can be expressed as tables should be:

```
system.integrity.violations where id == "05KG..." { state = Waived "legacy import, TICKET-4471" }
system.integrity.violations { subject_table = ..., subject = ..., origin = Forced, ... }
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
acknowledge  add    always    as        assert    asc       at        avg
by        connector conflict  count     DataCode  deep      delete    delete!
demote    deprecate describe  desc      drop      elect     elevate   else
enforce   export    extend    External  False     flag      for       force
forward   from      group     if        import    in        indexed   into
is        issue     key       lag       let       limit     materialized
max       merge     migrate   min       monitor   not       order     pause
primary   prune     repair    replay    replication  refresh  removing  resolve
resume    revoke    scoped    secondary seq       servers   set       shard
shards    show      shrink    since     split     sum       sync      table
tertiary  then      to        token     tokens    transaction  transactions
trait     True      type      ui        unique    using     verify    via
view      views     violations  visibility  waive  where    with
```

`and` and `or` are **not** reserved — boolean conjunction and disjunction are the operators
`&&` and `||`. (In Haskell `and` and `or` are list functions, not operators; reserving the
words here would have misled.) `not` is a reserved prefix operator, as in Haskell.

Two words that were considered and deliberately **not** reserved:

- **`write`**, as in an `enforce … on write` spelling of the grandfathering mode. `write` is
  a likely field name in any permissions table, including DataCode's own. The mode is spelled
  `forward` instead — one word, symmetric with `always`, no collision.
- **`open`**, as a modifier marking an extensible `Reference` table. `open` is a likely
  boolean field name. Extensibility is a marker trait (`Extensible`) instead, which needs no
  keyword at all and composes through the existing trait list.

`matches` is an ordinary function, not a keyword. `acknowledge`, `flag`, and `waive` are
reserved against future admin syntax but currently have no production — those operations are
ordinary mutations against `system.integrity.violations`.

Type and trait names (`Text`, `Int`, `Null`, `NotFound`, `Doc`, `Reference`, `UserData`,
`LogData`, `Configuration`, `Component`, `Extensible`, `DocKeys`, …) are ordinary identifiers
resolved through the namespace tree, not reserved words.
