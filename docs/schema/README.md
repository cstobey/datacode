# Schema Model

The DataCode schema language, broken up by topic. This directory is the normative
reference for schema syntax and semantics. `../cli.md` covers the tooling that
*carries* this syntax (REPL, flags, admin and DR commands) and links here rather
than restating it.

| Document | Covers |
|---|---|
| [types.md](types.md) | Primitives, domain types, sum and product types, `Moment` and `Behavior`, absence types, `is`, `Secret`, `Hashed` |
| [tables.md](tables.md) | Table bodies, field declarations, defaults, candidate keys, ordering, foreign keys, sub-tables |
| [traits.md](traits.md) | Trait declaration, extension, multiple inheritance, replication traits, `Component`, `Keyless`, `Extensible` |
| [constraints.md](constraints.md) | `assert`, path equivalence, access control |
| [documents.md](documents.md) | The `Doc` type, shredding, key interning and spill |
| [aggregates.md](aggregates.md) | `aggregate` and `retain`, rollup chains, mergeable aggregates, log retention |
| [evolution.md](evolution.md) | Redeclaration, rename, deprecate, prune, split, merge, ADT extension, visibility |
| [queries.md](queries.md) | Filter, projection, joins, grouping, ordering, views, mutation |
| [functions.md](functions.md) | Scope, Haskell functions, auto-wrapping, imports |
| [functors.md](functors.md) | The four functor kinds, order of operations, enforcement modes |
| [railroad.md](railroad.md) | Full EBNF grammar + railroad diagram rendering |

Related documents outside this directory: [../namespaces.md](../namespaces.md) (namespace
tree), [../transaction-graph.md](../transaction-graph.md) (versioning, branches, identifiers),
[../storage.md](../storage.md) (physical layout), [../api.md](../api.md) (HTTP surface),
[../events.md](../events.md) (event scheduler), [../auth.md](../auth.md) (tokens),
[../integrity.md](../integrity.md) (nonconformance and enforcement modes).

## Design Philosophy

DataCode schemas are closer to TutorialD than SQL. The core shift:

- A **table** is a named collection of typed tuples (no row ordering, no implicit keys unless declared)
- A **field** has a precise type with associated validation functors
- A **query/view** is indistinguishable from a table definition — both are views over the transaction graph
- There is **no NULL** — absent values are expressed as typed ADTs with meaningful names
- Tables are organized in a **namespace tree** — namespaces replace the SQL "database" concept
- **Traits** provide abstract base types for tables, encoding replication policy, shared fields, and shared functions

### Self-Hosting Principle

**DataCode should use DataCode to manage its own operational data wherever practical.**

Every system concern that can be expressed as a table, should be. This includes:

- **API route registrations** — rows in `system.api.GeneratedRoute` and `system.api.CustomRoute`
- **Connector configurations** — rows in `system.connectors.*`
- **Event queues** — rows in `system.events.Item` (and user-defined queue tables in `app.*`)
- **Scheduler state** — rows in `system.events.*`
- **Auth tokens and sessions** — rows in `system.auth.*`
- **Schema version promotions** — rows in `system.VersionRef` (branches and tags share one table; the `VersionRef` ADT encodes which)
- **Operational metrics and logs** — rows in `system.logs.*` (logs shard, prunable)
- **HTTP request logs** — rows in `system.logs.HttpRequest` (per-server log shard)

The practical consequences:

- DataCode's own configuration is inspectable and queryable with standard DataCode tooling
- System operations (connector sync, event dispatch, shard maintenance) are auditable in the transaction log
- The IDE can show system state the same way it shows application state
- Bootstrapping is the only exception — the very first system tables must exist before DataCode can use DataCode to manage them

## Namespace Organization

Every table belongs to a namespace. Namespaces are dot-separated hierarchical paths:

- `app.commerce.Order` — user-defined application schema
- `connectors.mariadb.production.Order` — auto-generated connector shadow schema
- `system.auth.User` — DataCode self-management tables

