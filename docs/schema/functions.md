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

## Haskell Functions

Functions are written in Haskell style. Types are automatically threaded through the system
monad.

Auto-wrapping rules:

- `a -> b` (pure) → lifted automatically
- `a -> Bool` → used directly as a `where` predicate; `False` becomes a validation failure
- `a -> Maybe b` → `Nothing` becomes a validation failure
- `a -> Either Error a` → used as-is; this is the native validation functor signature
- `a -> IO b` → **rejected** at schema commit; use an event functor queue instead (see [../events.md](../events.md))

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

`Data.Time`'s pure functions are available; its clock functions are not, because
`getCurrentTime :: IO UTCTime` is an `a -> IO b` and is rejected by the rule above. That
rejection is doing more work than it appears to:

- A validation functor that reads the clock is not replayable, and the transaction graph
  guarantees that applying a transaction twice produces the same state.
- A materialized view that reads the clock cannot be recomputed, and derivable nonconformance
  depends on recomputation being exact (see [../integrity.md](../integrity.md)).
- A [behavior](types.md#behaviors) that read the clock would not be a function of time at all.

So a computation that needs the current time takes it as a parameter. Queries supply it as
the sample moment ([queries.md](queries.md#every-query-has-a-sample-moment)); behaviors take
it as their `Moment` argument.

`Duration` conversions are ordinary stdlib functions:

```
days, hours, minutes, seconds, millis :: Duration -> Decimal
```

Write them at the use site — `rate * days (t - opened_at)` — so the unit a rate is expressed
in is visible next to the rate.

Extra packages require `import` at the schema file level. The allowed package list is
managed by admins in `system.config.AllowedPackage`.

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
