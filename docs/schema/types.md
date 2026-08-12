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
| `Timestamp` | A stored point in time |
| `Duration` | Signed elapsed time; canonical unit is the millisecond |
| `Moment` | A point in the observation continuum — the parameter of a `Behavior` |
| `Bytes` | Opaque byte string |
| `DataId` | 12-byte globally unique identifier (see [../transaction-graph.md](../transaction-graph.md)) |
| `Doc` | Tree-shaped data of unknown shape (see [documents.md](documents.md)) |

`DataId` is written without a role in the DSL — the phantom role that distinguishes a
transaction, row, and shard identifier in the implementation is inferred from position and is
not part of the surface syntax.

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

## Behaviors

A **behavior** is a value that varies continuously with time. It denotes a function from a
moment to a value:

```
Behavior a  ≅  Moment -> a
```

Behaviors express quantities that change without anything being written: accruing interest, a
depreciating asset, a trial countdown, a decaying rate limit. Nothing is stored — the value is
computed from the row's stored fields at the moment it is observed.

```
table app.billing.Loan : UserData {
  customer  :> Customer,
  account   : AccountNumber,
  principal : Amount,
  rate      : Rate,
  opened_at : Timestamp,

  unique loanRef { customer, account },

  balance : Behavior Amount = \t -> principal * (1 + rate * days (t - opened_at))
}
```

The `=` clause on a behavior field is its **definition**, not a default. A behavior has no
stored value for a default to stand in for, so the clause is mandatory.

### One Parameter, One Domain

A behavior takes exactly one parameter and its type is always `Moment`. The other inputs —
`principal`, `rate`, `opened_at` — are not parameters. They are fields of the row, already
typed by the schema, and the behavior closes over them.

This is not a simplification. Two behaviors can be combined pointwise only if they share a
domain, and the event scheduler can solve for a crossing only over a domain it knows. A
behavior with a domain of its own would just be a function.

### `Moment` Is Not `Timestamp`

`Timestamp` is a stored point in time — `opened_at` is a value sitting in a row. `Moment` is
the point of observation and is never stored. Keeping them distinct prevents the one mistake
that would make a behavior meaningless: closing over "now" instead of taking it as a
parameter. A stored `Timestamp` cannot be passed where a `Moment` is expected.

`Moment` also ranges over the past and the future, which is why it is not called
`CurrentTime`. A historical query samples a behavior at a past moment; the scheduler
evaluates one at future moments to find when a condition *will* become true. Neither is now.

| Expression | Result |
|---|---|
| `Moment - Moment` | `Duration` |
| `Moment - Timestamp` | `Duration` |
| `Timestamp - Timestamp` | `Duration` |
| `Timestamp + Duration` | `Timestamp` |
| `Moment + Duration` | `Moment` |

`Moment` resolves to millisecond resolution on observation, matching `DataId`. The
*denotation* must not depend on that: a behavior meaningful only at millisecond boundaries is
a discrete signal and belongs in a stored field.

### Units

`Duration`'s canonical unit is the millisecond. Conversions are ordinary standard-library
functions, not a dimensional type system:

```
days, hours, minutes, seconds, millis :: Duration -> Decimal
```

Write the conversion at the use site — `rate * days (t - opened_at)` — rather than folding a
factor into the expression. `rate` then means "per day" because `days` is visible beside it,
and the factor is written once in the standard library instead of once per behavior.

Domain types carry validation, not dimensional algebra: `type Rate : Decimal` narrows the
value set, but arithmetic operates on `Decimal` and the result widens back to it. Canonical
`Duration` is what keeps that safe — every conversion pivots through one unit, so there is
exactly one place a factor can be wrong.

### Restrictions

A behavior's value changes with no write, which rules out everything that assumes a stored
value is current:

| Rejected on a behavior field | Reason |
|---|---|
| `unique` | The constraint would hold at some moments and not others. Same reasoning as `unique` on a `Hashed` field: a constraint that cannot fire is a lie the schema keeps telling. |
| `indexed` | An index would be stale the moment it was written |
| `order by` | Undefined without a stated moment |
| `where` | The predicate would have to hold at every moment, which is undecidable in general. Constrain the stored fields the behavior closes over instead. |

Behaviors are **read-only**. Having no stored bytes, they are rejected in row construction and
row update literals, exactly as `created_at` and `updated_at` are.

A behavior must be **total for every moment at or after the row's `created_at`**. The
scheduler evaluates behaviors at future moments to solve for crossings, and a partial function
has no crossing to find.

Behaviors are addressed by field path like any other computed field type
(`app.billing.Loan.balance`), so they appear in `:describe`, error messages, and evolution
diffs the same way everything else does.

