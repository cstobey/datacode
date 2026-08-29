# Schema model

The DataCode schema language, broken up by topic. This directory is the normative
reference for schema syntax and semantics. `../cli.md` covers the tooling that
*carries* this syntax (REPL, flags, admin and DR commands) and links here rather
than restating it.

| Document | Covers |
|---|---|
| [types.md](types.md) | Primitives, domain types, sum and product types, `Moment` and `Behavior`, `Duration`/`Period`/`Grain`, absence types, canonical types, `File`, `is`, `Secret`, `Hashed`, `Encrypted` |
| [tables.md](tables.md) | Table bodies, field declarations, defaults, candidate keys, ordering, foreign keys, sub-tables, back-references |
| [traits.md](traits.md) | Trait declaration, extension, multiple inheritance, replication traits, `Component`, `Keyless`, `Personal`, `Extensible`, `Queue`/`QueueState` |
| [constraints.md](constraints.md) | `assert`, path constraints, presence and absence, access control |
| [documents.md](documents.md) | The `Doc` type, shredding, key interning and spill, key shape rules, demotion |
| [aggregates.md](aggregates.md) | Aggregate functions, mergeable aggregates, `retain` chains, log retention |
| [evolution.md](evolution.md) | Redeclaration, rename, retype, deprecate, prune, split, merge, ADT extension, visibility |
| [queries.md](queries.md) | Filter, projection, joins, grouping, ordering, limit and pagination, derived tables, mutation, `diff` |
| [functions.md](functions.md) | Scope, the effect ladder, Haskell functions, auto-wrapping, function types, function-valued columns |
| [functors.md](functors.md) | The four functor kinds, order of operations, enforcement modes |
| [templates.md](templates.md) | Text with holes, cardinality as control flow, `using` and render functions |
| [railroad.md](railroad.md) | Full EBNF grammar + railroad diagram rendering |

Related documents outside this directory: [../namespaces.md](../namespaces.md) (namespace
tree), [../transaction-graph.md](../transaction-graph.md) (versioning, branches, identifiers),
[../storage.md](../storage.md) (physical layout), [../api.md](../api.md) (HTTP surface),
[../events.md](../events.md) (event scheduler), [../auth.md](../auth.md) (tokens),
[../integrity.md](../integrity.md) (nonconformance and enforcement modes).

## Design philosophy

DataCode agrees with TutorialD and *The Third Manifesto* on three things SQL gets wrong: no
NULL, mandatory candidate keys, and tables as sets of typed tuples. It departs on a fourth —
`:>` stores a surrogate row identifier, which TTM proscribes — because the transaction graph
needs an identity independent of any natural key. The core shift from SQL:

