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
type Password : Hashed Text using system.crypto.password_v2
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

`using` names a row in `system.crypto.hash_policies`, a `Reference` table — so a policy is
schema, replicated to every server, and versioned in the schema graph:

```
table system.crypto.hash_policies : Reference {
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
