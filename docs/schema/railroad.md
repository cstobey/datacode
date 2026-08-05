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
               | FunctionDecl
               | TypeSigDecl

ImportDecl   ::= 'import' ModuleName ( '(' Ident ( ',' Ident )* ')' )?
```

---

## Types

```ebnf
TypeDecl     ::= 'type' Ident ( ':' TypeExpr | '=' TypeExpr ) WhereClause*

TypeExpr     ::= Variant ( '|' Variant )*
Variant      ::= QName TypeArg*
               | '(' TypeExpr ( ',' TypeExpr )+ ')'
TypeArg      ::= QName | Literal

TypeSig      ::= TypeExpr ( '->' TypeExpr )*
TypeSigDecl  ::= Ident ':' TypeSig
```

`type A : B` declares a domain type (subtype of `B`); `type A = B | C` declares a sum type.
`TypeSigDecl` is a top-level Haskell-style signature for a function; it is distinguished
from `FieldDecl` by position — signatures appear at file top level, field declarations only
inside a table, view, or trait body.

---

## Fields

```ebnf
FieldDecl    ::= Ident RefToken TypeExpr SubTableBody?
                 SourceClause? 'unique'? DefaultClause? WhereClause?

RefToken     ::= ':' | ':>'
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
- `SubTableBody` is only valid with `:>`.

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

## Functions and Expressions

```ebnf
FunctionDecl ::= Ident Param* '=' Expr
Param        ::= Ident

Expr         ::= OrExpr
OrExpr       ::= AndExpr ( '||' AndExpr )*
AndExpr      ::= NotExpr ( '&&' NotExpr )*
NotExpr      ::= 'not' NotExpr | CmpExpr
CmpExpr      ::= AddExpr ( CmpOp AddExpr )?
CmpOp        ::= '==' | '/=' | '<' | '<=' | '>' | '>=' | IsOp
IsOp         ::= 'is' 'not'?

AddExpr      ::= MulExpr ( ( '+' | '-' ) MulExpr )*
MulExpr      ::= Atom ( ( '*' | '/' ) Atom )*

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

**Lexing.** Several operators share a prefix; maximal munch applies in every case:

| Prefix | Tokens |
|---|---|
| `=` | `=`, `==`, `=~` |
| `/` | `/`, `/=` |
| `\|` | `\|`, `\|\|` |
| `:` | `:`, `:>` |
| `>` | `>`, `>=`, `><` |
| `<` | `<`, `<=` |

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
               | MatViewCmd | TxnCmd | DrCmd

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
add       as        assert    asc       at        avg       by        connector
conflict  count     DataCode  deep      delete    delete!   demote    deprecate
describe  desc      drop      elect     elevate   else      export    extend
External  False     for       force     from      group     if        import
in        into      is        issue     key       lag       let       limit
materialized  max   merge     migrate   min       not       order     pause
primary   prune     replay    replication  refresh  removing  resolve  resume
revoke    scoped    secondary seq       servers   set       shard     shards
show      shrink    since     split     sum       sync      table     tertiary
then      to        token     tokens    transaction  transactions     trait
True      type      ui        unique    using     verify    via       view
views     visibility  where   with
```

`and` and `or` are **not** reserved — boolean conjunction and disjunction are the operators
`&&` and `||`. (In Haskell `and` and `or` are list functions, not operators; reserving the
words here would have misled.) `not` is a reserved prefix operator, as in Haskell.

Type and trait names (`Text`, `Int`, `Null`, `NotFound`, `Reference`, `UserData`,
`LogData`, `Configuration`, …) are ordinary identifiers resolved through the namespace tree,
not reserved words.
