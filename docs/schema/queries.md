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

### Clause order

**Clauses apply in written order.** Each one takes the relation the clause before it produced.
Naming a column an earlier clause dropped is a compile-time error, so a filter goes *before*
the projection that removes its columns:

```
Order >< Customer as c where c.region == "EU" { total }   -- filters, then projects
Order >< Customer as c { total } where c.region == "EU"   -- rejected: `c.region` is gone
```

Left to right is the rule the rest of the file already assumes. It is what makes `group`
followed by a projection mean "shape the group's output", and it is why a filter on an
outer-joined source has to sit inside the join term rather than after it — see
[Filter before guard](#filter-before-guard).

### Membership

Membership is `` `elem` ``, an ordinary backtick infix over a table:

```
Order where status `elem` [Pending, Shipped]
Payment where { customer = payer, order_num = invoice_num } `elem` app.commerce.OpenOrder
```

`[ … ]` is a table literal, not a list — DataCode has no list type, and a table is what the
right operand of a membership test already is. The multi-field form compares a row rather than a
tuple: each name is a column of the right operand and each value an expression over the row
being filtered, so it binds by name and reuses the element shape an insert already uses.

There is no `in` operator. `in` belongs to `let … in`, and the reasoning is recorded in
[railroad.md](railroad.md#functions-and-expressions).

## The `*` selector

`*` expands to every field of its source that no other item in the projection mentions.
Qualify it (`User.*`) to pick one side of a join.

```
-- Bulk copy
OrderMirror = connectors.mariadb.production.Order { * }

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

A table-valued column is excluded from `*` **unconditionally**, whether it comes from `group`,
from a `:>` field whose target carries `Component`, or from a reverse join. Nesting is
authored, never inherited — see [Nesting a table-valued column](#nesting-a-table-valued-column).

**`*` resolves when the projection it sits in is committed.**

| Position | Resolves against |
|---|---|
| `table` body | the previous version of the table, at schema commit |
| A committed binding | its sources' columns at schema commit |
| An ad-hoc query | its sources' columns at query time |

A committed binding's field set is a schema-graph fact, so it cannot be late-bound: `diff`
between two graph points would otherwise have no row type to compare, and a materialized view
would change shape with no transaction behind it. Named fields bind stably in every position.

A field added to a source after the binding commits therefore does not appear in the binding
until it is redeclared. Whether a *connector*-sourced column should propagate into the bindings
over it automatically, and under what policy, is OQ-025 and is still open.

The `table`-body case carries forward the previous version of the table. See
[evolution.md](evolution.md#redeclare-a-table).

## Join operator

`><` is the **reference join**: it joins two sources along a declared `:>` edge, in either
direction. There is no join on shared column names. SQL's natural join would use whatever
attributes the two sides happen to name alike, so adding a same-named column to two tables
would silently change an existing join; here the edge is declared and adding a column changes
nothing.

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
-- Rejected at compile time. Were it admitted, an account whose every suspension is
-- lifted would yield zero rows rather than a NoSuspension row: the filter deletes the
-- rows the guard produced.
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
DenormalizedSale group { product_sku, product_name }
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
app.sales.Product : Configuration = DenormalizedSale
  group { product_sku, product_name }
        { product_sku, product_name, rows as Sale : UserData via product }
```

**An elevated nested table derives its key and its placement like any other derived table.**
Its key is the group keys — here `{ product_sku, product_name }`, which must therefore identify
a product — and it roots where that key's head FK roots. A group whose keys do not identify an
entity elevates to a table with a degenerate key, which is read-only and blocks incremental
refresh; `:describe` reports it.

The catalogue is `Configuration` rather than `Reference` deliberately. Inserting a `Reference`
row is a schema transaction ([traits.md](traits.md#reference-tables-are-code)), so an
incremental refresh of a `Reference`-typed binding would be a stream of schema commits, and an
ETL catalogue also runs past the 65 535-variant ceiling that makes a table a code table.
`Configuration` keeps the rows everywhere they are needed and the writes ordinary.

## Nesting a table-valued column

**A projection item whose head path is table-valued may carry its own projection, which nests
it.** That one rule covers every nested column in the language, so there is no `nest` clause and
none is wanted.

```
Order >< OrderLine as line
  { order_num, total, line { product, qty } }
```

Three heads are table-valued:

| Head | Comes from |
|---|---|
| `rows` | the column a `group` generates |
| A `:>` field whose target carries `Component` | the parent's own rows in that sub-table, in `ordinal` order |
| A source joined against the reference direction, named by its mandatory `as` | many rows per row of the containing relation |

Nesting a reverse-joined source groups the containing rows by their own key, so the result has
one row per containing row — the shape `group` produces, without writing the chain out. A
forward `:>` to a non-`Component` table is single-valued and is reached by path
(`customer.name`); there is nothing to nest.

Four rules travel with it:

- **A table-valued column is excluded from `*` unconditionally.** Nesting is a claim of
  authorship: a nested column appears because someone wrote the sub-projection.
- **Naming a field removes it from `*`**, whether or not the item carries a sub-projection —
  the same rule as [The `*` selector](#the--selector).
- **Ordering inside a nested column is declared in its source term** — `>< (OrderLine order by
  qty desc) as line`, or the child's own declared `order by` — never by an `order by` after the
  projection, which orders the outer rows.
- **`ordinal` is available on a stored `Component` table and not on a computed nested column.**
  Nothing was inserted in any order in a `group` result or a sub-projection, so there is no
  ordinal to report.

To rename a nested column, or to set its trait or its back-FK, use the same `as` / `:` / `via`
clauses as [Naming the nested table](#naming-the-nested-table).

Nesting is also what a JSON-shaped API contract is made of: a nested binding serializes as
nested JSON on the way out and accepts the same shape on the way in, because a derived table
with a meaningful key is writable — see
[Writing through a derived table](#writing-through-a-derived-table).

## Aggregate functions

An aggregate function takes a table and returns a scalar. Apply it like any other function:

```
count Order                                       -- rows in the table
Order group { customer } { customer, count rows as num_orders }
count $ Order group { customer }                  -- customers that have orders
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

`group` is not required. `count Order` reads the whole table, and the result is a scalar rather
than a one-row table.

### Row numbers

`numbered` is an ordinary function of the same family. It returns its argument plus a generated
`n` column, numbered from 1 in the argument's order:

```
numbered (Order order by placed_at desc) { n, order_num, total }
```

**The ordering is a parameter, not an enclosing clause.** A nullary `row_number` would be a term
whose value depends on the surrounding query's ordering *and* extent — ambient state, the same
reading rejected for `Moment` ([Every query has a sample moment](#every-query-has-a-sample-moment)).
Passing the ordered table in makes the dependency visible, and it is what lets numbering reach
inside a nested column: apply `numbered` to that column.

`n` is not key-eligible. It changes when an unrelated row is inserted, so a materialized view
keyed on position would renumber its whole extent on one insert.

`numbered` gives `lag` and `lead` by self-join on `n - 1`, and running totals. It does not give
`rank` or `dense_rank`, which differ from it on ties, and it has no frame clause. There are no
window functions.

## Ordering

```
-- Overrides the table default set by `order by` in the table body
Order
  where total > 100
  order by total desc
  { customer, total }
```

## Limit and pagination

`limit` truncates the result after ordering.

```
Order where total > 100 order by placed_at desc limit 100
```

**`limit` requires a total order.** It comes from an explicit `order by`, else the source's
declared one, else the candidate key ascending. **Any stated order is extended by the candidate
key as a final tiebreak**, because a stated order is rarely total: `order by placed_at desc`
puts fifty orders sharing a timestamp in an arbitrary sequence, so a page boundary can fall
mid-tie and a resume predicate then either skips the rest of the tie or repeats it. `limit` on a
degenerate-keyed source that declares no ordering is a compile-time error — there is nothing to
break the tie with.

### Pagination is a cursor

**There is no offset**, and none is added. Given a total order, "resume after the last row I
saw" is an ordinary `where` over the ordering tuple, so cursor pagination costs no syntax at
all, and offset would cost a production:

```
-- Page 1
Order at "05KG3N0000ZQ8V4T1H7C"
  order by placed_at desc
  limit 100

-- Page 2, resuming after the last row of page 1
Order at "05KG3N0000ZQ8V4T1H7C"
  where placed_at < "2026-08-27T14:02:11Z"
     || (placed_at == "2026-08-27T14:02:11Z"
         && (customer > "05KG3N0000ZQ8V4T1H7C"
             || (customer == "05KG3N0000ZQ8V4T1H7C" && order_num > 4471)))
  order by placed_at desc
  limit 100
```

Three properties of that predicate are the whole argument for the cursor:

- **It carries the `at` peg.** Without it the next page runs against a relation that moved,
  which is the failure offset is famous for. `at` defaults to request arrival
  ([Every query has a sample moment](#every-query-has-a-sample-moment)), so a continuation with
  no peg is unstable — the cursor threads the peg and the position in one token, where an offset
  requires the caller to remember the peg separately.
- **It uses the effective ordering tuple, tiebreak included.** Here that is
  `(placed_at desc, customer asc, order_num asc)` — the stated order extended by `Order`'s
  candidate key. Leaving the key out makes the predicate wrong at a tie boundary.
- **Mixed directions expand.** `placed_at desc` with an ascending tiebreak cannot be one
  comparison, so it is written out as above. Uglier and correct.

Offset was rejected on its cost as well as its instability: it is O(offset) and hides it. Every
shard has to produce and discard its prefix before the coordinator can merge, and nothing in
the syntax says so.

### No exact total

A paged query reports `100 of 100+`. The `+` is produced by fetching `limit + 1` rows and
discarding the extra — exact for the only bit a caller can act on, one row of cost, and no
query-language feature. An exact footer would mean running the whole query, which is the cost
`limit` exists to avoid.

Where a real total is wanted it is a second query, and the language already has it:
`count (Order where total > 100)` is an ordinary function application returning a scalar.

The `100 of 100+` footer and the printed continuation are a CLI display convention, not
grammar, and they apply to the `table` and `json` formats only — a pipe cannot carry a footer,
and a silently truncated export is worse than a slow one. See
[../cli.md](../cli.md#output-formats).

## Local bindings

```
let ActiveOrder = Order where status is Active
ActiveOrder >< Customer { customer.name, total }
```

`let` binds locally, for the rest of the script or REPL session, and follows the same naming
rule as a top-level binding. A schema file holds declarations, so `let` does not appear in one.
A binding at top level is global, namespaced, and committed to the schema:

```
app.commerce.ActiveOrder = Order where status is Active

system.auth.ServiceAccount = User >< AccountKind as ak
  where ak.kind is Service
  { User.*, ak.purpose }
```

Nothing precedes the name. `table` keeps a keyword because it declares storage and constraints;
a binding declares neither, and DataCode's top-level function definitions already take no
keyword. A binding whose right side contains a query clause is a query; one that does not is an
expression, which is the rule that already distinguishes the two inside parentheses.

`AccountKind` references `User`, so the join runs against the reference direction and `as ak` is
mandatory — the query names that source twice. The filter precedes the projection because
`ak.kind` does not survive it.

A trait list after `:` overrides the traits a derived table would otherwise inherit. **By
default it inherits the replication trait its sources share.** Sources that disagree are a
compile-time error — a derived table over `LogData` was never free to be `UserData`.
`Reference` and `Configuration` sources are ignored in that comparison, because they are present
on every server and say nothing about placement; this is the carve-out foreign keys already get
in key rooting ([tables.md](tables.md#keys-must-be-rooted)). Without it the commonest join in
the language — a `UserData` fact table against a code table — would need an explicit override,
putting the marked spelling on the unmarked case.

The ETL split [above](#naming-the-nested-table) is what an override is for: its source is
`UserData` and the extracted catalogue has to be present everywhere, so it declares
`Configuration`.

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

## A query that pins a key denotes a row

**A query whose `where` pins every column of one declared candidate key denotes a row, not a
table, and a path may be taken through it.** The check is static: it reads the key declaration,
not the result.

```
let u = system.auth.User where username == name
in  attempt `matches` u.password
```

A zero-row result is `NotFound`, so a path through such a query has type `t | NotFound` and
every consumer handles the absent case the way it handles any other absence. Nothing here is
special-cased for one row: this is the coercion `matches` needs, the one a template hole uses
when it interpolates `{{ self.order_num }}`, and the one an assert relies on when it reaches
through `self`.

Any other query is a table, and taking a path through it is a compile-time error naming an
aggregate or a projection as the fix.

### Restrictions on `matches`

``User where attempt `matches` password`` is rejected at compile time. Each stored digest
carries its own salt, so the expression is a full scan that hashes the attempt once per row.
`matches` applies to a single resolved row, after a `unique` field has narrowed the query — the
form above.

## Historical queries

**A query resolves against a pair**: a **commit node**, which decides which row versions exist
and which schema is in force, and a **sample moment**, which decides what a behavior evaluates
to. `at` sets one of them, and the other follows.

| `at` | Commit node | Sample moment |
|---|---|---|
| Omitted | HEAD of the current branch | request arrival |
| A version token | that node | that node's commit timestamp |
| A moment | the latest merged node at or before it | that moment |

A version token is a graph node hash prefix, a tag, or a branch name — see
[../transaction-graph.md](../transaction-graph.md). The two forms are told apart at resolution,
not by the grammar.

```
Order at "05KG3N0000ZQ8V4T1H7C" where total > 100   -- node: schema and rows as of that commit
Order at "v2.1.0" where total > 100                 -- tag: the same, by name
Loan  at "2026-03-01T00:00:00Z" { account, balance } -- moment: what the balance was then
```

Pairing them rather than leaving one unset is what makes each example mean one thing. Pinning a
node without a moment would leave a `Behavior` reading the wall clock inside a query that is
otherwise reproducible; pinning a moment without a node would evaluate an old moment against
today's schema.

**At most one `at` per query.** Two would be two answers to one question.

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

**The earlier node supplies the schema.** The two points may sit either side of an evolution, so
the query's row type and derived key are resolved once, at the earlier node, and the later
extent is read through it. A key column that is absent or degenerate at either node is a
compile-time error naming both nodes — the same failure the degenerate-key rejection exists to
catch, arriving through evolution rather than through projection.

**A `Behavior` in the projection is rejected**, for the same reason a `Behavior` cannot
participate in a key: it has no value except at a moment, `at` is rejected alongside `diff`, and
a diff that sampled the wall clock would not be reproducible — which is the property the
version-tokens-only rule is there to protect.

A re-keyed row reads as a `Removed` plus an `Added`, never a `Changed`, and that is exact rather
than a limitation: the row genuinely became a different row in a different shard
([tables.md](tables.md#changing-a-placement-key)). `diff` does not learn about the supersession
record; `show transaction` is where that is read.

### Comparing periods

Comparing aggregates over time needs neither `diff` nor window functions. A rollup level is a
real table and queries compose, so a shifted self-join states it directly:

```
let Hourly = system.logs.RequestRollup where grain == Hour

Hourly >< Hourly as prev via Unrelated
  where prev.bucket_start == bucket_start - 1 hour
  { bucket_start, requests, prev.requests as previous }
```

`via Unrelated` says there is no `:>` edge between the two sides, which is true — it is the same
typed-absence discipline as any other cross product, and it is required rather than optional
here. It does not force a materialized cross product: the planner reads the equality between the
two sides and executes an equi-join, exactly as it would along a declared edge. What `via` and
the `where` do together is make the join condition visible in the query text instead of implicit
in a window frame.

Pin the grain on both sides. A chain's binding denotes the union of its levels
([aggregates.md](aggregates.md#the-union)), so an unpinned self-join would compare hourly
buckets against daily ones.

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

The moment is one half of the pair; the commit node is the other, and the two answer different
questions. Which row versions exist — including whether a tombstoned row is still visible — is
the commit node's business. What a behavior evaluates to is the moment's. A stored field reads
the same at every moment under one commit node, which is why the second coordinate only becomes
visible over a behavior. See [Historical queries](#historical-queries) for how `at` sets each.

One consequence of the pair worth stating: no sample moment sees both a re-keyed row and its
successor, so a re-key never double-counts in an aggregate.

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

**Every other field path that projects the same expression is an alias for that type.** The
second definer's path still addresses it, so `enforce` and the other mode statements resolve
through aliases and a `ValidationRef` written against either path reaches the same validation.
`:describe` reports the canonical name beside the alias, which is the only place the difference
shows.

**A computed type carries no predicate of its own.** A projected *path* keeps the source field's
validations, but a projected *expression* does not inherit them — a function need not preserve
the domain it was applied to, and there is no way to know in general that it did. A predicate on
a derived column is written as a standalone assert
([constraints.md](constraints.md#standalone-form)), which is the only form a binding has.

**A function over a key column degenerates the key**, because injectivity is not knowable in
general. That costs incremental refresh, pins the sources against `deprecate`, and makes the
result read-only. Apply functions to non-key columns, or accept a read-only table. `:describe`
reports which happened.

## Keys are computed, never declared

A `table` declares a candidate key ([tables.md](tables.md#candidate-keys-are-mandatory)). A
binding must not — its key follows from its sources and the operators applied to them, and the
system derives it.

A binding also declares no field types and no defaults, for the same structural reason: it has
no body to write them in. So the rule that every field added to an existing table carries a
default ([evolution.md](evolution.md#redeclare-a-table)) cannot reach a derived table, and the
grammar enforces that rather than a check.

**Every derived table has a key.** A table is a set of tuples, so at worst the whole tuple is
one. The question is never whether a key exists, but whether the derived key is **meaningful**
(a proper subset identifying an entity) or **degenerate** (all attributes, identifying only this
combination of values).

### How each operator propagates

**Propagation is over a key *set*, not one key.** A table may declare several candidate keys,
and each operator maps the source's set to a result set. The result is meaningful while the set
is non-empty after discarding supersets, and degenerate only when it is empty. A table keyed
both `unique orderRef { customer, order_num }` and `order_ref : Text unique` therefore survives
projecting `customer` away — the second key is untouched. `:describe` reports the shortest
surviving key, and every one of them where they differ.

| Operator | Key of the result |
|---|---|
| `where` | Unchanged. A subset of rows keyed by K is still keyed by K. |
| `{ ... }` | Every source key all of whose columns survive; **degenerate** if none does |
| `group { ... }` | The group keys. Exactly one row per distinct value, by construction. |
| `><` along a `:>` edge | K of the referencing side alone. The join is **non-multiplying** — each row matches at most one counterpart. |
| `><` outer | As above, but **degenerate** if a key column comes from the outer side |
| `><` via a `Null` type | K₁ ∪ K₂ |

There is no row for an equi-join on non-key fields, because there is no such operator: every
join runs along a declared `:>` edge or is unconditional via a `Null`-derived type. There is no
row for a union either — the only union in the language is the one a `retain` chain generates
over its levels, and it is discussed [below](#where-propagation-breaks).

Three of these need a note.

**A superkey of a declared candidate key reduces to it.** `group { c.* }` derives every column
of `c` as its key, which contains `c`'s declared key, so the result is keyed by that instead —
meaningful rather than degenerate. This is the rule that also licenses the optimizer's rewrite
above, and it is unavailable on a source with no declared key.

**Foreign keys substitute.** A key containing a `:>` field resolves to the referent's key, so
`Order` keyed `{customer, order_num}` joined to `Customer` yields `{Customer.email, order_num}`.
The key survives even when the FK column is projected away. The same substitution tells the
optimizer the join is non-multiplying; without the reference direction you would derive only the
superkey K₁ ∪ K₂, which is correct but not minimal. Non-multiplying is a statement about row
counts only: an inner `:>` join still drops every row with no counterpart, and the outer form is
what preserves them. Reserve *lossless* for the decomposition sense it carries in
[evolution.md](evolution.md#the-fragment-holding-the-key-is-the-root).

**Grouping is exact here in a way it is not in SQL.** `group` nests rather than aggregating away,
so nothing is discarded and there is precisely one output row per distinct group value. The
group keys are a key by construction rather than by argument.

### Where propagation breaks

**The rollup union** does not preserve a shared key, because two rows carrying the same key from
different levels collide. Every level of a chain is keyed `{bucket_start, ...}`, and an hourly
bucket starting at midnight collides with a daily bucket starting at midnight. `grain` is the
discriminator that fixes it, and it was introduced for the purpose — see
[aggregates.md](aggregates.md#the-union).

This is the only union in the language. There is no `union` operator over two arbitrary queries,
and none is wanted: the key-reconciliation question above is the one it would raise everywhere
instead of in the one place a chain already answers it. A union whose sources offered no
discriminator would have a degenerate key.

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
app.commerce.OrderSummary = Order { placed_at, total }
```

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

**A meaningful key is necessary for incremental refresh, not sufficient**, and the difference
decides whether a source may be retired. Refresh is incremental only when every aggregate in
the projection is also invertible under deletion and the query contains no negation over a
source. `Order group { customer } { customer, count rows as orders }` is keyed `{customer}` and
maintainable from deltas alone. `Order group { customer } { customer, max rows.total as biggest
}` has the same key and is not: deleting the maximal row needs the group rescanned, because
`max` has no inverse. So `:describe` reports a refresh *class* — `incremental`, `insert-only`,
or `full only` — and it is the class, not the key, that decides whether the sources may be
deprecated. Retiring `Order` under the second binding would leave a table that can never be
refreshed again, which is the stranding the rule exists to prevent.

## Writing through a derived table

An insert or update decomposes into one mutation per base table, ordered by FK direction —
referenced side first, so the row exists before anything references it.

```
system.auth.ServiceAccount { username = "billing-sync", purpose = "invoice ingestion" }
-- inserts a system.auth.User row, then an AccountKind row with kind = Service
```

Note what supplied `kind`. **A `where` filter is a check constraint on write, and its constant
conjuncts supply values on insert.** The row you write must satisfy the filter, and where the
filter pins a field to a constant, that constant is written. This is SQL's `WITH CHECK OPTION`
doing one extra job: it lets a write create the linking row without the call site knowing the
linking table exists.

Two operators pin a field, and they pin different amounts:

| Conjunct | Supplies |
|---|---|
| `field == <literal>` | that literal |
| `field is <nullary variant>` | that variant — the case above, `kind is Service` |
| `field is <variant carrying a payload>` | nothing; the payload is unconstrained, so the field stays required |

The third row is not an omission. `is` matches a constructor and ignores the payload, so
`status is Waived` says nothing about *what* was waived and cannot invent it. A binding filtered
that way fails admissibility condition 3 unless the field is projected.

Write-through is admissible exactly when:

1. The derived key is meaningful, not degenerate. It is what says which base row a row is.
2. Every join runs along a `:>` edge, so key propagation makes it non-multiplying and each row
   corresponds to at most one row per base table.
3. Every required field of each base table — one with no default — is either projected or fixed
   by the `where`.

**On a nested query the three conditions are checked per nesting level**, against that level's
own sources and its own `where`. Two rules join them there:

- Each level's key must be a superkey of its parent's, so every nested row belongs to exactly
  one containing row.
- Each nested column must be an unaggregated table-valued path. `count rows as n` is a scalar
  and there is nothing to write back through it.

That is what makes a nested binding an API contract in both directions: the same definition
serializes nested JSON out and accepts the same shape in, with the back-FK supplied from the
parent row exactly as a `where` constant is.

Fail any condition and the table is read-only, with `:describe` reporting which.

**`delete` removes the row the key identifies, and never cascades.** For a `:>` join that is the
*referencing* side: deleting from `ServiceAccount` appends a tombstone to the `AccountKind` row,
and the `User` survives, now matching no service-account row. This falls out of key propagation
rather than being stipulated, but "delete the service account" reads as though the user should
go too, and it does not.

What a delete may not do is strand a reference: deleting a row that live, non-`Component`
references point at is rejected. That rule belongs to the foreign key, not to the query — see
[tables.md](tables.md#deleting-a-referenced-row).

## Mutation

Row construction and row update both use `=` for their fields, as in Haskell record syntax.

```
-- Insert; `c` is a Customer row, resolved by pinning that table's key
let c = Customer where email == "ada@example.com"
app.commerce.Order { customer = c, order_num = 1042, total = 99.99, status = Pending }

-- Functional update; returns a new version, re-evaluates all functors
Order where id == "05KG3N0000ZQ8V4T1H7C" { status = Shipped }

-- Delete; appends a tombstone version, history stays readable
delete Order where id == "05KG3N0000ZQ8V4T1H7C"
```

`id` is the row's own `DataId`, rendered as 20 characters of Crockford base32
([tables.md](tables.md#basic-syntax)). A candidate key addresses the same row and is what an
application usually has in hand: `Order where customer == c && order_num == 1042`.

A brace block in query position is a **projection** when its items are bare paths, and a **row
update** when they are `field = value` bindings:

```
Order where total > 100 { customer, total }                      -- projection
Order where id == "05KG3N0000ZQ8V4T1H7C" { status = Shipped }    -- update
```

**A bare name followed by a brace block is an insert; a query carrying at least one clause
followed by one is an update.** Without that rule `Order { status = Shipped }` derives from
both, and the two readings differ catastrophically — create one row, or append a version to
every row in the table.

A write target admits `><`, `where`, and a projection, and nothing else. `at`, `diff`, `group`,
`order by`, and `limit` are rejected there: a write lands at HEAD, and sampling the past to
write into it means nothing.

### Inserting many rows

A bracket literal in insert position writes N rows in one transaction:

```
app.commerce.Product [ { sku = "A1", name = "Widget" }
                     , { sku = "A2", name = "Gadget" } ]
```

`T { … }` and `T [ { … } ]` mean the same thing, so a generated client can always emit the
bracket form. The elements are checked independently against the target's row type and an
omitted field takes its declared default, exactly as in the single-row form — the position fixes
the type, so the elements need not agree with each other about which optional fields they carry.
An empty literal is a legal no-op, which spares every caller a zero-case.

Through a derived target, N rows decompose the same way one row does, with one addition: **the
base row written is one per distinct value of that base's candidate key.**

```
OrderWithLine = Order >< OrderLine as line { Order.*, line.product, line.qty }

app.commerce.OrderWithLine
  [ { customer = c, order_num = 17, total = 30, product = p1, qty = 2 }
  , { customer = c, order_num = 17, total = 30, product = p2, qty = 1 } ]
```

Both elements agree on `Order`'s key `{ customer, order_num }`, so **one** `Order` row is
written and two `OrderLine` rows reference it. That is not a new mechanism — it is `group` by
the base's key, read in write direction, and `group` already yields exactly one row per distinct
key value. Four consequences:

- **Elements that agree on a base's key but disagree on a non-key column of that base are
  rejected**, naming the base, the key value, and the column. Not last-wins, not first-wins.
- **Elements that agree on the target's full derived key are rejected as duplicates**, so the
  row count out always equals the literal's length.
- **Decomposition never upserts.** A created base row that collides with an existing `unique`
  value fails exactly as the equivalent single-row insert fails. An insert that sometimes
  attached to an existing entity could not report a stable count, and a typo in a key would
  silently adopt the wrong parent. To attach children to a parent that already exists, insert
  the children naming the FK.
- **Where the base's key is not supplied** — defaulted, or allocated by `next` — there is
  nothing to group by, so every element gets its own base row.

Rows are applied base-major: bases in FK order, referenced side first, and within each base in
the literal's textual order. A table literal is unordered *as a value*; in insert position its
textual order is the order the mutations are applied, which is what assigns `ordinal` to
component children and orders the `DataId`s.

**One statement is one transaction**, and a literal batch is an ordinary multi-participant
transaction rather than a cluster-wide mutation: every row's placement is computable from its
key before any work starts, so the participant set is known in advance and the write cannot be
partial. See [../distribution.md](../distribution.md#bulk-and-cluster-wide-mutations). A bulk
load is not a statement — it is a handler that reads its source and commits per batch,
restartable at the last committed batch.

### Delete appends a version

`delete` follows the rule every other mutation follows: it appends a tombstone version rather
than removing anything. The row is absent from any query at or after the delete's commit node,
and present in any query pinned earlier with `at`. The `DataId` is never reused, and writing a
new version brings the row back.

Two scopes on that last clause:

- **A component subtree goes with its parent.** Deleting the parent tombstones the components
  under it, because a component's identity is the parent's identifier plus an ordinal. Only a
  non-`Component` dependent's history is untouched.
- **The tombstone of a re-keyed row is terminal.** Where the delete was half of a re-key
  ([tables.md](tables.md#changing-a-placement-key)), a write at the old key is rejected with a
  diagnostic naming the successor. Resurrecting it would put two live rows behind one entity,
  one of them recorded as superseded, while the reserved key value is still held.

**There is no second, harder delete.** A `delete!` spelling was reserved and has been removed.
It did nothing `delete` did not already do — both amounted to "removes it from the current
state, keeps it in the graph" — and the operations that would justify the sigil are `erase`,
which closes a row's history, and `scrub`, which destroys bytes already written. Both are
administrative acts reachable only from the CLI and the admin interface, never from the query
language, and neither is spelled as a variant of `delete`. See
[../integrity.md](../integrity.md#erasure-restricts-scrub-destroys).