A behavior shared across tables belongs in a trait, which supplies both the formula and the
fields it closes over — see [traits.md](traits.md#behaviors-in-traits).

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
| `Sealed` | Present but one-way — a `Secret` value that cannot be read back |
| `JsonNull` | An explicit `null` received in a document |
| `NoKey` | This node is identified by position, not by name (see [documents.md](documents.md)) |
| `NotRetained` | The retention policy did not cover this bucket (see [aggregates.md](aggregates.md)) |

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

## Secret Types

A type may be marked **`Secret`**. This is a property of the type, not a functor and not an
access rule: it says that values of this type must not be readable back, must not appear in
diagnostics, and must not reach the transaction log in their original form.

Marking a type `Secret` has four effects, all enforced at schema commit:

| Effect | Rule |
|---|---|
| Reads | The field resolves to `Sealed`, a `Null`-derived absence type. Never to the stored bytes. |
| Predicates | Only `a -> Bool` is admitted. `a -> Either Error a` and `a -> Maybe b` are rejected. |
| Comparison | `==` and `/=` against a `Secret` field are compile-time errors. |
| Diagnostics | Any error payload produced while handling the value is erased and replaced by the failing predicate's address. |

The predicate restriction is the substantive one. A validation functor with signature
`a -> Either Error a` can carry a value out in its `Error`, and an author writing
`\p -> Left (Error ("rejected: " <> p))` would put a credential into the append-only log,
where nothing can subsequently remove it. Restricting the signature removes the channel
rather than policing its use. Failures are reported by address, which is the reporting
mechanism the language already uses (see
[README.md](README.md#addressing-validations)), so nothing is lost.

Erasing error payloads at the runtime boundary is a backstop for anything that slips past
the signature restriction, not the primary mechanism.

The `==` restriction exists because comparing secrets directly is both a timing side channel
and an invitation to compare stored digests instead of verifying inputs. Comparison goes
through `matches`, below.

## Hashed Types

`Hashed a` is a `Secret` type constructor: it accepts an `a`, validates it, and stores a
one-way digest of it.

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2
  where
    minLen 12
    \p -> not (isBreached p)
```

The `where` predicates run on the **input** — the plaintext — because that is the only thing
worth validating. The digest is produced afterwards, and nothing downstream of the transform
ever sees the input again. The full ordering is in
[functors.md](functors.md#order-of-operations-for-a-field-write).

Hashing is not written as a predicate at the end of a `where` block, even though that is
where it belongs in the pipeline. A validation functor is `a -> Either Error a`: same type in,
same type out. Hashing is one-way and changes the field's type, so expressing it as a
predicate would make it look composable with predicates when it is not. Making it the type is
also what puts it in control of the Cap'n Proto encoding, which is how "the plaintext never
enters the mutation list" becomes structural rather than a rule someone has to remember.

### Policies

`using` names a row in `system.crypto.HashPolicy`, a `Reference` table — so a policy is
schema, replicated to every server, and versioned in the schema graph:

```
table system.crypto.HashPolicy : Reference {
  name        : Text unique,
  algorithm   : Argon2id | Scrypt | Bcrypt,
  memory_kib  : Int,
  iterations  : Int,
  parallelism : Int,
  salt_bytes  : Int
}
```

Algorithm parameters are operational and change as hardware does. Keeping them in a table
rather than in the type declaration means rotating them does not require redeclaring every
type that uses them, and means the current policy is queryable.

### Rotation

Changing the policy is repointing the type at a new policy row — a schema commit against a
populated field, which by the rule in [../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)
must declare an enforcement mode. The mode is `enforce forward`: existing digests keep
working, and every row hashed under the superseded policy becomes a reportable violation.

That is the whole rotation mechanism. It is the same machinery as any other tightened rule,
not a special path for credentials. See [../auth.md](../auth.md#password-policy-rotation) for
the login-time half.

### Comparison

```
attempt `matches` user.password
```

`matches : Hashed a -> a -> Bool` hashes its right-hand argument under the stored policy and
compares in constant time. It is the only way to test a `Hashed` value.

Two restrictions:

- **`matches` is not a row filter.** ``User where attempt `matches` password`` is a scan of
  every row against a per-row salt, and is rejected at compile time. It applies to a single
  resolved row.
- **`unique` on a `Hashed` field is a compile-time error.** Per-row salts mean two identical
  inputs produce different digests, so the constraint would silently never fire — a lie the
  schema would keep telling forever.

`Hashed` is one-way. Reversible encryption at rest is a different type with different key
management and is not currently specified.

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
