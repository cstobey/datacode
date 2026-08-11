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
let u = system.auth.users where username == name
in  attempt `matches` u.password
```

## Historical Queries

Pin a query to a historical schema version. The token may be a graph node hash prefix, a
tag, or a branch name — see [../transaction-graph.md](../transaction-graph.md).

```
Order at "schema-txn-abc123" where total > 100
Order at "v2.1.0" where total > 100
```

## Views

Views are defined identically to tables — they are table definitions whose data is computed
from the transaction graph rather than stored directly. The distinction is a storage hint,
not a schema distinction.

```
view app.commerce.active_orders {
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

## The `*` Selector and Field Propagation

Views and connector overlays can use `*` to include all fields from a source table:

```
-- Wildcard: tracks source schema dynamically
view app.commerce.order_summary {
  * from connectors.mariadb.production.orders,
  status : OrderStatus    -- explicit override: coerces Text -> ADT
}

-- Explicit field list: stable, change-resistant
view app.commerce.order_detail {
  id     : DataId from connectors.mariadb.production.orders,
  total  : Amount from connectors.mariadb.production.orders,
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

-- Soft delete (recorded in transaction log; data stays in graph)
delete Order where id == "uuid-..."

-- Hard delete (removes from active state; record remains in transaction graph)
delete! Order where id == "uuid-..."
```

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
