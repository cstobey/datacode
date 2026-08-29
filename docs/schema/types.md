# Type system

See [README.md](README.md) for the `:` / `:>` rule, clause order, and layout conventions
assumed here.

## Primitive types

Standard scalar types:

| Type | Description |
|---|---|
| `Text` | Unicode string; length is counted in code points |
| `Int` | Integer |
| `Decimal` | Arbitrary-precision decimal |
| `Bool` | Boolean |
| `Date` | Calendar date |
| `Timestamp` | A stored point in time |
| `Duration` | Signed elapsed time; canonical unit is the millisecond |
| `Period` | A calendar offset (`month`, `quarter`, `year`); no millisecond count |
| `Grain` | A truncation of the time axis into labelled buckets (`Hour`, `IsoWeek`, `Month`, …) |
| `Moment` | A point in the observation continuum — the parameter of a `Behavior` |
| `Bytes` | Opaque byte string, held in the row frame |
| `File` | A media type and an octet sequence of unbounded length, held in a chunk chain (see [Files](#files)) |
| `DataId` | 12-byte globally unique identifier (see [../transaction-graph.md](../transaction-graph.md)) |
| `Doc` | Tree-shaped data of unknown shape (see [documents.md](documents.md)) |

`DataId` is written without a role in the DSL — the phantom role that distinguishes a
transaction, row, and shard identifier in the implementation is inferred from position and is
not part of the surface syntax.

### Structural and system types

These are not scalars and none of them is spelled by a schema author in a `FieldDecl`, but each
appears in a signature or a system table, so each needs a definition:

| Type | What it holds | Owned by |
|---|---|---|
| `Table a` | A table-valued expression whose rows have type `a`. Produced by a query, by `group`'s generated `rows` column, and by a `:>` field to a `Component` target. Aggregate functions take one: `count : Table a -> Int`. | [queries.md](queries.md#aggregate-functions) |
| `Number` | The types that admit addition and scalar multiplication — `Int`, `Decimal`, `Duration`. It constrains a type argument (`sum : Table Number -> Number`) and is never a field's declared type. `Period` is excluded: no operator adds two of them. | this file |
| `Row t` | One row of table `t`. A function-typed column over rows names a concrete table or `Row t`; bare `Row` appears only in Haskell-level signature prose ([functors.md](functors.md), [../category-model.md](../category-model.md)) and is not a DataCode type, because it cannot say which table's row and so has no static field access. | [functions.md](functions.md#function-types) |
| `Ordinal` | The 4-byte position of a component under its parent at one nesting level, and the type of the `ordinal` virtual column. Never reused, not necessarily contiguous. | [traits.md](traits.md#what-component-changes) |
| `FunctorRef` | A reference to a functor stored in the schema graph as a serialized DSL term. It resolves like a foreign key to a schema node, so a referenced node is pinned against `prune` and a dangling reference is unrepresentable rather than typed. | [functors.md](functors.md) |
| `EventRef` | The work item an event functor returns: the queue table plus the identity of the row appended to it. | [functors.md](functors.md#event-functor) |
| `TypeRef` | Names a declared type in the schema graph — a queue's payload type, an effect signature. Same resolution and pinning as `FunctorRef`. | this file |
| `Html` | Text safe to emit into an HTML document without escaping. **It has no literal form**: the only producers are a template and a render function, which is what makes injection safety a typing property rather than a rule about output filters. | [templates.md](templates.md) |

Two names that look like missing types and are not. `TemplateBody` is a grammar production in
[railroad.md](railroad.md#templates), not a type — a template's `body` column is `Text`, parsed
against that production at schema commit. `FieldName | DocKey | Both` in
`system.crypto.ScrubRule` is an ordinary three-variant sum type declared inline, not three
undeclared types.

**A type used by one document's system tables is declared in that document**, as an ordinary
domain type. This file holds the types the whole language uses. So `ServerId`, `TokenId`,
`ChallengeCode`, `TableRef`, and `FormatRef` belong to [../api.md](../api.md) and
[../auth.md](../auth.md), and each is either a domain type over `DataId` or `Text`, or a `:>` to
the table it names — not a primitive.

**There is no list type.** `TypeExpr` has no `[T]` production and none is planned: a repeated
value is a `:>` to a `Component` sub-table, which gives it an ordinal, a range scan, and a
lifetime, none of which a bare list has. See [tables.md](tables.md#component-sub-tables).

### `Text` length is counted in code points

> **`Text` length is counted in Unicode scalar values. `length`, `minLen`, and `maxLen` all
> mean the same thing by it.**

This is already the de facto rule — `Data.Text` is auto-available and `Data.Text.length` counts
`Char`, which is a code point. Fixing it here rather than leaving it implied buys three things:

- **The MariaDB round trip is exact.** MySQL and MariaDB count `CHAR`/`VARCHAR` in *characters*
  under a multibyte charset, and `utf8mb4` covers all of Unicode. `VARCHAR(255)` is therefore
  255 code points and maps to `where maxLen 255` losslessly in both directions. Byte counting
  would reject valid source rows.
- **Grapheme clusters would not be deterministic.** UAX #29 boundaries are revised between
  Unicode versions, so a grapheme count depends on the ICU build of the server evaluating it.
  Two replicas could disagree, and a materialized-view refresh on an upgraded server could flip
  a violation on and off with no commit. That is the recomputation-determinism rule that already
  bans clock reads inside a functor ([functions.md](functions.md#time-is-a-parameter-never-a-read)),
  not a new one.
- **Byte length is still wanted sometimes**, so it gets its own name rather than overloading one.

| Predicate | Signature | Counts |
|---|---|---|
| `minLen` | `Int -> Text -> Bool` | code points, inclusive |
| `maxLen` | `Int -> Text -> Bool` | code points, inclusive |
| `maxBytes` | `Int -> Text -> Bool` | UTF-8 bytes, for a byte-limited external column or wire field |

Currying is what makes these work with no special form: `maxLen 254` is a `Text -> Bool`, which
is exactly what a `where` block takes and auto-lifts
([functions.md](functions.md#haskell-functions)).

Three consequences to state rather than discover:

- **No implicit trimming.** `maxLen` counts what is stored, trailing whitespace included.
  DataCode stores what it was given. `isTrimmed` is a predicate; trimming is never silent.
- **No implicit normalization.** `é` is one code point in NFC and two in NFD, so a client
  sending NFD gets a different count. Normalization is either a declared storage transform
  ([Canonical types](#canonical-types)) or an explicit predicate, never a hidden rewrite.
- `maxLen 0` is legal and means "empty only". A negative argument, or a `minLen`/`maxLen` pair
  that cannot both hold, is unsatisfiable by construction and rejected at schema commit — both
  arguments are literals, so the check is free.

## Domain types

Domain types are named subtypes of primitives. The `:` operator means "is a kind of".
Domain types carry validation functors, attached with `where`:

```
type Email  : Text    where isValidEmail
type Amount : Decimal where \a -> a >= 0
type Zip    : Text    where \z -> length z == 5
```

`where` restricts a type to the subset of its parent satisfying a predicate — the same
meaning it carries in queries, applied at the type level instead of the row
level. `type Email : Text where isValidEmail` reads as "the `Text`s where `isValidEmail`".

One `where` per declaration. Several predicates go in an indented block beneath it and are
implicitly conjoined:

```
type Username : Text
  where
    isNotEmpty
    maxLen 32
    \u -> not $ containsWhitespace u
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

**A rule phrased "a field whose type is `X`" means "whose computed field type has `X` in its
ancestor chain".** Field scoping makes type *identity* with `Secret`, `Doc`, `Behavior`, or a
function type false of every field, so every such rule would fire zero times if read literally.
`Secret`-ness, `Doc`-ness, `Behavior`-ness and function-typeness are inherited down the chain
and cannot be shed by wrapping the type in one more `type` declaration — which is the case that
makes the distinction load-bearing rather than pedantic.

### Length is a predicate, not a type argument

> **A type argument is warranted when it changes the representation or the set of admissible
> operations. A `where` predicate is warranted when it only narrows the value set.**

`Hashed Text` changes both — the stored bytes become a digest and `==` becomes a compile error.
`Encrypted Text` changes both. `Behavior a` changes read semantics. A length cap changes
neither, so it is a validation:

```
-- one-off
note : Text where maxLen 500

-- two bounds, each number labelled
username : Text
  where
    minLen 3
    maxLen 32

-- the reusable case: name the concept, declare the cap once
type PersonName : Text where maxLen 100
```

This replaces a proposed `Text 255` / `Text 1 255` type syntax. Four reasons, the third being
the one that decides it:

- **The first number would mean two things.** `Text 10` caps at 10 and `Text 10 200` floors at
  10, so adjacent field declarations would read differently for the same token — the same
  defect that retired the `days` conversion family, one position over.
- **A type argument has no address.** Every enforcement mode addresses a predicate by the
  function it applies (`… / maxLen`). A type argument is not a predicate and has nothing to
  name on the right of the `/`, so `enforce`, `monitor`, and `repair` could not reach a cap.
- **It would halt connector ingest.** A rule over connector-sourced data defaults to `monitor`
  precisely so one bad row cannot stop a binlog ([../integrity.md](../integrity.md#ingestion-must-not-enforce)).
  An over-length value under a type-level cap is *untypeable*: the commit fails and the stream
  stops. A predicate can be monitored; a type cannot.
- **`TypeArg` is a single token**, so `Hashed Text 255` parses as `Hashed` applied to three
  arguments rather than `Hashed (Text 255)`. Admitting the form would need a parenthesized
  `TypeArg` for one type's benefit.

`Text 255` stays *grammatical* — `Variant ::= QName TypeArg*` admits it — and is rejected at
name resolution with `where maxLen 255` in the diagnostic. That is a better error than a parse
failure at `255`, and it is the spelling a SQL author reaches for first. No type constructor
takes a `Literal` argument today; the alternative exists to give this diagnostic somewhere to
fire. See [railroad.md](railroad.md#types).

**Caps accumulate by conjunction, which is already the subtyping rule.** A field inherits its
domain type's predicates and extends them, so:

```
type Email : Text
  where
    isValidEmail
    maxLen 254

table app.commerce.Customer : UserData {
  customer_num : Int,
  email        : Email unique where maxLen 100,   -- effective cap: 100
  unique customerRef { customer_num }
}
```

Both predicates hold, so the effective cap is the minimum, and it is monotone in the tightening
direction only — declaring `maxLen 300` there widens nothing. A type-argument spelling would
have invited the opposite reading and then needed a variance rule nobody asked for.

The same answer covers numeric ranges, and the language already committed to it: `Decimal` is
arbitrary-precision by declaration and its scale is a predicate (`isRoundedToCents`), so
`type Percent : Int where \n -> n >= 0 && n <= 100` is the spelling. A genuinely fixed-point
`Decimal p s` *would* qualify under the discriminator above, which is how you can tell the rule
has teeth rather than being a blanket ban.

**Do not ship size-named types.** A name that is only a number is the number with extra steps,
and one of them becomes the default everyone reaches for until the cap stops meaning anything.
Name the concept — `PersonName`, `UrlPath`, `CountryCode`. A project that wants size grades
declares them in its own namespace, where they are its decision. For "most `Text` fields want a
cap", the lever is a linter warning on an uncapped `Text` field, not a default value nobody
chose.

## Sum types (ADTs)

The `|` operator builds sum types. It is also the alternation that separates the guard variants
of an outer join, which is one row picking one variant — **not** a relational union. There is no
binary union operator over two queries: `union`, `except`, and `intersect` were considered and
deliberately not reserved, because `diff` at two graph points and composition over rollup levels
answer what they were reaching for. See [queries.md](queries.md#outer-joins).

```
type CustomerStatus = Active | Suspended | Closed

-- Inline in a field declaration
status : Active | Suspended | Closed
```

Variants may carry a payload:

```
type CustomerStatus = Active | Suspended Text | Closed Date
```

## Product types

Multiple fields in a record body form a product type. Tuple notation `(A, B)` is available
for and-types used outside a named record.

**The tuple exists at the type level only.** There is no tuple literal, no tuple pattern in
`let` or a lambda, and no `fst`/`snd`, so a tuple-valued expression cannot be consumed. A
function that would return a pair is declared as two functions instead — which is why
[Grains align](#grains-align-they-do-not-merely-coarsen) below names `isoYearOf` and
`isoWeekNumberOf` rather than one function returning `(Int, Int)`.

Note that an inline sub-table is *not* a product type — it creates a sibling table and an
FK reference to it. See [tables.md](tables.md).

## Behaviors

A **behavior** is a value that varies continuously with time. Its denotation is a function from
a moment to a value:

```
⟦Behavior a⟧  :  Moment -> a
```

The denotation is total. The admissible *representations* are deliberately narrower — a
closed-form-solvable class — so the event scheduler can solve for a crossing rather than only
sample. That is why this is written as a denotation and not as an isomorphism: an arbitrary
`Moment -> a` can be sampled and not solved, and a scheduler that can only sample is a poller.
See [../category-model.md](../category-model.md#denotative-time).

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

  balance : Behavior Decimal = \t -> principal * (1 + rate * (t - opened_at) / day)
}
```

This is the normative declaration of `app.billing.Loan`; [tables.md](tables.md#behavior-fields)
and [traits.md](traits.md#behaviors-in-traits) show fragments of it and link here.

The `=` clause on a behavior field is its **definition**, not a default. A behavior has no
stored value for a default to stand in for, so the clause is mandatory. It is also the model for
the rule that every field added to an existing table carries a default: a behavior is computed
at read and never stored, so old and new rows read identically and the rule is satisfied by
construction. See [evolution.md](evolution.md#every-added-field-declares-a-default).

### The element type carries no predicates

A behavior's body is checked against the **parent primitive** of its declared element type, and
a declared element type carrying `where` predicates is rejected.

Arithmetic operates on the primitive and widens back to it, so
`\t -> principal * (1 + rate * (t - opened_at) / day)` has type `Moment -> Decimal`, not
`Moment -> Amount`. Nothing narrows it, and nothing could: coercion to a field's declared type
is step 1 of the **field-write** order ([functors.md](functors.md#order-of-operations-for-a-field-write)),
and a behavior has no write. `Behavior Amount` would therefore promise `a >= 0` that no functor
ever checks. Constrain the stored fields the behavior closes over instead — `principal : Amount`
and `rate : Rate` are where the predicate can actually run.

### One parameter, one domain

A behavior takes exactly one parameter and its type is always `Moment`. The other inputs —
`principal`, `rate`, `opened_at` — are not parameters. They are fields of the row, already
typed by the schema, and the behavior closes over them.

This is not a simplification. Two behaviors can be combined pointwise only if they share a
domain, and the event scheduler can solve for a crossing only over a domain it knows. A
behavior with a domain of its own would just be a function.

### `Moment` is not `Timestamp`

`Timestamp` is a stored point in time — `opened_at` is a value sitting in a row. `Moment` is
the point of observation and is never stored. Keeping them distinct prevents the one mistake
that would make a behavior meaningless: closing over "now" instead of taking it as a
parameter. A stored `Timestamp` cannot be passed where a `Moment` is expected.

`Moment` also ranges over the past and the future, which is why it is not called
`CurrentTime`. A historical query samples a behavior at a past moment; the scheduler
evaluates one at future moments to find when a condition *will* become true. Neither is now.
How a query supplies a moment, and what a future one means for row versions, is
[queries.md](queries.md#every-query-has-a-sample-moment).

| Expression | Result |
|---|---|
| `Moment - Moment` | `Duration` |
| `Moment - Timestamp` | `Duration` |
| `Timestamp - Timestamp` | `Duration` |
| `Timestamp + Duration` | `Timestamp` |
| `Moment + Duration` | `Moment` |
| `Timestamp + Period` | `Timestamp` |
| `Moment + Period` | `Moment` |
| `Duration + Duration` | `Duration` |
| `Duration - Duration` | `Duration` |
| `Duration / Duration` | `Decimal` |
| `Duration * Decimal`, `Decimal * Duration` | `Duration` |
| `Period * Int`, `Int * Period` | `Period` |

Scalar multiplication commutes, which is why both orders are listed — every expression in these
documents writes the scalar first (`7 * day`, `3 * month`), and a checker over three distinct
types needs the rule stated rather than assumed. `Period` and `Duration` never mix in either
direction.

`Moment` resolves to millisecond resolution on observation, matching `DataId`. The
*denotation* must not depend on that: a behavior meaningful only at millisecond boundaries is
a discrete signal and belongs in a stored field.

### Three kinds of time quantity

Elapsed time, calendar offsets, and bucket sizes are three different things. They were one
thing while `Duration` was the only type, and that hid two errors: a "month" with a fixed
millisecond count, and a bucket size that has no count at all.

| Type | Job | Constants |
|---|---|---|
| `Duration` | elapsed time; divisible, millisecond-canonical | `milli`, `second`, `minute`, `hour`, `day`, `week` |
| `Period` | a calendar offset added to a `Timestamp`; integer-scaled | `month`, `quarter`, `year` |
| `Grain` | a truncation of the time axis into labelled buckets | `Minute`, `Hour`, `Day`, `IsoWeek`, `Month`, `Quarter`, `Year`, `IsoYear` |

Capitalization carries the distinction where two of them would otherwise want the same word:
`hour` is an elapsed `Duration`, `Hour` is a `Grain`. This is the ordinary type/value case
rather than a special rule — `Grain`'s inhabitants are variants of a sum type, so they are
`UpperCamelCase` like every other variant ([README.md](README.md)).

### Units are values

`Duration`'s canonical unit is the millisecond, and unit names are **constants**, not
conversion functions. Converting is division:

```
rate * (t - opened_at) / day        -- "per day", because `day` is visible beside the rate
(closed_at - opened_at) / hour      -- Decimal hours
```

`Duration / Duration` is the one division that yields a dimensionless `Decimal`, which is what
makes this work without a dimensional type system. `*` and `/` are both `infixl 7`, so the
expression above needs no parentheses.

This replaced a family of conversion functions (`days`, `hours`, `minutes`, `seconds`,
`millis : Duration -> Decimal`). Three reasons:

- **A factor existed in two places.** The constant `day` and the function `days` were
  independent sources of the same number, which is the defect canonical-millisecond exists to
  prevent. Division derives the conversion from the constant.
- **One name was bound twice.** `7 days` is a duration literal and `days x` was an
  application, so `days` meant a scale word in one position and a function in another.
- **Units now compose.** `7 * day`, `2 * week`, and a user-defined `fortnight` in a
  `Reference` table all work with no standard-library entry each.

Consequently **no unit name is ever bound in the plural**, for a constant or a function. The
plural namespace is kept empty so the collision cannot recur.

### Calendar arithmetic is not elapsed arithmetic

A `Period` has no millisecond count and no conversion to `Duration` in either direction. That
is the entire point: `now + 3 * month` is a type error away from being wrong, because it is
`Period` arithmetic and gets calendar semantics rather than a 30-day approximation.

`Period` scales by `Int` only. A non-integral literal against a `Period` unit is rejected at
compile time rather than rounded — `2.5 month` denotes nothing.

**Calendar addition is not associative**, which is why one operator cannot cover both readings.
Take December 31 plus three months:

| | Result | Why |
|---|---|---|
| `d + 3 * month` | Mar 31 | one clamp, applied once from the origin |
| `stepMonth 3 d` | Mar 28 or 29 | Jan 31 → Feb 28/29 → Mar 28/29; the day-of-month never recovers |

`+` is the from-origin reading. `stepMonth : Int -> Timestamp -> Timestamp` accumulates one
month at a time, clamping at each step, so a value that lands on a short month stays there.
Both are wanted — the first for "three months from signup", the second for a schedule anchored
to a day-of-month that must not jump back out once it has been reduced.

`stepMonth` is singular for the same reason the plural namespace is empty. Rollover semantics
(Jan 31 + 1 month = Mar 3, as in `Data.Time`'s `addGregorianMonthsRollOver`) is deliberately
not provided.

Domain types carry validation, not dimensional algebra: `type Rate : Decimal` narrows the
value set, but arithmetic operates on `Decimal` and the result widens back to it. Canonical
`Duration` is what keeps that safe — every elapsed conversion pivots through one unit, so
there is exactly one place a factor can be wrong. `Period` sidesteps the question by having no
factor at all.

`week` is a `Duration` (`7 * day`), not a `Period`. On an unzoned `Timestamp` the two would be
indistinguishable — the calendar reading of "a day" only diverges from 86 400 000 ms once a
zone is in play, where "same wall-clock time tomorrow" crosses a DST boundary. `Period`
spellings of `day` and `week` are therefore **reserved rather than bound**: binding them now
would put one name on two types with no behavioural difference to justify it. They arrive with
zoned timestamps or not at all.

### Grains align, they do not merely coarsen

A `Grain` truncates the time axis and labels the result. Every grain declares the grains it
**aligns into** — those whose buckets its own buckets tile exactly — and that forms a rooted
DAG rather than a total order:

```
Minute → Hour → Day → Month → Quarter → Year
                Day → IsoWeek → IsoYear
```

One source, `Minute`. Two maximal grains, `Year` and `IsoYear`, because ISO weeks tile ISO
years exactly by construction and tile nothing on the calendar side. `Day` aligns into **two**
grains, which is why alignment is a relation rather than a parent pointer: a chain may branch
into the ISO side at `Day` and never back.

> **A step is admissible where its grain is reachable from its predecessor's along alignment
> edges.**

`IsoWeek → Month` looks like coarsening and is not: the week of January 29 straddles two
months, so merging week buckets into month buckets would put a bucket in a month it is only
partly inside. Following alignment edges makes that unrepresentable instead of a rounding
error nobody notices.

This is also what a millisecond comparison could never decide. `IsoWeek` is coarser than `Day`
and finer than `Month` while dividing neither evenly, so its position is *declared*, not
computed. See [aggregates.md](aggregates.md#grain-order) for the retention consequence.

**An `IsoWeek` bucket is labelled by ISO year, not calendar year.** December 29–31 can fall in
week 1 of the following ISO year, and January 1–3 in week 52 or 53 of the previous one, so a
calendar-year label would collide two different weeks. `bucket_start` is the Monday;
`isoYearOf : Timestamp -> Int` and `isoWeekNumberOf : Timestamp -> Int` return the two
components for anyone who wants the numbers directly. They are two functions rather than one
returning a pair because [tuples have no literal and no destructuring](#product-types).

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
row update literals, exactly as the virtual columns are
([tables.md](tables.md#basic-syntax)).

A behavior must be **total for every moment at or after the row's `created_at`**. The
scheduler evaluates behaviors at future moments to solve for crossings, and a partial function
has no crossing to find.

Behaviors are addressed by field path like any other computed field type
(`app.billing.Loan.balance`), so they appear in `:describe`, error messages, and evolution
diffs the same way everything else does.

A behavior shared across tables belongs in a trait, which supplies both the formula and the
fields it closes over — see [traits.md](traits.md#behaviors-in-traits).

## Absence types

There is no `NULL`. Absent values are expressed as typed ADTs that extend the `Null` base
type. This encodes the *reason* for absence, not just the fact of it.

Built-in absence types (all extend `Null`):

| Type | Meaning |
|---|---|
| `NotFound` | Row or value does not exist |
| `Redacted` | Present but access-controlled away |
| `NotYetComputed` | Not yet computed or arrived |
| `Deleted` | Tombstoned in history |
| `Erased` | Tombstoned and history closed — see [../integrity.md](../integrity.md#erasure-restricts-scrub-destroys) |
| `Sealed` | Present but not readable through a query — a `Secret` value |
| `TooLarge` | Present but above the configured inline-read cap — a `File` reachable only by streaming |
| `JsonNull` | An explicit `null` received in a document |
| `NoKey` | This node is identified by position, not by name (see [documents.md](documents.md)) |
| `NotRetained` | The retention policy did not cover this bucket (see [aggregates.md](aggregates.md)) |

**A built-in absence name is not available as an ordinary variant**, and the linter rejects
reuse. Nothing in the position distinguishes the two readings, and the consequences are
mechanical: an alternation *containing* a `Null`-derived variant is rejected from a candidate
key and from `unique`, it always matches in a join guard so an inner join silently becomes an
outer one, and it degenerates the derived key of any projection carrying it. An order status
typed that way would be rejected from a key for a reason its author could not read off the
declaration.

`NotYetComputed` was `Pending` until this pass, and the rename is what enforces the rule above
at the one place it was already broken: `Pending` was simultaneously the built-in absence type
and an ordinary status variant in an order table, a queue disposition, and the scheduler's own
state machine. Renaming the built-in was the cheaper direction — it had one use in the corpus
(`claimed_at : Timestamp | NotYetComputed`) and no example depended on the name, while
`Pending` is the natural word for an order that has been placed and not yet shipped.

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

### Absence in reference position

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

### Read-time absence variants

Two variants a reader can encounter are **supplied by the system and never declared**:

| Variant | When it appears | Declared type |
|---|---|---|
| `Sealed` | Every read of a `Secret` field, for every token | `T` |
| `Redacted` | A field or row behind an access assert the requesting token fails | `T` |

> **A `Secret` or access-constrained field's declared type is `T`; its **read** type is
> `T | Sealed` or `T | Redacted`.**

`is Sealed` and `is Redacted` are therefore admissible on such a field even though the
declaration names no such variant, and `:describe` and generated API types report the read
type. Stating this is what keeps "absence is typed" honest: these are the two absences the
declaration cannot carry, because a `Secret` field is *always* sealed and redaction depends on
who is asking, not on what was written. See
[constraints.md](constraints.md#redaction-scope) for the redaction half.

## Canonical types

`Canonical a` applies a **storage transform** to a value on write. It is the same hook the two
`Secret` constructors use — step 4 of the field-write order — widened to a transform that keeps
the value readable:

```
type Email : Canonical Text using system.text.Policy.email
```

`using` names a row in `system.text.Policy`, a `Reference` table, so the transform is schema,
replicated to every server, and versioned in the schema graph — the `Hashed … using` shape
exactly:

```
table system.text.Policy : Reference {
  name          : Text unique,
  case_fold     : Bool = False,
  normalization : Nfc | Nfd | NoNormalization = Nfc
}
```

This is how case-insensitive comparison is expressed, and it is deliberately **not** a second
equality operator. `==` stays exact. A case-insensitive `==` would have to be understood by
`unique`, by every index, by join matching, and by derived-key propagation — a large blast
radius for a convenience. Canonicalizing on write means `==`, `unique`, and the index are all
ordinary operations over ordinary bytes.

Four details decide whether this is right or subtly wrong:

- **Fold with `toCaseFold`, not `toLower`.** Full case folding is the correct operation — `ß`
  folds to `ss` — and `toLower` is the classic bug.
- **Normalization is the other half.** NFC is what actually reconciles the two encodings of
  `é`, and it runs at the same hook. That is why the transform names a policy row rather than
  being fixed: one type says "casefold and NFC".
- **Keep the original in a second field where display matters.** `email : Email unique`
  alongside `email_as_given : Text`. Explicit, free, and it makes the trade visible rather than
  hiding it inside a comparison operator.
- **A regex is not folded.** A bare `StringLit` pattern is always exact; a pattern that must be
  case-insensitive lives in a `Reference` pattern row carrying its own `case_sensitive` column,
  which is the same "a declaration that must name a policy names a row" rule.

**Rejected: a function in `UniqueDecl`** (`unique emailRef { fold email }`). It keeps the
original casing, but an index over `fold email` is usable only by a query that spells
`fold email`, so every lookup has to carry the function. Storing the canonical form and keeping
the original beside it costs the same bytes and reads better.

`Canonical` is not `Secret`: the stored value is the value, reads return it, and `==` works.
The transform is lossy in the same sense any normalization is — `maxLen` counts the *stored*
form, so a cap interacts with folding and the two should be read together.

## Files

A `File` is a **media type and an octet sequence** of unbounded length. The octets do not sit
in the row frame: they are a chain of `Component` chunk rows under the owning row, which is why
a `File` field costs nothing when a sibling scalar is written.

```
type Path : Text where isRelativePath

table app.web.Asset : UserData {
  site   :> Site,
  path    : Path,
  body    : File,
  unique assetRef { site, path }
}
```

`File` is a type, so the token is `:` and `logo : File | NotGiven` is an ordinary field
declaration. That the octets live in a generated sibling is a *storage* fact, and `Doc indexed`
already establishes that storage facts do not choose the token.

**Why `File` and not `Blob`.** DataCode is the origin: it serves the CSS and JS, so the HTTP
response needs a media type and the media type is part of the value rather than a convention
beside it. Rejected alternatives, each for its own reason:

- **`Blob`** — the design pass's proposal. It names octets only, and the media type had to be
  bolted on as a sibling FK that nothing forced an author to supply.
- **`Asset`** — web-specific. A scanned invoice is not an asset.
- **`Content`** — reads badly, and `content` is the likeliest field name for the thing.
- **`Stream`** — implies unbounded in *time*, and `Behavior` already owns the time axis.
- **Widening `Bytes`** — would make every `Bytes` field potentially unbounded, silently breaking
  `unique` and `==` on the digests and wrapped keys that use `Bytes` today.

### Virtual columns

A `File` field carries four columns, addressed by field path exactly as per-field timestamps
are:

| Column | Type | Holds | Key-eligible |
|---|---|---|---|
| `body.media_type` | `:> system.files.MediaType` | What the octets were written as. Never sniffed from the bytes. | yes |
| `body.digest` | `Bytes` | Content hash of the octets as written | yes |
| `body.length` | `Int` | Total octets | yes |
| `body.bytes` | `Bytes \| TooLarge` | The octets themselves, bounded (see below) | no |

The first three are immutable for the life of the value, so all three are key-eligible under
the existing rule, and `FieldPath` already admits `body.digest` in a `UniqueDecl` with no
grammar change. `body.bytes` is the payload rather than a fact about it, and it carries every
restriction the field itself does.

```
table system.files.MediaType : Reference, Extensible {
  name : Text unique,                     -- "TextCss", "ImageAvif" — what `is` matches
  iana : Text unique                      -- "text/css", "image/avif" — what the header carries
}
```

`Reference` because the fact originates outside the schema graph, in IANA; `Extensible` because
a deployment meets media types the schema did not anticipate. Making it a table rather than a
`Text` column is what makes `body.media_type is TextCss` checked at schema commit. The two
columns are two different things: the variant name has to be identifier-shaped, and the IANA
name is not.

> **The digest is for verification and transfer, never for identity.** Content-addressed pieces
> tempt deduplication, and deduplication is rejected: sharing one content row across owners
> breaks `erase` and collapses N access policies onto one row. This is exactly where the design
> departs from BitTorrent, whose whole model is content-addressed identity.

### Reading a file

`File` content is readable in `Read`, not only in `Effect`. The motivating case decides it: a
stylesheet is both served at a URL and inlined into rendered HTML for email, where mail clients
demand inline CSS, and a template hole is `Read` — so an `Effect`-only file cannot serve the
second path.

The read is bounded. `body.bytes` has type `Bytes | TooLarge`, and the cap is a `Configuration`
value; above it the octets are reachable only through the streaming handler. Typing the overflow
rather than failing the query is the ordinary discipline: the reason the value is absent is in
the type, and a template that inlines a stylesheet handles the oversized case the same way it
handles any other absence variant.

What is **not** available at any effect index:

- **No predicate over the octets.** A `where` on a `File` field may reference only
  `media_type`, `digest`, and `length`. A validation functor must be bounded and transparent so
  the optimizer can cost it and static access analysis can walk it, and reading a large payload
  inside a commit is what the effect ladder exists to prevent. A functor that must inspect
  octets runs in `Effect` off a queue.
- **No byte-range operator in the query language.** A file is projected whole or by handle.
  `substring body …` would invite a scan over unbounded values and give the optimizer nothing to
  cost. Ranging is a transport concern: an HTTP `Range` header resolves to a bounded contiguous
  scan over `ordinal`, which is already the column that states chunk order.

### Restrictions on a `File` field

`unique`, `indexed`, and `order by` are rejected on a `File` field, and it may not appear in a
`UniqueDecl`, in a candidate key, in a `GroupClause`, or as an operand of `==` or `/=`. An
arrangement over unbounded octets cannot mean what it says, and a comparison would read the
whole payload. `body.digest`, `body.length`, and `body.media_type` are admissible in every one
of those positions, which is how a file participates in a key at all.

Four more, each following from something already settled:

- **A `DefaultClause` on a `File` field must name a `Null`-derived variant.** A schema file is
  not where octets live.
- **A `File` field is rejected on a `Reference` or `Configuration` table.** Inserting a
  `Reference` row is a schema transaction replicated to every server, and an unbounded payload
  on that path is cluster-wide schema churn per write.
- **`Hashed File` is rejected**; `body.digest` is already the one-way projection, and `matches`
  against an unbounded input is not a credential check. **`Encrypted File` is admissible**, reads
  as `Sealed`, and is reached only by `reveal` in `Effect`, so no cipher sits between mmap and
  the Cap'n Proto message.
- **A `File` on a `LogData` table warns rather than rejects.** It is `system.events.Item`'s
  mistake — a payload nothing can inspect — *except* that a `LogData` table is the one place a
  `retain … drop` chain gives it a real discard path. The warning names the chain.

### Where the bytes live

Three placements, and only the first is invisible to the model.

**(a) In the graph, laid out by policy — the default.** Whether a file's chunks sit inline with
the parent's extent or in an extent of their own is a `Configuration` row beside
`system.shards.ExtentPolicy`, per field with a per-server override, resolved most-specific-first.
The size cap lives there too. Pure tuning: it tracks hardware, it must differ between staging
and production without branching the schema, and it changes nothing a query can observe. See
[../storage.md](../storage.md) for the layout and [../transaction-graph.md](../transaction-graph.md)
for the policy-row shape.

**(b) On the server filesystem — a separately named type, never a quiet flag.** An
`ExternalFile` holds a digest and a path; the bytes are outside the graph. It gives up four
properties a reader otherwise assumes:

- `verify shard` cannot check the bytes,
- replication does not carry them,
- a restore does not restore them,
- `scrub` cannot reach them.

That is why it is a type name rather than a per-field flag: the declaration is where the warning
has to be, because every one of those four failures is silent at the call site. `ExternalFile`
over a modifier for the same reason `Keyless` is a trait — writing it should feel like admitting
something.

**(c) Purely external — an ordinary `Text` URL.** No mechanism, no type, nothing to design. A
reference to something DataCode neither stores nor verifies is a string, and pretending
otherwise would promise properties it cannot deliver.

The size cap is documented rather than removed. The path past it is chunked, swarmed
distribution — each chunk its own transaction, announce-and-fetch widened from sequence ranges
to chunk digests — not a larger number. See [../distribution.md](../distribution.md).

## Secret types

**A type built with `Hashed` or `Encrypted` is `Secret`.** There is no user-applicable marker:
`Secret` names the property those two constructors carry, not a modifier a `TypeDecl` can write.
The property says that values of the type must not be readable back, must not appear in
diagnostics, and must not reach the transaction log in their original form.

`Secret` has four effects, all enforced at schema commit:

| Effect | Rule |
|---|---|
| Reads | The field resolves to `Sealed`, a `Null`-derived absence type. Never to the stored bytes, for any token. |
| Predicates | Only `a -> Bool` is admitted. `a -> Either Error a` and `a -> Maybe b` are rejected. |
| Comparison | `==` and `/=` against a `Secret` field are compile-time errors. |
| Diagnostics | Any error payload produced while handling the value is erased and replaced by the failing predicate's address. |

The predicate restriction is the substantive one, and the two rejected signatures are rejected
for different reasons:

- **`a -> Either Error a` can carry the value out in its `Error`.** An author writing
  `\p -> Left (Error ("rejected: " <> p))` would put a credential into the append-only log,
  where nothing can subsequently remove it. Restricting the signature removes the channel
  rather than policing its use.
- **`a -> Maybe b` leaks through its *success* channel, not its failure one.** `Nothing`
  carries nothing. The problem is that `b` is a different type, so the signature is a transform
  rather than a predicate, and a transform whose output is not `Secret` launders the plaintext
  out through the value channel.

Failures are reported by address, which is the reporting mechanism the language already uses
(see [README.md](README.md#addressing-validations)), so nothing is lost.

Erasing error payloads at the runtime boundary is a backstop for anything that slips past
the signature restriction, not the primary mechanism.

The `==` restriction exists because comparing secrets directly is both a timing side channel
and an invitation to compare stored digests instead of verifying inputs. Comparison goes
through `matches`, below.

**A literal default on an added `Secret` field is rejected.** Under the rule that every field
added to an existing table carries a default, a literal there would put one digest — or one
known plaintext — on every pre-existing row. The sound shape is `T | NotGiven = NotGiven`. Same
list as `unique`, `indexed`, and `order by` on a `Secret` field, and the reason is stronger: a
disclosure rather than an unenforceable constraint.

## Hashed types

`Hashed a` is a `Secret` type constructor: it accepts an `a`, validates it, and stores a
one-way digest of it.

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2
  where
    minLen 12
    \p -> not $ isBreached p
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
type MemoryKib   : Int
type Iterations  : Int
type CostLog2    : Int
type BlockSize   : Int
type Parallelism : Int

table system.crypto.HashPolicy : Reference {
  name       : Text unique,
  algorithm  : Argon2id MemoryKib Iterations Parallelism
             | Scrypt   CostLog2  BlockSize  Parallelism
             | Bcrypt   CostLog2,
  salt_bytes : Int where \n -> n >= 16
}
```

Algorithm parameters are operational and change as hardware does. Keeping them in a table
rather than in the type declaration means rotating them does not require redeclaring every
type that uses them, and means the current policy is queryable.

**The parameters ride on the variant, not beside it.** A flat parameter set fits Argon2id
alone: bcrypt takes one cost factor and a fixed 128-bit salt, and scrypt's three numbers are N,
r, and p — a cost parameter, a block size, and parallelism, none of which is "iterations" or
"memory in KiB". Three of six flat columns were therefore silently inapplicable for two of three
algorithms, in a language whose central claim is that the reason for absence lives in the type.
A payload-carrying variant makes each algorithm carry exactly its own parameters, so an
inapplicable column cannot be written. `salt_bytes` survives as a column because every
algorithm takes one; the 16-byte floor is NIST SP 800-63B's, and `Bcrypt` admits exactly 16
because its salt length is fixed by the algorithm — an assert, not a third parameter.

### Rotation

Changing the policy is repointing the type at a new policy row — a schema commit against a
populated field, which by the rule in [../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)
must declare an enforcement mode. The mode is `enforce forward`: existing digests keep
working, and every row hashed under the superseded policy becomes a reportable violation.

**The statement addresses the field path with no `/`.** A `ValidationRef`'s optional
`/ <predicate>` selects one predicate from a `where` block, and a storage transform is not a
predicate. A bare field path names the field's computed type as a whole, which is what the
transform belongs to:

```
enforce system.auth.Credential.secret forward
```

That is the whole rotation mechanism. It is the same machinery as any other tightened rule,
not a special path for credentials. See [../auth.md](../auth.md#password-policy-rotation) for
the login-time half.

### Comparison

```
attempt `matches` credential.secret
```

`matches : a -> Hashed a -> Bool` hashes its **left-hand** argument under the policy recorded on
the stored value to its right, and compares in constant time. It is the only way to test a
`Hashed` value.

The plaintext goes on the left because backtick infix is Haskell's — ``x `f` y`` is `f x y` —
and every call site in these documents puts the attempt first. The signature read
`Hashed a -> a -> Bool` until this pass, which typed every one of those call sites backwards
and, in the prose that went with it, asked the runtime to hash the stored digest.

Two restrictions:

- **`matches` is not a row filter.** ``Credential where attempt `matches` secret`` is a scan of
  every row against a per-row salt, and is rejected at compile time. It applies to a single
  resolved row — which `system.auth.Credential`'s key gives you directly, since a credential is
  keyed `{ user, method }`.
- **`unique` on a `Hashed` field is a compile-time error.** Per-row salts mean two identical
  inputs produce different digests, so the constraint would silently never fire — a lie the
  schema would keep telling forever.

`Hashed` is one-way. The reversible constructor is `Encrypted`, below.

## Encrypted types

`Encrypted a` is the second `Secret` constructor: it accepts an `a`, validates it, and stores a
ciphertext the server can recover. It exists for the two credentials that must be reproduced
rather than re-derived — an authenticator app's shared secret and a connector's outbound
credential.

```
type TotpSecret : Encrypted Text using system.crypto.CipherPolicy.totp_v1
```

The shape mirrors `Hashed a using …` exactly, and for the same reason: `using` names a policy
row, so the algorithm and its key reference are data rather than part of the type declaration.
Every stored value records the policy that produced it, which makes rotation the ordinary
`enforce forward` path rather than a special one.

### Decryption is an `Effect`, never a read

> **An `Encrypted` field reads as `Sealed` for every token. Plaintext is reached only by
> `reveal`, which runs in `Effect`.**

```
reveal : Encrypted a -> Effect (a | Sealed)
```

`reveal` returns `Sealed` where the calling handler's grant does not cover the field, so the
failure is a variant rather than an exception and the caller handles it the way it handles every
other absence. The argument is the field itself: a handler receives the row it was queued
against, and the `Encrypted a` value is reachable from that row inside `Effect` even though a
query projection of the same field yields `Sealed`. The difference is the effect index, not the
value.

This is the whole of the read story, and it is what keeps encryption off the query path. Both
consumers of a reversible secret are handler-side — TOTP verification and connector
authentication — so no cipher ever sits between mmap and the Cap'n Proto message, and
[../storage.md](../storage.md#full-zero-copy-read-path)'s zero-copy claim is untouched.

It also answers what a read returns to a token that may not decrypt: the same thing every other
token gets. Who may call `reveal` is an ordinary grant, decided where access is decided rather
than inside the type.

`Encrypted` inherits every `Secret` restriction — `Sealed` reads, `a -> Bool` predicates only,
no `==`, erased diagnostics — and adds none. `unique`, `indexed`, and `order by` are rejected on
such a field for the reason they are rejected on a `Hashed` one: the constraint or arrangement
would be over ciphertext and could not mean what it says.

Key custody, wrapping, and rotation are in
[../auth.md](../auth.md#envelope-encryption-and-key-custody).

## The `is` operator

`is` checks the outermost constructor of a sum type, regardless of any payload. Distinct
from `==`, which checks exact value equality including payload.

```
status is Active               -- constructor match (works with or without payload)
status is Suspended            -- matches any Suspended regardless of reason payload
status == Suspended "overdue"  -- exact equality including payload
phone is NotGiven              -- absence check
phone is not NotGiven          -- negation
secret is Sealed               -- read-time variant, admissible though undeclared
```

`=` is never a comparison. It binds: field defaults, function definitions, sum-type
declarations, and `let`. Comparison is always `==`. This follows Haskell.