- A **table** is a named collection of typed tuples. Every row carries a system-minted
  `DataId`, which is *not* a candidate key; a candidate key is mandatory unless the table
  carries `LogData`, `Component`, or `Keyless`
  ([tables.md](tables.md#candidate-keys-are-mandatory)). Rows are a set — `order by` declares
  a default ordering for queries, not a stored order.
- A **field** has a precise type with associated validation functors
- A **query** is indistinguishable from a table definition. Both denote tables over the transaction graph, and there is no separate schema object called a view.
- There is **no NULL** — absent values are expressed as typed ADTs with meaningful names
- Tables are organized in a **namespace tree** — namespaces replace the SQL "database" concept
- **Traits** provide abstract base types for tables, encoding replication policy, shared fields, and shared functions

### Self-hosting principle

**DataCode should use DataCode to manage its own operational data wherever practical.**

Every system concern that can be expressed as a table, should be. This includes:

- **The transaction graph itself** — rows in `system.graph.Transaction`
- **Branches and tags** — rows in `system.schema.Branch` and `system.schema.Tag`
- **API route registrations** — rows in `system.api.GeneratedRoute` and `system.api.CustomRoute`
- **Connector configuration and replication position** — rows in `system.connectors.*`
- **Event queues** — user-defined tables carrying the `Queue` trait, with policy in `system.events.QueuePolicy`
- **Scheduler state** — rows in `system.events.*`
- **Accounts, credentials, tokens, and grants** — rows in `system.auth.*`
- **Shard roles, placement, and durability policy** — rows in `system.shards.*`
- **Key custody and hash policy** — rows in `system.crypto.*`
- **Nonconformance** — rows in `system.integrity.Violation` and `system.integrity.Disposition`
- **Operational metrics and request logs** — rows in `system.logs.*`, `system.logs.HttpRequest` among them. They carry `LogData`, so they are discarded only by a declared `retain` chain and never automatically ([traits.md](traits.md#replication-traits))

The practical consequences:

- DataCode's own configuration is inspectable and queryable with standard DataCode tooling
- System operations (connector sync, event dispatch, shard maintenance) are auditable in the transaction log
- The IDE can show system state the same way it shows application state
- **A DataCode upgrade obeys the rules an application author obeys.** A release that adds a field to `system.auth.*` ships a `DefaultClause` with it and backfills nothing ([evolution.md](evolution.md#every-added-field-declares-a-default)). Self-hosting cuts both ways: the product's own author is *further* from an operator's rows than an application author is, so no escape hatch exists here that does not exist there

Bootstrapping is the one exception, and the genesis path is not yet specified. The first system
tables must exist before DataCode can use DataCode to manage them, and every route into that
state is circular against a settled rule: inserting a `Reference` row is itself a schema
commit, access is default-deny until a grant exists, and a schema shard is rooted at a branch
row that the schema graph has to hold. The compiled-in seed schema, the order in which the
first rows are admitted, and how the initial grant and token are minted belong in
[../transaction-graph.md](../transaction-graph.md), which owns the graph.

## Namespace organization

Every table belongs to a namespace. Namespaces are dot-separated hierarchical paths:

- `app.commerce.Order` — user-defined application schema
- `connectors.mariadb.production.Order` — auto-generated connector shadow schema
- `system.auth.User` — DataCode self-management tables

Namespaces are created implicitly when a table is first defined in them — no explicit
creation syntax. Full namespace documentation: [../namespaces.md](../namespaces.md).

## Schema layers

DataCode maintains three layers of schema simultaneously. A layer is a namespace convention.
It is not the `VisibilityLevel` that `set visibility` assigns, which is a separate five-value
scale with a home in [../namespaces.md](../namespaces.md#schema-visibility-layers).

1. **Auto-generated connector shadow schemas** (`connectors.*`): created when a connector is added; updated automatically as the external schema changes; hidden from the default IDE view
2. **User-defined application schemas** (`app.*`): created by schema authors; may be derived from or extend connector schemas; visible by default
3. **System schemas** (`system.*`): DataCode internals. They default to the `system` visibility level, so the IDE hides them. Read access is default-deny and takes an explicit grant on the subtree, as it does everywhere ([../namespaces.md](../namespaces.md#namespace-access-control)). There is no admin token type and no role check on the read path — administrator status is a `bypass` attribute on an ordinary grant

This layering enables data independence: the human-understood schema (`app.*`) evolves
independently of the connector shadow schema beneath it. The coercion between the two layers
is an ordinary `Binding`, not a fifth functor kind — its projected expressions mint the target
field types ([queries.md](queries.md#field-types)). All three layers are logical; *physical*
means storage layout and belongs to [../storage.md](../storage.md).

## Notation conventions

These conventions recur throughout the language. They are defined once here and assumed
everywhere else.

### Capitalization

Follows Haskell: the things that name a *kind* are capitalized, the things that name an
*instance or a member* are not.

| Kind of name | Form | Examples |
|---|---|---|
| Type, trait, table, derived table | `UpperCamelCase`, **singular** | `Email`, `Amount`, `Active`, `UserData`, `Order`, `Customer` |
| Sum-type variant | `UpperCamelCase` | `Shipped`, `NotGiven`, `Argon2id` |
| Field | `lower_snake_case` | `order_num`, `placed_at`, `billing_address` |
| Function, predicate, constraint name | `lowerCamelCase` | `isValidEmail`, `matches`, `orderRef`, `billingMatch` |
| Namespace segment | `lowercase` | `app`, `commerce`, `system`, `auth` |

So a fully-qualified name reads `app.commerce.Order` — lowercase path, capitalized table.

**Tables are capitalized because they are types.** `table T : Trait` uses the same `:` that
`type A : B` does, `:>` resolves to a row *of* that table, and a table is an object in the
schema category exactly as a type is. Singular follows from the same place: a row is an
`Order`, not an `Orders`.

**Fields are `snake_case` while functions are `camelCase`**, and the split is deliberate
rather than an accident of drift. A field names stored data and reads as a column; a function
is code and reads as Haskell. `total : Amount where isRoundedToCents` puts both conventions in
one line, and each looks like what it is.

### `:` versus `:>`

`:` means **is a kind of**. `:>` means **references a row in**. `:<` means **is referenced
by rows in**. The correct token depends on syntactic position:

| Position | Token | Right-hand side must be |
|---|---|---|
| `type A : B` | `:` | a type |
| `trait T : R` | `:` | a trait |
| `table T : R, S` | `:` | traits |
| field declaration | `:` | a type — no alternative may be a table |
| field declaration | `:>` | a table or derived table (see the head rule below) |
| table body item | `:<` | a table — the child that holds the FK back |

`:>` is meaningful only in field position. Using `:` where the right-hand side names a
table, or `:>` where it names a type, is a compile-time error:

```
email    : Email        -- ok:    Email is a type
customer :> Customer    -- ok:    Customer is a table
email   :> Email        -- error: Email is a type, not a table; use `:`
customer : Customer     -- error: Customer is a table; use `:>`
```

The distinction is not redundant with name resolution. An FK field does not *hold* a
`Customer` — it holds a `DataId` wrapped in a field-scoped type, carries an FK functor,
adds an edge to the join graph, and is checked for referential integrity at commit. `:>`
records that difference where it is read, and separates reference from containment.

**The head rule.** When the right-hand side is an alternation, only the *first* alternative
determines which token is required. Subsequent alternatives may be further tables or
`Null`-derived absence types:

```
customer :> Customer                                            -- required FK
customer :> Customer | MissingCustomer                          -- nullable FK
customer :> Customer | HistoricalCustomer | MissingCustomer     -- fallback chain
phone     : Phone | NotGiven                                    -- no table anywhere: `:`
```

This is the same left-to-right guard semantics used by outer joins (see
[queries.md](queries.md)), so a nullable FK field and an outer join read identically.
No second `Null` root is needed — absence types are admissible in the tail of either form.

**`:<` is `:>` read from the other end.** It is a body item rather than a field, and it
declares a *child* table that holds a foreign key back to this one, naming that field with
`via`. The parent gains nothing from it — no column, no reverse relation — so `:<` removes a
second declaration, never a second spelling for a join:

```
:< Comment via document { body : Text, author :> User }
```

It is spelled `:<` and not `<:` because `<:` is the subtyping operator everywhere else it
appears, and `:` already means subtype here: `type Email : Text` is `Email <: Text`. So
`comments <: Comment` would be a well-formed sentence saying the wrong thing, which is worse
than a parse error. Full treatment in [tables.md](tables.md#back-references).

### Clause order

A field declaration takes its optional clauses in one fixed order:

1. sub-table traits — `: Component`, `: Reference`
2. an inline sub-table body — `{ … }`
3. seed rows for a `Reference` sub-table — `[ { … }, { … } ]`
4. `unique`
5. `indexed`, with an optional `using`
6. the default — `= …`
7. `where`

The production is `FieldDecl` in [railroad.md](railroad.md#fields), which also carries the
constraint on each clause. This section holds only why the order is fixed, so that the two
cannot drift apart again.

`where` is last because it is the only clause with an open-ended expression on its right.
Fixing the order keeps a declaration parseable in one pass, with no lookahead to decide
where the default ends and the predicate begins.

`=` is binding only — field defaults, function definitions, sum-type declarations, `let`,
and row construction/update — and is never a comparison; comparison is `==`, as in Haskell.
Because a bare `=` therefore cannot appear at bracket depth 0 inside a predicate,
`total : Amount = 0 where isPositive` has exactly one parse.

Operator spelling follows Haskell throughout: `==`, `/=`, `&&`, `||`, `not`, `True`,
`False`. There are no `!=`, `and`, or `or` tokens. `=~` is regex match, and its right operand
must be a string literal or a path into a `Reference` or `Configuration` table — never user
input ([railroad.md](railroad.md#functions-and-expressions) owns the restriction and its
reasons). Membership is `` `elem` `` over a table literal, not an `in` operator; `in` belongs
to `let … in` and gains no second meaning ([queries.md](queries.md#membership)).

### Backticks and `$`

Two Haskell conveniences, with Haskell's semantics and Haskell's fixities.

**Any named function may be written infix in backticks** (`infixl 9` — tighter than every
operator, looser than juxtaposition). This matters most for two-argument predicates, which
read as the assertions they are rather than as function calls:

```
attempt `matches` credential.secret
authed_user `canRead` subject_table
```

**`$` is low-precedence right-associative application** (`infixr 0`). Its practical effect is
an opening parenthesis that closes at the end of the expression, which keeps `where` blocks
free of trailing parenthesis stacks:

```
where
  isValidEmail
  \e -> not $ isDisposableDomain e || isBlockedDomain e
```

### The `where` clause

`where` attaches to the end of a declaration and restricts it, the way Haskell's `where`
attaches to the end of a declaration and elaborates it. The meaning is narrower — DataCode's
`where` binds no names, it only constrains — but the shape is deliberately the same.

One `where` per declaration. Its body is either a single predicate on the same line, or a
block of predicates indented beneath it:

```
type Email : Text where isValidEmail

type Username : Text
  where
    isNotEmpty
    maxLen 32
    \u -> not (containsWhitespace u)
```

Predicates in a block are implicitly conjoined — all must hold. There is no `&&` between
them and no repeated `where`.

Conjunction also arises semantically, without appearing in the syntax: a field inherited
from two traits carries both traits' predicates (see [traits.md](traits.md)).

### Termination and layout

The token rules are [railroad.md](railroad.md#lexical)'s; what follows is why they are worth
following.

Comments are `--` to end of line.

**Inside a body** (`table`, `trait`), field declarations are separated by `,` and
the body is closed by `}`. The separator may sit at the end of a declaration or at the start
of the next — leading-comma style keeps a block `where` readable, and is the recommended
style whenever any field in the body has one. A comma before the closing `}` is permitted:

```
table app.commerce.Customer : UserData {
  email : Email unique
    where
      isValidEmail
      maxLen 254
  , name  : Text
  , phone : Phone | NotGiven
}
```

**At top level** (`type`, `trait`, `table`, bindings, function definitions), there is no
enclosing bracket and no separator. A declaration ends where the next one begins: at the
next token in column 0. Blank lines are formatting, not syntax.

```
type Email  : Text    where isValidEmail
type Amount : Decimal where \a -> a >= 0

type Zip : Text
  where
    \z -> length z == 5
    allDigits
```

**Continuation**, in both cases, is by indentation: a line indented deeper than the column
where the current declaration began continues it. A line at the same column starts the next
declaration. This is the offside rule, and it is what makes the block form of `where` work.

### Addressing validations

A field declaration creates a type scoped to that field, named by its path — see
[types.md](types.md). The `where` predicates attached to the field are properties of that
computed type, so **the path addresses the validation too**. No separate naming syntax is
needed, and none is provided:

```
app.commerce.Customer.email    -- the field's computed type, and its validation
Active.is_active               -- a trait field's type, and its validation
```

The path is what `assert` gets from its explicit name. The difference is that `assert` must be
named because it spans two paths and belongs to no single field, whereas a field's `where`
already has a path.

Origin is preserved under inheritance. A predicate inherited from a trait keeps its trait
address; a table that merges a field from two traits leaves all the origin addresses live
alongside its own:

```
trait A { name : Text where isNotEmpty }
trait B { name : Text where maxLen 100 }

table Bar : A, B {
  name : Text where isTitleCase
}
-- A.name, B.name, and Bar.name each address one predicate on the merged field
```

Addresses are used for error reporting (a rejected commit names the path that refused it),
for `:describe`, and for evolution — a validation is changed by redeclaring the field, and
the diff is taken per path.

#### Addressing one predicate in a block

Within one block, a predicate is addressed by the **function it applies, with its literal
arguments appended in order and no separators**. So `isValidEmail` addresses as
`isValidEmail`, and `minLen 12` addresses as `minLen12`:

```
enforce app.auth.User.username / minLen12 forward
```

The arguments are part of the address rather than elided, which is what this replaces. One
block may apply the same function twice — `inRange 0 10` beside `inRange 5 20` — and the whole
point of an address is to let a mode statement reach one predicate and not the other
([../integrity.md](../integrity.md#enforcement-modes)). Under the bare-function-name rule those
two collide, in exactly the case worth naming.

`ValidationRef` carries a single `Ident`
([railroad.md](railroad.md#enforcement-modes)), so an address has to lex as one. Two
predicates therefore have no address:

- an anonymous lambda, which applies no named function
- an application whose rendered arguments do not lex inside an `Ident` — a string literal, a
  negative number, any expression

Both are compile-time errors wherever an address is required, which is on a populated field,
where stating a mode is mandatory
([../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)). The fix for both
is the same and the diagnostic names it: give the predicate a top-level definition, which
gives it a name. Give one a top-level definition whenever its failure message matters, too —
an unnamed predicate reports the field path and nothing more.
