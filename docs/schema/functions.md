# Functions

## Scope

Top-level declarations are **global** — committed to the schema transaction graph. `let` is
only for local bindings inside function bodies. There is no `def` keyword.

```
-- Top-level: stored in schema
isPositive a = a > 0

PremiumOrder = Order where total > 1000     -- a derived table, not a function

-- Local: inside a function body only
processOrder o =
  let discount = if o.total > 1000 then 0.1 else 0
  in o { total = o.total * (1 - discount) }
```

`PremiumOrder` is the case `=` does not settle on its own: a right-hand side containing a
query clause is a `Query`, so the declaration binds a **derived table** and takes a table's
`UpperCamelCase` name. A right-hand side with no query clause is an expression, so the
declaration is a function and takes a function's `lowerCamelCase`. See
[railroad.md](railroad.md#functions-and-expressions).

`o { total = … }` is functional record update — it produces a value and writes nothing. The
mutation that looks like it, `<query> { field = value }`, is a different production and is
reachable only from a script. See [queries.md](queries.md#mutation).

DataCode uses `let ... in` for local bindings, so `where` is free to mean "restrict to the
subset satisfying a predicate" in all three of its positions: type declarations, field
declarations, and queries.

## REPL transactions

The REPL stages everything typed and commits nothing until `:commit`; `:rollback` discards.
An exploratory query therefore cannot leave a schema change behind. See
[../cli.md](../cli.md#transaction-model).

## The effect ladder

Every DataCode computation runs in one of four effects. `IO` is not among them and never
appears in a DataCode signature.

| Effect | May do | Admissible in |
|---|---|---|
| `Pure a` | nothing but compute | anywhere |
| `Read a` | query at a supplied sample moment, never at a clock | validation, `assert`, foreign-key resolution, `on` and `every` conditions, `emit` payloads, `Behavior`, binding, template hole, render function, `every` interval |
| `Tx a` | query, and mutate within the current transaction | field default, internal derivation, API functor |
| `Effect a` | external calls, with capabilities granted by configuration | handler position, and compiled-in `Effect` roles registered as `Reference` rows |

**Which moment a `Read` reads at is fixed by the position, and none of them is a clock.**
Inside a commit it is the transaction's sample moment. Outside one it is the `Moment` a
behavior is applied to — which the scheduler ranges over the future — or the moment of the
scheduler tick, which is re-read per tick and carries no transaction. See
[Time is a parameter, never a read](#time-is-a-parameter-never-a-read).

**The "Admissible in" column is a ceiling, not an index.** The effect is inferred from the
body and checked against the position, so a cell names the strongest effect that position
admits rather than the effect everything written there carries. Field defaults sit in the
`Tx` row because `next` allocates — a read-modify-write on a counter row — and that
allocation is the only genuinely `Tx` default. A default on a field *added* to an existing
table must infer `Pure`, because every row older than the adding node computes it at read.
See [evolution.md](evolution.md#redeclare-a-table).

**`Effect` is wider than queue handlers, and the boundary is registration rather than
position.** A handler is the common case; a `system.crypto.WrappingAuthority` unwrapping a
data key at startup and at rotation is another, and the queued schema build is a third.
Each is compiled-in code named by a `Reference` row, which is what makes its existence
schema and compile-checked, and each draws its capabilities from its own `Configuration`
row.

`Pure ⊂ Read ⊂ Tx` — each lifts into the next, so an ordinary function is usable everywhere.
`Effect` sits outside that chain and connects to it through exactly one arrow:

```haskell
commit :: Tx a -> Effect a      -- exists
-- no   :: Effect a -> Tx a     -- and never will
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
`QueueState` field of its own queue. See [../events.md](../events.md#handlers).

**`commit` bounds retry cost, but it does not checkpoint the handler.** A retry re-enters the
handler at its first statement — nothing captures a continuation — so work done after a
`commit` is done again. What the `commit` buys is that its writes are durable and therefore
*visible* to the retry, which can read them and skip what they record. A full refresh that
commits per batch resumes at the last committed batch for that reason. So every external
call must be idempotent or guarded by committed state; placement alone does not make it safe.

**`Effect` wraps `IO`, and the wrapping is what the guarantee rests on.** A handler binds to
LDAP or puts to S3, and those libraries are typed in `IO`, so `Effect` has to reach them.
What makes it a boundary is construction rather than absence: an `Effect` value is built only
through a capability-granting primitive, and the host, credential, and timeout that primitive
uses come from the registering role's `Configuration` row rather than from the code. There is
no `MonadIO Effect`, no escape constructor, and no lift from `IO` into `Pure`, `Read`, or
`Tx` at all. A handler therefore cannot reach a destination the operator has not granted and
never holds a credential in a compiled constant.
[../dynamic-loading.md](../dynamic-loading.md#handler-workers-are-a-separate-pool) puts
handlers in their own process, so the OS enforces the same boundary the type does.

## Haskell functions

Functions are written in Haskell style. The effect is inferred from the body and checked
against the position, so a signature is optional and an explicit one is checked rather than
trusted.

**Haskell style is the surface; a functor body is a DSL term.** Validations, asserts, path
constraints, and event functors are effect-indexed GADT terms, interpreted rather than
compiled, and their vocabulary is the **registered primitive library** — not everything a
package exports. An operation the library does not carry has no term, whichever module it
lives in. That is also what makes the missing lift stronger than a signature check: inside
the DSL the type an external call would have to produce is unconstructible. Handlers are the
one exception and the whole of it — they are compiled in, they run in `Effect`, and arbitrary
Haskell is admissible there because a handler needs none of transparency, static access
analysis, or replay. See
[../dynamic-loading.md](../dynamic-loading.md#the-dsl-is-indexed-by-effect) and
[../events.md](../events.md#handlers).

Auto-wrapping rules:

- `a -> b` (pure) → lifted automatically
- `a -> Bool` → used directly as a `where` predicate; `False` becomes a validation failure
- `a -> Maybe b` → `Nothing` becomes a validation failure
- `a -> Either Error a` → used as-is; this is the native validation functor signature
- anything inferred as `Effect` → **rejected outside an `Effect` position** at schema commit

```
isValidEmail : Text -> Bool
isValidEmail e = e =~ "^[^@]+@[^@]+\\.[^@]+"

type Email : Text where isValidEmail
```

Available with no import: `Data.Text`, `Data.Time`, `Data.Maybe`, `Data.List`, `Data.Map`,
and the standard numeric packages — meaning the names of each that the primitive library
registers. Anything else requires an `import` at the schema file level, naming a package an
administrator has admitted to `system.config.AllowedPackage`. The allowlist gates which
libraries may be **registered**, because registration is what turns a name into a callable
term; `import` then selects from what is registered.

`Text.Regex.TDFA` is deliberately not among them. It is the engine behind the `=~`
primitive, not a user-facing library: exposing the module would hand back `matchTest` and
`makeRegex`, and a predicate could then take its pattern from the row being matched — the
exact case `=~` rejects at compile time. Matching is written with `=~`, whose right operand
is restricted to a `StringLit`, a `Reference` path, or a `Configuration` path, and whose
engine settings are normative in [railroad.md](railroad.md#functions-and-expressions).

On a field whose type is `Secret` — which every `Hashed` type is — only `a -> Bool` is
admitted. `a -> Either Error a` and `a -> Maybe b` are rejected, because their failure
channels can carry the value out into an error payload and thence into the append-only log,
where nothing can subsequently remove it. See [types.md](types.md#secret-types).

## Infix application

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

## Time is a parameter, never a read

`Data.Time`'s pure functions are available; its clock functions are not. `getCurrentTime` is
an `IO` action, and there is no lift from `IO` into `Pure`, `Read`, or `Tx`, so nothing
inside a functor can reach it. In `Effect` a clock would be a capability like any other,
granted by a `Configuration` row or absent — which is why the two places the system does
sample time are **runtime** code rather than author code. The runtime samples at exactly two
boundaries and passes the value in:

- **Request arrival**, which becomes the query's sample moment
  ([queries.md](queries.md#every-query-has-a-sample-moment)).
- **The scheduler tick** ([../events.md](../events.md#scheduler-architecture)).

That exclusion is doing more work than it appears to:

- A validation functor that reads the clock is not replayable, and the transaction graph
  guarantees that applying a transaction twice produces the same state.
- A materialized view that reads the clock cannot be recomputed, and derivable nonconformance
  depends on recomputation being exact (see [../integrity.md](../integrity.md)).
- A [behavior](types.md#behaviors) that read the clock would not be a function of time at all.

So a computation that needs the current time takes it as a parameter. Queries supply it as
the sample moment; behaviors take it as their `Moment` argument.

`Data.Time`'s calendar functions are available on the same terms as the rest of it — pure
only, no clock. What the standard library does **not** bind is a unit conversion: unit names
are `Duration` constants and converting is division
([types.md](types.md#units-are-values)); `Period` carries no millisecond count, so `+` and
`stepMonth` are the two calendar readings
([types.md](types.md#calendar-arithmetic-is-not-elapsed-arithmetic)); and a `Grain`
truncates into labelled buckets, with `isoWeekOf` the one function a schema is likely to
call directly ([types.md](types.md#grains-align-they-do-not-merely-coarsen)).

## Function types

A function type is declared with `type` and `=`, as in Haskell:

```
type Renderer   = Moment -> Doc -> Read Html
type LineFormat = Row -> Read Text
```

**A field may not write an arrow inline; it names a declared function type.** Two things
follow, and both are wanted rather than tolerated:

- **Every function in a field shares one signature**, by construction, because a field has a
  type. This is not a special rule about function columns; it is what a field is.
- **The signature has a name**, which is what diagnostics, `:describe`, and evolution diffs
  address it by.

`Behavior a ≅ Moment -> a` is this pattern with the arrow already hidden, and its mandatory
`=` lambda ([types.md](types.md#behaviors)) is the precedent for the value form below.

**A registry keyed by type name needs one signature covering every type.** `Renderer` read
`Amount -> Read Html` until this pass, and could not hold the `Rate` renderer stored in the
same column — the one-signature rule biting the case it was written for. The argument is a
`Doc` and the function dispatches inside, so the `render` column has one type, as a field
must. The alternative is a signature indexed by the row's `type_name`, which the language has
no dependent type to check.

**The `Moment` is a parameter for the same reason it is everywhere else.** A theme that
renders a `Timestamp` as "3 hours ago" is a function of the observation moment, and no
renderer may read a clock, so the moment arrives as an argument: the query's sample moment
([queries.md](queries.md#every-query-has-a-sample-moment)) reaches the render function
first. A renderer that ignores it is constant in that argument and costs nothing.

## Functions as column values

**A function-typed column is a `FunctorRef` with a static signature.** Storage changes nothing
— `FunctorRef` is already a column type in `system.api.CustomRoute` and
`system.api.FormatFunctor` ([../api.md](../api.md#custom-routes)), and it already points at a
serialized DSL term. What is new is that the compiler knows the signature, so the call site is
checked.

A value is written either as a reference to a top-level function or as a lambda literal:

```
system.ui.TypeRender { theme = Plain, type_name = "Amount", render = renderMoney }
system.ui.TypeRender { theme = Plain, type_name = "Rate",   render = \m d -> percent d 2 }
```

Both values inhabit one `Renderer`, which is what a field's type requires. The registry
itself — the theme table, `system.ui.TypeRender`, and its key `{ theme, type_name }` — is
declared in [../api-and-rendering.md](../api-and-rendering.md#themes). An insert is a `QName`
and a record literal; there is no `insert` keyword ([queries.md](queries.md#mutation)).

No new syntax was needed for either. Template Haskell-style quotation (`[| … |]`) was
considered and rejected: its whole appeal is the promise that arbitrary Haskell goes inside,
and the GADT DSL cannot cash that check (see [../dynamic-loading.md](../dynamic-loading.md)).
A syntax whose selling point is a permanent lie about the DSL's ceiling is worse than no
syntax. Heredocs and fenced blocks have the opposite defect — they are for text, and would
invite a stringly-typed body that never gets type-checked. Text-heavy cases are
[templates](templates.md), which are text with holes rather than functions with strings in
them.

### Where a literal is admissible

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

The first three follow from one fact — **function types have no equality**:

- Rejected in `unique`, `order by`, `group`, and `==`. Comparing functions would mean
  comparing source, under which alpha-equivalent functions differ and equivalent ones do not
  compare equal.
- Rejected in a candidate key, alongside `Secret`, `Doc`, and `Behavior`.
- Rejected with `indexed`, and no `WhereClause` is admitted on the field — there is no
  predicate over a function worth writing.
- **Queries in the body must be rooted at `self`**, the same anchoring rule asserts obey and
  for the same reason: a stored function runs per row on every read that reaches it, so an
  unanchored one would scan on every read. `self` is the row **holding** the column, not the
  row the function is applied to — the signature names every argument, and a value that
  arrived as an argument is not an anchor. Anchoring therefore bounds the stored function's
  own queries; the caller's read cost is bounded by the caller's own anchoring. See
  [constraints.md](constraints.md#anchoring).
- **The call graph over function columns must be acyclic.** Row A's function calling row B's
  is the feature; a cycle is a non-terminating query. Where the values are held on a
  `Reference` table the check runs at schema commit and is decidable, because inserting a
  `Reference` row *is* a schema transaction, so the whole call graph is in the schema graph.
  A function-typed `Configuration` column is repointed by an ordinary data write with no
  schema commit behind it, so the same check runs on that write and a write closing a cycle
  is rejected.
- **An `Effect` function type is name-only, never literal.** Effectful code is compiled-in
  Haskell registered in `system.events.Handler`, so a column of an `Effect` type holds that
  row's name — not a `FunctorRef`, because there is no serialized term to point at. A data
  write can select a handler; it can never author one.

### What this covers

| Case | Mechanism |
|---|---|
| Path constraint functors in a system table | `FunctorRef` — already the design |
| Trait and field functions in a table keyed by the types they apply to | same |
| A `Reference` table whose rows carry an operation for a linking table | function literal on a `Reference` table — the intended case |
| Per-type render functions for a theme | function literal on a `Reference` table; see [../api-and-rendering.md](../api-and-rendering.md#themes) |
| Templates | text with holes, not a function; see [templates.md](templates.md) |

The last two are what [../api-and-rendering.md](../api-and-rendering.md) already asked for as
"render functions per type, stored as reference data".

## Trait functions

Functions declared in a trait body are available on every table extending that trait, with
`self` bound to the row under evaluation. `self` is **contextual**: a trait function declares
no parameter for it, and none may be declared, because no declaration may introduce a name
colliding with a binding already in scope
([railroad.md](railroad.md#contextual-bindings)). The declaration form and its examples are
in [traits.md](traits.md#declaring-a-trait).
