# Queries, derived tables, and mutation

A query is an expression that denotes a table. A `table` declaration declares stored structure
and constraints. A binding names a query. All three denote the same kind of thing, so there is
no separate schema object called a view:

```
table app.commerce.Order : UserData { ... }        -- declares storage and constraints
ActiveOrder = Order where status is Active         -- names a query
```

The difference between them is whether anything is stored and whether constraints are
declared — not what kind of value they are. Whether a derived table is *maintained* as stored
rows is a storage decision made separately; see [../storage.md](../storage.md#materialization).

## Filter, projection, alias

```
Order >< Customer
  where total > 100
  { customer.name as name, total as order_total, applyTax (total) as with_tax }
```

- `where` filters rows.
- `{ field, ... }` projects. There is no `select` keyword.
- `as` renames.

A projection item is a field path, an expression, or `*`. A bare path keeps the source field's
name and type. An expression **requires** `as`, because a computed column has no name to
inherit. For what an expression does to a derived table's field type, see
[Field types](#field-types).

Reference fields as `TableName.field_name` or `alias.field_name`. Use a table alias when the
full namespace path is in the name.

`where` here is the row-level form of the operator used at type level in declarations (see
[types.md](types.md)). Both restrict to the subset satisfying a predicate.

## The `*` selector

`*` expands to every field of its source that no other item in the projection mentions.
Qualify it (`User.*`) to pick one side of a join.

```
-- Bulk copy
OrderSummary = connectors.mariadb.production.Order { * }

-- Recompute one field, carry the rest
Order = connectors.mariadb.production.Order { *, toOrderStatus (status) as status }

-- Rename one field, carry the rest
Customer = Customer { *, status as account_status }
```

**Naming a source field anywhere in the projection removes it from `*`.** That is what makes
the third line a rename rather than a copy: `status` is mentioned, so `*` skips it, and the
only surviving column is `account_status`. The second line reads the same way — `status` is
mentioned and re-added under its own name, so the coercion replaces the column instead of
duplicating it.

To keep both the original and a renamed copy, mention the field twice:

```
{ Order.*, Customer.name, Customer.name as buyer }
```

`*` binds to the source schema at query time, so new source fields appear automatically. Named
fields bind stably.

The same rule applies to `*` in a `table` body, where it carries forward the previous version
of the table. See [evolution.md](evolution.md#redeclare-a-table).

## Join operator

`><` is the natural join. By default it joins along the edges that `:>` field declarations
create.

```
-- Uses the FK between Order and Customer
Order >< Customer

-- Names the edge, required when several FKs connect the two tables
Order >< Customer via customer
```

### Outer joins

Outer joins use guard semantics. Write the right side as an alternation. The system tries each
type left to right, and the first that produces a matching row wins. `Null`-derived types
always match, so they serve as the catch-all.

```
type MissingCustomer : Null

Order >< Customer | MissingCustomer                          -- left outer join
Order >< Customer | HistoricalCustomer | MissingCustomer     -- chained fallback
```

The result's `customer` field has type `Customer | MissingCustomer`. Pattern matching and
functor targeting address each variant. `MissingCustomer` carries no fields; the absence is the
value.

This is the guard rule that governs a nullable `:>` declaration, so the two read identically:

```
customer :> Customer | MissingCustomer      -- declaration
Order    >< Customer | MissingCustomer      -- query
```

A field declared with a fallback chain needs no `|` at the query site. The declaration already
carries it.

### Cross products

A `via` clause naming a `Null`-derived type says the join has no condition:

```
type Unrelated : Null

Order >< Promotion via Unrelated
```

`via` names the join edge, so a typed absence there says the edge is absent and records why in
the type name the author chose. This is the discipline the language already applies to absent
values, one position over.

`A >< B` where no `:>` edge connects the two is a compile-time error, and the diagnostic names
`via` and a `Null`-derived type as the fix. An accidental cross product across a distributed
database is expensive enough to be worth making unwritable.

Cross products compose with outer joins unchanged. `A >< B | NoB via Unrelated` still yields
`NoB` when `B` is empty, because `Null`-derived types always match.

### Joining against the reference direction

A join runs either way along a `:>` edge. Going backwards — from `Account` to the `Suspension`
rows that reference it — the result column has no `:>` field to name it, so `as` is
**mandatory** whenever the query names that source:

```
Account >< Suspension as suspension { name, suspension.opened_at }
```

Falling back to the bare table name would read as though the table itself were the value. A
reverse join whose source is never named needs no `as`, which is the common case inside an
`assert`.

### Filter before guard

**Put a filter on an outer-joined source inside the join term.**

```
-- Wrong: an account whose every suspension is lifted yields zero rows, not a
-- NoSuspension row. The filter deleted the rows the guard produced.
Account >< Suspension | NoSuspension as suspension where lifted is NotLifted

-- Right
Account >< (Suspension where lifted is NotLifted) | NoSuspension as suspension
```

An outer-level `where` naming a field of an outer-joined source is a compile-time error, and
the diagnostic names the parenthesized form as the fix. This is SQL's `ON`-versus-`WHERE` trap.
It is closed structurally because the same expression appears inside `assert`, where the
symptom is not missing rows but a constraint asserting the opposite of what it reads as. See
[constraints.md](constraints.md#absence).

## Grouping

`group` takes a table on the left and a projection on the right, and returns a table. The
projection declares the group keys. Every column the keys do not mention collapses into a
generated table-valued column named `rows`.

```
Order group { customer }
-- Result: { customer, rows }, where rows holds that customer's orders
```

Because the right side is an ordinary projection, group keys can be renamed and computed:

```
Order group { monthOf placed_at as month, customer as buyer }
```

Follow the `group` with a projection to shape the result and to apply aggregate functions to
`rows`:

```
Order group { customer } { customer, count rows as num_orders }
```

Group keys are one column each and `rows` holds the rest, so nothing is discarded and there is
exactly one output row per distinct key value. Chain `group` clauses to nest further.

A group key named `rows` is a compile-time error. Residual columns named `rows` cannot collide,
because they sit inside `rows`.

### Grouping by a whole table

`group { c.* }` groups by every column of `c`:

```
Order >< Customer as c group { c.* }
-- Result: each Customer, plus a rows column holding that customer's orders
```

The optimizer rewrites this to a group on `Customer`'s candidate key, and from there to
`DataId`. What licenses the rewrite is the key, not the identifier: grouping by every column
merges two distinct rows that happen to be field-identical, and grouping by a key does not.
They coincide only because `Customer` declares a candidate key that `c.*` contains. On a
`Keyless` or `LogData` source the reduction is unavailable and the rewrite is unsound.

`Order.customer` lands in `rows`, where it is the FK back to the group row. That is the link
the nested table needs, so it costs no extra bytes.

### Naming the nested table

Rename `rows` in the following projection. Give it traits with `:` and name its FK with `via`:

```
Sales group { product_sku, product_name }
  { product_sku, product_name, rows as Sale : UserData via product }
```

| Clause | Effect |
|---|---|
| `as Sale` | Names the nested table |
| `: UserData` | Overrides the trait it would otherwise inherit from its source |
| `via product` | Names the FK back to the group row |

Defaults: the nested table carries `Component`, and its FK is named after the group row's table
in `lower_snake_case`. `via` is needed only when that name collides or when you want a
different one.

**The trait decides whether the nested table is a column or a sibling.** A `Component` nested
table is a column, addressed as a path (`Agg.LinkedTable`), identified by `Ordinal`, and
destroyed with its parent — the same construct as an inline component sub-table
([tables.md](tables.md#component-sub-tables)). Elevating it out of `Component` gives its rows
their own `DataId` and shard placement, makes the parent link a real `:>` field costing real
bytes, stops `deprecate` from cascading, and makes the name a top-level table rather than a
path. `:describe` reports which.

Elevation is what an ETL split needs, because the extracted rows outlive the row they were
grouped under:

```
Product : Reference = DenormalizedSales
  group { product_sku, product_name }
        { product_sku, product_name, rows as Sale : UserData via product }
```

## Aggregate functions

An aggregate function takes a table and returns a scalar. Apply it like any other function:

```
count Orders                                      -- rows in the table
Orders group { customer } { customer, count rows as num_orders }
count $ Orders group { customer }                 -- customers that have orders
```

There is no special position and no fixed list. `count`, `sum`, `min`, `max`, and `avg` are
ordinary functions, and a user-defined one is admissible wherever they are. A retention chain
imposes the one extra requirement, that the function declare an associative merge with an
identity; see [aggregates.md](aggregates.md#aggregates-in-a-chain-must-merge).

**A path through a table-valued column distributes to a column.** `rows.bytes_sent` has type
`Table Amount`, which is what lets a prefix aggregate take it without parentheses:

```
{ status, count rows as requests, sum rows.bytes_sent as bytes, max rows.duration as slowest }
```

Signatures follow from that: `count :: Table a -> Int`, `sum :: Table Number -> Number`.

`group` is not required. `count Orders` reads the whole table, and the result is a scalar rather
than a one-row table.

## Ordering

```
-- Overrides the table default set by `order by` in the table body
Order
  where total > 100
  order by total desc
  { customer, total }
```

## Local bindings

```
let activeOrders = Order where status is Active
activeOrders >< Customer { customer.name, total }
```

`let` binds locally. A binding at top level is global and committed to the schema:

```
ActiveOrder            = Order where status is Active
ServiceAccount : LogData = User >< AccountKind { User.*, AccountKind.purpose } where kind is Service
```

Nothing precedes the name. `table` keeps a keyword because it declares storage and constraints;
a binding declares neither, and DataCode's top-level function definitions already take no
keyword. A binding whose right side contains a query clause is a query; one that does not is an
expression, which is the rule that already distinguishes the two inside parentheses.

A trait list after `:` overrides the traits a derived table would otherwise inherit. **By
default it inherits its sources' replication trait**, and sources that disagree are a
compile-time error — a derived table over `LogData` was never free to be `UserData`.

Because a binding has no body, its asserts and uniqueness constraints are written standalone
([constraints.md](constraints.md#standalone-form)).

## Document paths

A path into a `Doc indexed` field reads like any other path and resolves through the shredded
node tree:

```
app.log.Request where body.event_type == "charge.succeeded"
app.log.Request { received_at, body.data.object.amount as amount }
```

The result type is the sum of every type that path has held, plus `NotFound` for documents
lacking it — the same discipline as any other sum type, with no implicit coercion.

A path into a `Doc` that is not `indexed` is a compile-time error rather than a slow query. The
bytes are opaque by construction, and the error names `indexed` as the fix. See
[documents.md](documents.md).

## Restrictions on `matches`

``User where attempt `matches` password`` is rejected at compile time. Each stored digest
carries its own salt, so the expression is a full scan that hashes the attempt once per row.
`matches` applies to a single resolved row, after a `unique` field has narrowed the query:

```
let u = system.auth.User where username == name
in  attempt `matches` u.password
```

## Historical queries

Pin a query to a historical schema version. The token is a graph node hash prefix, a tag, or a
branch name — see [../transaction-graph.md](../transaction-graph.md).

```
Order at "schema-txn-abc123" where total > 100
Order at "v2.1.0" where total > 100
```

`at` also accepts a moment, which pins the query's **sample moment** rather than its schema
version:

```
Loan at "2026-03-01T00:00:00Z" { account, balance }
```

### Diffing two transaction points

`diff` evaluates a query at two graph nodes and returns what changed between them:

```
app.commerce.Order diff "v2.1.0" to "v2.2.0"
```

Both operands are version tokens — a graph node hash prefix, a tag, or a branch name — never
moments. A node is exact and reads no clock, which is what makes a diff reproducible.

The result is keyed by the query's own derived key
([below](#keys-are-computed-never-declared)) and carries three generated columns:

| Column | Holds |
|---|---|
| `before` | the query's row type; zero rows or one |
| `after` | the query's row type; zero rows or one |
| `change` | `Added`, `Removed`, or `Changed` |

`before` and `after` are table-valued columns — the shape `group` already produces as `rows` — so
projecting into them needs no new syntax.

**A degenerate key is rejected.** Where the derived key is all attributes, nothing identifies a
row across the two points: every change would read as a `Removed` plus an `Added`, and the result
would say nothing that two separate queries do not. The diagnostic names the source whose key
degenerated.

Comparing aggregates over time needs neither `diff` nor window functions. A rollup level is a
real table and queries compose, so a shifted self-join states it directly.

## Every query has a sample moment

A query is evaluated at one moment, and that moment is a value carried in the query rather than
a clock the evaluator reads. Without `at`, it defaults to the moment the request arrived.

This is what makes [behaviors](types.md#behaviors) well defined: `balance` has no value except
at a moment, and the query supplies the moment instead of the field fetching it. It is the
discipline the missing `Effect`-to-`Tx` lift already enforces on functors
([functions.md](functions.md)) — a commit that reads the clock is not replayable, and a derived
table that reads the clock is not recomputable.

> **The coordinating server resolves the sample moment once, and every shard evaluates against
> the value it was given.**

This matters beyond behaviors. `DataId` timestamps come from per-server wall clocks with
regression clamping ([../transaction-graph.md](../transaction-graph.md#clock-regression)), so
shards that each resolved "now" independently would answer one query as of slightly different
times, and a cross-shard aggregate would correspond to no actual state of the database.

Stored rows make the moment immaterial, which is why this has not needed stating until now.
Over a behavior it is part of what the result means.

## Field types

A derived table does not declare field types. It inherits or computes them.

- A projected field path keeps the source field's name and type, including its validations.
  `User.email` is still a `system.auth.User.email`.
- A projected expression mints a computed type named by the field's path.
  `normalize (User.name) as name` in `system.auth.ServiceAccount` defines the type
  `system.auth.ServiceAccount.name`.

The naming rule is not new. A field's `where` is already addressed by the field's path, and that
path is already the name of the field's computed type
([README.md](README.md#addressing-validations)). A projection is the same mechanism reaching a
new position.

**Types are shared structurally and named by their first definer.** Two derived tables
projecting `normalize (User.name)` get one type, not two incompatible ones, because functors are
transparent and the same function over the same source type is the same computed type. First
definer decides only the *name*. Expect one consequence: the name outlives its definer's
`deprecate`, because nothing is destroyed and the type is still in use elsewhere.

**A function over a key column degenerates the key**, because injectivity is not knowable in
general. That costs incremental refresh, pins the sources against `deprecate`, and makes the
result read-only. Apply functions to non-key columns, or accept a read-only table. `:describe`
reports which happened.

## Keys are computed, never declared

A `table` declares a candidate key ([tables.md](tables.md#candidate-keys-are-mandatory)). A
binding must not — its key follows from its sources and the operators applied to them, and the
system derives it.

**Every derived table has a key.** A table is a set of tuples, so at worst the whole tuple is
one. The question is never whether a key exists, but whether the derived key is **meaningful**
(a proper subset identifying an entity) or **degenerate** (all attributes, identifying only this
combination of values).

### How each operator propagates

| Operator | Key of the result |
|---|---|
| `where` | Unchanged. A subset of rows keyed by K is still keyed by K. |
| `{ ... }` | The source key if every one of its columns survives, otherwise **degenerate** |
| `group { ... }` | The group keys. Exactly one row per distinct value, by construction. |
| `><` along a `:>` edge | K of the referencing side alone. The join is **lossless** — each row matches at most one counterpart. |
| `><` on non-key fields | K₁ ∪ K₂ |
| `><` outer | As above, but **degenerate** if a key column comes from the outer side |
| `><` via a `Null` type | K₁ ∪ K₂ |
| `\|` union | The source key **plus a discriminator**, which may not exist |

Three of these need a note.

**A superkey of a declared candidate key reduces to it.** `group { c.* }` derives every column
of `c` as its key, which contains `c`'s declared key, so the result is keyed by that instead —
meaningful rather than degenerate. This is the rule that also licenses the optimizer's rewrite
above, and it is unavailable on a source with no declared key.

**Foreign keys substitute.** A key containing a `:>` field resolves to the referent's key, so
`Order` keyed `{customer, order_num}` joined to `Customer` yields `{Customer.email, order_num}`.
The key survives even when the FK column is projected away. The same substitution tells the
optimizer the join is lossless; without the reference direction you would derive only the
superkey K₁ ∪ K₂, which is correct but not minimal.

**Grouping is exact here in a way it is not in SQL.** `group` nests rather than aggregating away,
so nothing is discarded and there is precisely one output row per distinct group value. The
group keys are a key by construction rather than by argument.

### Where propagation breaks

**Union** does not preserve a shared key, because two rows carrying the same key from different
sources collide. The rollup union in [aggregates.md](aggregates.md#the-union) is this case:
every level is keyed `{bucket_start, ...}`, and an hourly bucket starting at midnight collides
with a daily bucket starting at midnight. `grain` is the discriminator that fixes it, and it was
introduced for the purpose. A union whose sources offer no discriminator has a degenerate key.

**Outer joins** degrade for the reason declared keys may not contain a `Null`-derived variant
([tables.md](tables.md#ineligible-key-fields)): `MissingCustomer` is an ordinary value, so every
absent row carries the same one and they collide. The rule falls out twice from one fact, which
is a good sign it is the right rule.

**Behaviors** cannot participate in a key at all, so a derived table distinguished only by
projected [behaviors](types.md#behaviors) has no stable key.

### Degeneracy warns, it does not fail

A degenerate key is well-defined and queryable, and reporting tables legitimately have no entity
identity — a revenue-by-month summary is not *about* anything you can point at. So it is never
rejected.

It is never silent either. Accepting an all-attributes key without saying so would let a derived
table claim an identity it does not have, and merge reconciliation would then trust it.
`:describe` reports the derived key and marks it:

```
datacode[app.commerce]> :describe app.commerce.OrderSummary
app.commerce.OrderSummary
  key:      (all attributes) -- degenerate: `customer` and `order_num` are projected away
  refresh:  full only
  writable: no -- degenerate key
```

This is the posture [../integrity.md](../integrity.md) takes elsewhere: compute what is known,
report it, leave the decision.

### What the key decides

Three things depend on it:

- **Incremental refresh.** A meaningful key says which row a recomputed one replaces. See
  [../storage.md](../storage.md#materialization).
- **Whether the sources can be retired.** An incrementally-refreshable table has an existence
  independent of its sources' full extent, which makes it a candidate to replace them. See
  [evolution.md](evolution.md#a-degenerate-dependent-blocks-deprecation).
- **Whether it can be written through.** See [Writing through a derived table](#writing-through-a-derived-table).

## Writing through a derived table

An insert or update decomposes into one mutation per base table, ordered by FK direction —
referenced side first, so the row exists before anything references it.

```
system.auth.ServiceAccount { username = "billing-sync", purpose = "invoice ingestion" }
-- inserts a system.auth.User row, then an AccountKind row with kind = Service
```

Note what supplied `kind`. **A `where` filter is a check constraint on write, and its constant
equalities supply values on insert.** The row you write must satisfy the filter, and where the
filter pins a field to a constant, that constant is written. This is SQL's `WITH CHECK OPTION`
doing one extra job: it lets a write create the linking row without the call site knowing the
linking table exists.

Write-through is admissible exactly when:

1. The derived key is meaningful, not degenerate. It is what says which base row a row is.
2. Every join runs along a `:>` edge, so key propagation makes it lossless and each row
   corresponds to at most one row per base table.
3. Every required field of each base table — one with no default — is either projected or fixed
   by the `where`.

Fail any of the three and the table is read-only, with `:describe` reporting which.

**`delete` removes the row the key identifies, and never cascades.** For a `:>` join that is the
*referencing* side: deleting from `ServiceAccount` appends a tombstone to the `AccountKind` row,
and the `User` survives, now matching no service-account row. This falls out of key propagation
rather than being stipulated, but "delete the service account" reads as though the user should
go too, and it does not.

## Mutation

Row construction and row update both use `=` for their fields, as in Haskell record syntax.

```
-- Insert
app.commerce.Order { customer = customerId, total = 99.99, status = Pending }

-- Functional update; returns a new version, re-evaluates all functors
Order where id == "uuid-..." { status = Shipped }

-- Delete; appends a tombstone version, history stays readable
delete Order where id == "uuid-..."
```

A brace block in query position is a **projection** when its items are bare paths, and a **row
update** when they are `field = value` bindings:

```
Order where total > 100 { customer, total }        -- projection
Order where id == "uuid-..." { status = Shipped }  -- update
```

### Delete appends a version

`delete` follows the rule every other mutation follows: it appends a tombstone version rather
than removing anything. The row is absent from any query whose sample moment is at or after the
delete, and present in any query pinned earlier with `at`. The `DataId` is never reused,
dependent history is untouched, and writing a new version brings the row back.

**There is no second, harder delete.** A `delete!` spelling was reserved and has been removed.
It did nothing `delete` did not already do — both amounted to "removes it from the current
state, keeps it in the graph" — and the operations that would justify the sigil are `erase`,
which closes a row's history, and `scrub`, which destroys bytes already written. Both are
administrative acts reachable only from the CLI and the admin interface, never from the query
language, and neither is spelled as a variant of `delete`. See
[../integrity.md](../integrity.md#erasure-restricts-scrub-destroys).
