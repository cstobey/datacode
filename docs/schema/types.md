# Type System

See [README.md](README.md) for the `:` / `:>` rule, clause order, and layout conventions
assumed here.

## Primitive Types

Standard scalar types:

| Type | Description |
|---|---|
| `Text` | Unicode string |
| `Int` | Integer |
| `Decimal` | Arbitrary-precision decimal |
| `Bool` | Boolean |
| `Date` | Calendar date |
| `Timestamp` | Point in time |
| `DataId` | 12-byte globally unique identifier (see [../transaction-graph.md](../transaction-graph.md)) |

## Domain Types

Domain types are named subtypes of primitives. The `:` operator means "is a kind of".
Domain types carry validation functors, attached with `where`:

```
type Email  : Text    where isValidEmail
type Amount : Decimal where \a -> a >= 0
type Zip    : Text    where \z -> length z == 5
```

`where` restricts a type to the subset of its parent satisfying a predicate — the same
meaning it carries in queries and views, applied at the type level instead of the row
level. `type Email : Text where isValidEmail` reads as "the `Text`s where `isValidEmail`".

One `where` per declaration. Several predicates go in an indented block beneath it and are
implicitly conjoined:

```
type Username : Text
  where
    isNotEmpty
    maxLen 32
    \u -> not (containsWhitespace u)
```

A top-level declaration ends at the next token in column 0, so no terminator is needed
between type declarations:

```
type Email  : Text    where isValidEmail
type Amount : Decimal where \a -> a >= 0
```

The predicate is a validation functor (kind 1 — see [functors.md](functors.md)). It runs on
commit and rejects invalid values. A bare `a -> Bool` is lifted automatically; see
[functions.md](functions.md) for the auto-wrapping rules.

Domain types are reusable named types. When a field in a table references a domain type, it
creates a new named subtype scoped to that field (`namespace.table.field`) — validations are
inherited and can be extended. Two fields in different tables are always distinct types even
if they share the same domain type as their parent.

That scoped name is also the address of the field's validation: `app.commerce.Customer.email`
denotes the computed type and the predicates attached to it. See
[README.md](README.md#addressing-validations).

## Sum Types (ADTs)

The `|` operator builds sum types. This is the same operator used for relational union —
context (type-annotation position vs. query-expression position) disambiguates.

```
type CustomerStatus = Active | Suspended | Closed

-- Inline in a field declaration
status : Active | Suspended | Closed
```

Variants may carry a payload:

```
type CustomerStatus = Active | Suspended Text | Closed Date
```

## Product Types

Multiple fields in a record body form a product type. Tuple notation `(A, B)` is available
for and-types used outside a named record.

Note that an inline sub-table is *not* a product type — it creates a sibling table and an
FK reference to it. See [tables.md](tables.md).

## Absence Types

There is no `NULL`. Absent values are expressed as typed ADTs that extend the `Null` base
type. This encodes the *reason* for absence, not just the fact of it.

Built-in absence types (all extend `Null`):

| Type | Meaning |
|---|---|
| `NotFound` | Row or value does not exist |
| `Redacted` | Present but access-controlled away |
| `Pending` | Not yet computed or arrived |
| `Deleted` | Tombstoned in history |

Custom absence types:

```
type MissingCustomer      : Null
type NoActiveSubscription : Null
type NotGiven             : Null
```

These are ordinary type declarations — `Null` is a type, so the token is `:`.

Using absence types in fields:

```
phone       : Phone | NotGiven,        -- reason for absence is typed
billing_zip : Zip   | NotFound         -- built-in absence type
```

### Absence in Reference Position

There is a single `Null` root. Absence types are admissible in the tail of an alternation
regardless of whether the head is a type or a table, so the same custom absence type works
in both positions:

```
type MissingCustomer : Null

phone     : Phone    | NotGiven,          -- value absence, `:`
customer :> Customer | MissingCustomer    -- reference absence, `:>`
```

Only the head of the alternation decides the token. See the head rule in
[README.md](README.md#-versus-).

## The `is` Operator

`is` checks the outermost constructor of a sum type, regardless of any payload. Distinct
from `==`, which checks exact value equality including payload.

```
status is Active               -- constructor match (works with or without payload)
status is Suspended            -- matches any Suspended regardless of reason payload
status == Suspended "overdue"  -- exact equality including payload
phone is NotGiven              -- absence check
phone is not NotGiven          -- negation
```

`=` is never a comparison. It binds: field defaults, function definitions, sum-type
declarations, and `let`. Comparison is always `==`. This follows Haskell.
