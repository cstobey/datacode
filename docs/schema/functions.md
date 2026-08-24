# Functions

## Scope

Top-level declarations are **global** — committed to the schema transaction graph. `let` is
only for local bindings inside function bodies. There is no `def` keyword.

```
-- Top-level: stored in schema
isPositive a = a > 0

premiumFilter = Order where total > 1000

-- Local: inside a function body only
processOrder order =
  let discount = if order.total > 1000 then 0.1 else 0
  in order { total = order.total * (1 - discount) }
```

DataCode uses `let ... in` for local bindings, so `where` is free to mean "restrict to the
subset satisfying a predicate" in all three of its positions: type declarations, field
declarations, and queries.

## REPL Transactions

The REPL operates in a transaction model: everything typed is staged but not committed
until `:commit`. Use `:rollback` to discard. This prevents accidental schema changes from
exploratory queries. See [../cli.md](../cli.md).

## The Effect Ladder

Every DataCode computation runs in one of four effects. `IO` is not among them and never
appears in a DataCode signature.

| Effect | May do | Admissible in |
|---|---|---|
| `Pure a` | nothing but compute | anywhere |
| `Read a` | query at the transaction's sample moment | validation, `assert`, `Behavior`, binding, template, render function, `every` interval |
| `Tx a` | query, and mutate within the current transaction | field default, internal derivation, API functor |
| `Effect a` | external calls, with capabilities granted by configuration | **handler position only** |

`Pure ⊂ Read ⊂ Tx` — each lifts into the next, so an ordinary function is usable everywhere.
`Effect` sits outside that chain and connects to it through exactly one arrow:

```haskell
commit :: Tx a -> Effect a     -- exists
       :: Effect a -> Tx a     -- does not, and will not
```

**That missing lift is the "no external calls inside a commit" rule.** It is a stronger
statement than rejecting an `a -> IO b` signature, because it also closes the compositions a
signature check misses — there is no way to `traverse` an effectful function inside a
validation, or to hide one behind a type alias, when the type it would have to produce is
unconstructible.

