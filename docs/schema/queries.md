# Queries, Views, and Mutation

## Filter, Projection, Alias

```
Order >< Customer
  where total > 100
  { customer.name as name, total as order_total }
```

- `where` — row filter
- `{ field, ... }` — projection (bare braces, no `select` keyword)
- `as` — alias

Field references: `TableName.field_name` or `alias.field_name`. Table aliases are
encouraged when the full namespace path is in the name.

`where` here is the row-level form of the same operator used at the type level in
declarations (see [types.md](types.md)) — in both cases it restricts to the subset
satisfying a predicate.

## Join Operator

`><` (bowtie) is the natural join operator. It joins on matching FK columns by default —
that is, along the edges created by `:>` field declarations.

```
-- Natural join: uses the FK between Order and Customer
Order >< Customer

-- Explicit FK path: required when multiple FKs exist between two tables
Order >< Customer via customer
```

## Outer Joins

Outer joins use guard semantics: the right side of `><` is a sum type written with `|`. The
system tries each type left-to-right; the first that produces a matching row wins.
`Null`-derived types always match and serve as the catch-all.

```
type MissingCustomer : Null

-- Left outer join equivalent
Order >< Customer | MissingCustomer

-- Chained fallback: try Customer, then HistoricalCustomer, then catch-all
Order >< Customer | HistoricalCustomer | MissingCustomer
```

The result row's customer field has type `Customer | MissingCustomer` — a sum type. Pattern
matching and functor targeting can address each variant. `MissingCustomer` carries no
fields; the absence IS the value.

This is the same left-to-right guard rule that governs a nullable `:>` field declaration,
so the two read identically:

```
customer :> Customer | MissingCustomer      -- declaration
Order    >< Customer | MissingCustomer      -- query
```

A field declared with a fallback chain is joined with no `|` needed at the query site — the
declaration already carries it.

## Grouping

`group` puts the grouped field on the left; all other fields collapse into a nested table
field. Aggregate functions operate on that nested table.

```
Order
  group customer
  { customer, orders.total sum as total_spend }
-- Result: { customer: DataId, total_spend: Amount }
-- The intermediate orders nested table is computed then projected away
```

## Ordering

```
-- Per-query ordering (overrides the table default from `order by` in the table body)
Order
  where total > 100
  order by total desc
  { customer, total }
```

## Local Bindings

```
let activeOrders = Order where status is Active
activeOrders >< Customer { customer.name, total }
```

`let` is local only. Top-level bindings are global and committed to the schema — see
[functions.md](functions.md).

## Document Paths

A path into a `Doc indexed` field reads like any other path and resolves through the shredded
node tree:

```
app.log.Request where body.event_type == "charge.succeeded"
app.log.Request { received_at, body.data.object.amount as amount }
```

The result type is the sum of every type that path has ever held, plus `NotFound` for
documents lacking it — the same discipline as any other sum type, with no implicit coercion.

A path into a `Doc` that is *not* `indexed` is a compile-time error rather than a slow query:
the bytes are opaque by construction, and the error names `indexed` as the fix. See
[documents.md](documents.md).

## Restrictions on `matches`

``User where attempt `matches` password`` is rejected at compile time. Each stored digest
carries its own salt, so the expression is a full scan that hashes the attempt once per row.
`matches` applies to a single resolved row, after a `unique` field has narrowed the query:

```
let u = system.auth.User where username == name
in  attempt `matches` u.password
```

## Historical Queries

Pin a query to a historical schema version. The token may be a graph node hash prefix, a
tag, or a branch name — see [../transaction-graph.md](../transaction-graph.md).

```
Order at "schema-txn-abc123" where total > 100
Order at "v2.1.0" where total > 100
```

`at` also accepts a moment, which pins the query's **sample moment** rather than its schema
version:

```
Loan at "2026-03-01T00:00:00Z" { account, balance }
```

## Every Query Has a Sample Moment

A query is evaluated at one moment, and that moment is a value carried in the query — not a
clock the evaluator reads. Where no `at` is given it defaults to the moment the request
arrived.