Namespaces are created implicitly when a table is first defined in them — no explicit
creation syntax. Full namespace documentation: [../namespaces.md](../namespaces.md).

## Schema Visibility Layers

DataCode maintains multiple layers of schema simultaneously:

1. **Auto-generated connector shadow schemas** (`connectors.*`): created when a connector is added; updated automatically as the external schema changes; hidden from the default IDE view
2. **User-defined application schemas** (`app.*`): created by schema authors; may be views or extensions over connector schemas; visible by default
3. **System schemas** (`system.*`): DataCode internals; visible only to admin tokens

This layering enables data independence: the human-understood schema (`app.*`) can evolve
independently of the physical/connector schema underneath it, with coercion handled by
functors between the layers.

## Notation Conventions

These conventions recur throughout the language. They are defined once here and assumed
everywhere else.

### Capitalization

Follows Haskell: the things that name a *kind* are capitalized, the things that name an
*instance or a member* are not.

| Kind of name | Form | Examples |
|---|---|---|
| Type, trait, table, view | `UpperCamelCase`, **singular** | `Email`, `Amount`, `Active`, `UserData`, `Order`, `Customer` |
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

`:` means **is a kind of**. `:>` means **references a row in**. The correct token depends
on syntactic position:

| Position | Token | Right-hand side must be |
|---|---|---|
| `type A : B` | `:` | a type |
| `trait T : R` | `:` | a trait |
| `table T : R, S` | `:` | traits |
| field declaration | `:` | a type — no alternative may be a table |
| field declaration | `:>` | a table or view (see the head rule below) |

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

### Clause order

Field declarations take up to five trailing clauses, in this order:

```
field ( ":" | ":>" ) Type [ rename from Old | from Source ] [ unique ] [ indexed ] [ = Default ] [ where Predicate ]
```

`where` is last because it is the only clause with an open-ended expression on its right.
Fixing the order keeps a declaration parseable in one pass, with no lookahead to decide
where the default ends and the predicate begins.

`=` is binding only — field defaults, function definitions, sum-type declarations, `let`,
and row construction/update — and is never a comparison; comparison is `==`, as in Haskell.
Because a bare `=` therefore cannot appear at bracket depth 0 inside a predicate,
`total : Amount = 0 where isPositive` has exactly one parse.

Operator spelling follows Haskell throughout: `==`, `/=`, `&&`, `||`, `not`, `True`,
`False`. There are no `!=`, `and`, or `or` tokens.

### Backticks and `$`

Two Haskell conveniences, with Haskell's semantics and Haskell's fixities.

**Any named function may be written infix in backticks** (`infixl 9` — tighter than every
operator, looser than juxtaposition). This matters most for two-argument predicates, which
read as the assertions they are rather than as function calls:

```
attempt `matches` user.password
user.id `canRead` subject_table
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

Comments are `--` to end of line.

**Inside a body** (`table`, `view`, `trait`), field declarations are separated by `,` and
the body is closed by `}`. The separator may sit at the end of a declaration or at the start
of the next — leading-comma style keeps a block `where` readable, and is the recommended
style whenever any field in the body has one. A comma before the closing `}` is permitted:

```
table app.commerce.Customer {
  email : Email
    where
      isValidEmail
      maxLen 254
  , name  : Text
  , phone : Phone | NotGiven
}
```

**At top level** (`type`, `trait`, `table`, `view`, function definitions), there is no
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

This is the same path form already used to reference an inherited field
(`a_name : Text from A.name`), and it is what `assert` gets from its explicit name. The
difference is that `assert` must be named because it spans two paths and belongs to no
single field, whereas a field's `where` already has a path.

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

Within one block, a predicate is identified by the function it applies
(`app.commerce.Customer.email` / `isValidEmail`). An anonymous lambda has no name to report,
so give a predicate a top-level definition when its failure message matters.