The arrow that *does* exist is what makes handlers workable. A handler runs in `Effect` and
calls `commit` as often as it needs to, so advancing a queue row's state, or writing 50 000
ingested rows in batches, is an ordinary transaction — subject to every validation, assert, and
access rule, because it *is* an ordinary transaction. A handler holds no privilege beyond the
`QueueState` field of its own queue. `commit` also fixes retry granularity: everything before
the first `commit` is redone on retry, everything after is not. See
[../events.md](../events.md#handlers).

`Effect`'s capabilities — reachable hosts, credentials, timeouts — come from the handler's
`Configuration` row rather than from the code, so a handler cannot reach a destination the
operator has not granted and never holds a credential in a compiled constant.

## Haskell Functions

Functions are written in Haskell style. The effect is inferred from the body and checked
against the position, so a signature is optional and an explicit one is checked rather than
trusted.

Auto-wrapping rules:

- `a -> b` (pure) → lifted automatically
- `a -> Bool` → used directly as a `where` predicate; `False` becomes a validation failure
- `a -> Maybe b` → `Nothing` becomes a validation failure
- `a -> Either Error a` → used as-is; this is the native validation functor signature
- anything inferred as `Effect` → **rejected outside handler position** at schema commit

```
import Data.Time (UTCTime, diffUTCTime)

-- Standard library is auto-available; extra packages via import
validateEmail : Text -> Bool
validateEmail e = e =~ "^[^@]+@[^@]+\\.[^@]+"

type Email : Text where validateEmail
```

On a field whose type is `Secret` — which every `Hashed` type is — only `a -> Bool` is
admitted. `a -> Either Error a` and `a -> Maybe b` are rejected, because their failure
channels can carry the value out into an error payload and thence into the append-only log,
where nothing can subsequently remove it. See [types.md](types.md#secret-types).

## Infix Application

A named function may be written infix in backticks, as in Haskell, at Haskell's default
fixity for the form (`infixl 9`):

```
attempt `matches` user.password
```

`$` is low-precedence right-associative application (`infixr 0`), which reads as an opening
parenthesis that closes at the end of the expression:

```
\p -> not $ isBreached p || isCommonWord p
```

Both are covered in [README.md](README.md#backticks-and-) and specified in
[railroad.md](railroad.md#functions-and-expressions).

Standard library always available (no import needed): `Data.Text`, `Data.Time`,
`Data.Maybe`, `Data.List`, `Data.Map`, `Text.Regex.TDFA`, standard numeric packages.

### Time Is a Parameter, Never a Read

`Data.Time`'s pure functions are available; its clock functions are not. `getCurrentTime` is
an `IO` action, and there is no lift from `IO` into any DataCode effect — not even `Effect`,
whose external capabilities are the ones its configuration grants and nothing else. That
exclusion is doing more work than it appears to:

- A validation functor that reads the clock is not replayable, and the transaction graph
  guarantees that applying a transaction twice produces the same state.
- A materialized view that reads the clock cannot be recomputed, and derivable nonconformance
  depends on recomputation being exact (see [../integrity.md](../integrity.md)).
- A [behavior](types.md#behaviors) that read the clock would not be a function of time at all.

So a computation that needs the current time takes it as a parameter. Queries supply it as
the sample moment ([queries.md](queries.md#every-query-has-a-sample-moment)); behaviors take
it as their `Moment` argument.

Unit names are `Duration` **constants**, so converting is division rather than a function
call:

```
rate * (t - opened_at) / day
```

The unit stays visible next to the rate, and the factor lives in exactly one place. This
replaced a family of `Duration -> Decimal` conversions (`days`, `hours`, …) that bound the
plural unit names a second time; see [types.md](types.md#units-are-values).

Calendar arithmetic uses `Period`, which has no millisecond count. `+` adds from the origin;
`stepMonth :: Int -> Timestamp -> Timestamp` accumulates a month at a time, clamping at each
step:

```
signed_at + 3 * month     -- Dec 31 → Mar 31
stepMonth 3 signed_at     -- Dec 31 → Mar 28 or 29
```

`Data.Time`'s calendar functions are available on the same terms as the rest of it — pure
only, no clock. `isoWeekOf :: Timestamp -> (Int, Int)` returns an ISO year and week number,
which is not derivable from the calendar year (see
[types.md](types.md#grains-align-they-do-not-merely-coarsen)).

Extra packages require `import` at the schema file level. The allowed package list is
managed by admins in `system.config.AllowedPackage`.

## Function Types

A function type is declared with `type` and `=`, as in Haskell:

```
type Renderer   = Amount -> Read Html
type LineFormat = Row   -> Read Text
```

**A field may not write an arrow inline; it names a declared function type.** Two things
follow, and both are wanted rather than tolerated:

- **Every function in a field shares one signature**, by construction, because a field has a
  type. This is not a special rule about function columns; it is what a field is.
- **The signature has a name**, which is what diagnostics, `:describe`, and evolution diffs
  address it by.

`Behavior a ≅ Moment -> a` is this pattern with the arrow already hidden, and its mandatory
`=` lambda ([types.md](types.md#behaviors)) is the precedent for the value form below.

## Functions as Column Values

**A function-typed column is a `FunctorRef` with a static signature.** Storage changes nothing
— `FunctorRef` is already a column type in `system.api.CustomRoute` and
`system.events.Handler`, and it already points at a serialized DSL term. What is new is that
the compiler knows the signature, so the call site is checked.

A value is written either as a reference to a top-level function or as a lambda literal:

```
insert system.ui.TypeRender { type_name = "Amount", render = renderMoney }
insert system.ui.TypeRender { type_name = "Rate",   render = \r -> percent r 2 }
```

No new syntax was needed for either. Template Haskell-style quotation (`[| … |]`) was
considered and rejected: its whole appeal is the promise that arbitrary Haskell goes inside,
and the GADT DSL cannot cash that check (see [../dynamic-loading.md](../dynamic-loading.md)).
A syntax whose selling point is a permanent lie about the DSL's ceiling is worse than no
syntax. Heredocs and fenced blocks have the opposite defect — they are for text, and would
invite a stringly-typed body that never gets type-checked. Text-heavy cases are
[templates](templates.md), which are text with holes rather than functions with strings in
them.

### Where a Literal Is Admissible

| Table trait | Function literal | `FunctorRef` |
|---|---|---|
| `Reference` | yes | yes |
| `Configuration` | no | yes |
| anything else | no | no |

**`Reference` tables may hold a function literal because inserting a `Reference` row is
already a schema transaction** ([traits.md](traits.md#reference-tables-are-code)). It
compiles, it is versioned by schema node, it is transparent, it replicates everywhere. "It
still has to compile" is satisfied structurally rather than by a rule bolted on.

**`Configuration` tables may hold a `FunctorRef` only.** A literal there would be code
arriving by data write, breaking "every loaded code unit references a schema graph node".
`system.api.CustomRoute` is already exactly this and needs no change.

So: **code by schema, selection-among-code by data.**

### Restrictions

All but the last follow from one fact — **function types have no equality**:

- Rejected in `unique`, `order by`, `group`, and `==`. Comparing functions would mean
  comparing source, under which alpha-equivalent functions differ and equivalent ones do not
  compare equal.
- Rejected in a candidate key, alongside `Secret`, `Doc`, and `Behavior`.
- Rejected with `indexed`, and no `WhereClause` is admitted on the field — there is no
  predicate over a function worth writing.
- **Queries in the body must be rooted at `self`**, the same anchoring rule asserts obey and
  for the same reason: a stored function runs per row on every read that reaches it, so an
  unanchored one would scan on every read. See [constraints.md](constraints.md#anchoring).
- **The call graph over function columns must be acyclic**, checked at schema commit. Row A's
  function calling row B's is the feature; a cycle is a non-terminating query. The call graph
  is in the schema graph, so this is decidable rather than a runtime depth limit.
- **An `Effect` function type is name-only, never literal.** Effectful code is compiled-in
  Haskell registered in `system.events.Handler`, so a column of an `Effect` type holds that
  row's name. A data write can select a handler; it can never author one.

### What This Covers

| Case | Mechanism |
|---|---|
| Path constraint functors in a system table | `FunctorRef` — already the design |
| Trait and field functions in a table keyed by the types they apply to | same |
| A `Reference` table whose rows carry an operation for a linking table | function literal on a `Reference` table — the intended case |
| Per-type render functions for a theme | function literal on a `Reference` table; see [templates.md](templates.md) |
| Templates | text with holes, not a function; see [templates.md](templates.md) |

The last two are what [../api-and-rendering.md](../api-and-rendering.md) already asked for as
"render functions per type, stored as reference data".

## Trait Functions

Functions declared in a trait body are available on every table extending that trait, with
`self` bound to the row. See [traits.md](traits.md):

```
trait Active {
  is_active : ActiveStatus | InactiveStatus,

  active   self = self where is_active is ActiveStatus,
  inactive self = self where is_active is InactiveStatus
}
```