This is what makes [behaviors](types.md#behaviors) well defined: `balance` has no value
except at a moment, and the moment is supplied by the query rather than fetched by the field.
It is the same discipline the `a -> IO b` rejection already enforces on functors
([functions.md](functions.md)) — nothing inside the evaluation may read the clock, because a
commit that reads the clock is not replayable and a view that reads the clock is not
recomputable.

> **The coordinating server resolves the sample moment once, and every shard evaluates
> against the value it was given.**

This matters beyond behaviors. `DataId` timestamps come from per-server wall clocks with
regression clamping ([../transaction-graph.md](../transaction-graph.md#clock-regression)), so
shards that each resolved "now" independently would answer one query as of slightly different
times, and a cross-shard aggregate would not correspond to any actual state of the database.

A materialized view is pegged to a `(commit node, sample moment)` pair for the same reason.
Over stored fields the moment is immaterial and only the commit node matters, which is why it
has not needed stating until now; over a behavior the view is a snapshot and the moment is
part of what it means.

## Views

Views are defined identically to tables — they are table definitions whose data is computed
from the transaction graph rather than stored directly. The distinction is a storage hint,
not a schema distinction.

```
view app.commerce.ActiveOrder {
  customer :> Customer,
  total    : Amount,
  where status is Active
}
```

A view body uses the same field declaration syntax as a table body, so `:>`, `where`, and
comma separation apply identically.

Note the two roles of `where` in one body: attached to a field declaration it validates that
field; standing alone as a body item it filters rows. Position disambiguates — a `where` that
begins its own comma-separated item is a row filter.

## View Keys Are Computed, Never Declared

A table must declare a candidate key ([tables.md](tables.md#candidate-keys-are-mandatory)). A
view must not — its key follows from its sources and the operators applied to them, and the
system derives it.

**Every view has a key.** A table is a set of tuples, so at worst the whole tuple is one. The
question is never whether a key exists; it is whether the derived key is **meaningful** — a
proper subset that identifies an entity — or **degenerate** — all attributes, identifying only
"this exact combination of values".

### How Each Operator Propagates

| Operator | Key of the result |
|---|---|
| `where` — filter | Unchanged. A subset of rows keyed by K is still keyed by K. |
| `{ … }` — projection | The source key, if every one of its columns survives; otherwise **degenerate** |
| `group f` | The group columns. Exactly one row per distinct value, by construction. |
| Aggregation with no `group` | The empty set — the result has at most one row |
| `><` where the join field is `:>` | `K` of the referencing side alone. The join is **lossless**: each row matches at most one counterpart, so cardinality is preserved. |
| `><` on non-key fields | `K₁ ∪ K₂` |
| `><` outer | As above, but **degenerate** if a key column comes from the outer side |
| `\|` — union | The source key **plus a discriminator**, which may not exist |

Two of these are worth their own note.

**Foreign keys substitute.** A key containing a `:>` field resolves to the referent's key, so
`Order` keyed `{customer, order_num}` joined to `Customer` yields `{Customer.email,
order_num}`. The key therefore survives even when the FK column itself is projected away. The
same substitution is what tells the optimizer the join is lossless — without the reference
direction you would derive only the superkey `K₁ ∪ K₂`, which is correct but not minimal.

**Grouping is exact here in a way it is not in SQL.** Because `group` nests rather than
aggregating away, nothing is discarded and there is precisely one output row per distinct
group value. The group columns are a key by construction rather than by argument.

### Where Propagation Genuinely Breaks

**Union** does not preserve a shared key — two rows carrying the same key from different
sources collide. The rollup union in [aggregates.md](aggregates.md#the-union-view) is exactly
this case: every level is keyed `{bucket_start, …}`, and an hourly bucket starting at midnight
collides with a daily bucket starting at midnight. `grain` is the discriminator that fixes it,
and it had to be introduced for the purpose. A union whose sources offer no discriminator has
a degenerate key.

**Outer joins** degrade for the same reason declared keys may not contain a `Null`-derived
variant ([tables.md](tables.md#ineligible-key-fields)): `MissingCustomer` is an ordinary
value, so every absent row carries the same one and they collide. The rule falls out twice
from one fact, which is a good sign it is the right rule.

**Behaviors** cannot participate in a key at all, so a view distinguished only by projected
[behaviors](types.md#behaviors) has no stable key.

### Degeneracy Is a Warning, Not an Error

A view with a degenerate key is well-defined and queryable, and reporting views legitimately
have no entity identity — a revenue-by-month summary is not *about* anything you can point at.
So it is never rejected.

But it is never silent either. Accepting an all-attributes key without saying so would let a
view claim an identity it does not have, and merge reconciliation would then trust it.
`:describe` reports the derived key, and marks it when it is degenerate:

```
datacode[app.commerce]> :describe app.commerce.OrderSummary
view app.commerce.OrderSummary
  key: (all attributes) -- degenerate: `customer` and `order_num` are projected away
  refresh: full only
```

This is the posture [../integrity.md](../integrity.md) already takes elsewhere: the system
computes what it knows, reports it, and leaves the decision.

### What the Key Decides

The derived key is not bookkeeping. Two things depend on it:

**Incremental refresh.** A materialized view with a meaningful key can be refreshed by
upserting changed rows, because the key says which row a recomputed one replaces — the same
idempotence argument that makes rollup catch-up safe
([aggregates.md](aggregates.md#what-gets-generated)). A degenerate key admits only wholesale
recomputation. See [../storage.md](../storage.md#materialized-views).

**Whether the source can be retired.** An incrementally-refreshable view has an existence
independent of its sources' full extent, which makes it a **candidate to replace them** — the
generalization of what a retention chain does when an aggregate supersedes the raw table it
was computed from.

A degenerate view has no such independence: it can only ever be rebuilt by rescanning its
sources. **`deprecate` on a table with a degraded dependent view is therefore rejected**, and
the diagnostic says which view and why. Alter the view to carry its sources' key columns, or
deprecate the view first.

```
datacode[app.commerce]> deprecate app.commerce.Order
error: app.commerce.OrderSummary depends on app.commerce.Order and has a degenerate key,
       so it cannot be maintained without rescanning it.
       Project `customer` and `order_num` into the view, or deprecate the view first.
```

That makes the warning load-bearing rather than advisory: a degenerate key is not merely
untidy, it pins the schema.

## The `*` Selector and Field Propagation

Views and connector overlays can use `*` to include all fields from a source table:

```
-- Wildcard: tracks source schema dynamically
view app.commerce.OrderSummary {
  * from connectors.mariadb.production.Order,
  status : OrderStatus    -- explicit override: coerces Text -> ADT
}

-- Explicit field list: stable, change-resistant
view app.commerce.OrderDetail {
  id     : DataId from connectors.mariadb.production.Order,
  total  : Amount from connectors.mariadb.production.Order,
  status : OrderStatus
}
```

`*` binds to the source's schema at query time — new fields in the source appear
automatically. Named fields bind stably — new source fields don't propagate. Mixed views
can use `*` for the bulk and override specific fields by name.

`from` is a trailing clause and precedes `unique`, `=`, and `where`.

## Mutation

Row construction and row update both use `=` for their fields, as in Haskell record syntax.

```
-- Insert
app.commerce.Order { customer = customerId, total = 99.99, status = Pending }

-- Functional update (returns new version; all functors re-evaluated)
Order where id == "uuid-..." { status = Shipped }

-- Delete (appends a tombstone version; the row's history stays readable)
delete Order where id == "uuid-..."
```

### Delete Appends a Version

`delete` is an ordinary mutation and follows the same rule as every other one: it appends a
tombstone version of the row rather than removing anything. The row is absent from any query
whose sample moment is at or after the delete, and present in any query pinned earlier with
`at`. The `DataId` is never reused, dependent history is untouched, and writing a new version
brings the row back.

**There is no second, harder delete.** A `delete!` spelling was reserved and has been removed.
As specified it did nothing `delete` did not already do — both descriptions amounted to
"removes it from the current state, keeps it in the graph" — and the only operation that would
have justified the sigil is destroying bytes already written to the append-only log, which is
unsolved. Scrubbing PII and quarantining a `UserData` shard are
[OQ-036](../open-questions.md#oq-036-erasure-pii-scrubbing-and-shard-quarantine);
whatever answers it will not be spelled as a variant of `delete`, because it is an
administrative act on a shard and not a row mutation.

A brace block in query position is a **projection** when its items are bare paths and a
**row update** when they are `field = value` bindings:

```
Order where total > 100 { customer, total }        -- projection
Order where id == "uuid-..." { status = Shipped }  -- update
```

## Materialized Views

Materialized views are pegged to specific commit nodes in the transaction graph. They never
block ongoing transactions (they reference a past, stable state), are updated in the
background or lazily on access, and are maintained per server. Large analytical
computations can be distributed across neighbouring servers — see
[../distribution.md](../distribution.md).

Materialization is a storage hint applied to a view, not a separate kind of schema object.
