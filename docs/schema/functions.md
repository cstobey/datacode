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

Standard library always available (no import needed): `Data.Text`, `Data.Time`,
`Data.Maybe`, `Data.List`, `Data.Map`, `Text.Regex.TDFA`, standard numeric packages.

Extra packages require `import` at the schema file level. The allowed package list is
managed by admins in `system.config.allowed_packages`.

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
