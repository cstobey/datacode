# Schema evolution

Every previous version of a table stays in the transaction graph. Evolution creates a new schema
node; it never modifies historical data. See
[../transaction-graph.md](../transaction-graph.md) for the underlying graph model.

Two statements do the work. Redeclare a `table` to change stored structure. Bind a query to
reshape one — rename, drop, retype, split, or merge.

## How a commit resolves names

A binding may refer to the thing it redefines, which is what lets evolution be written as
ordinary queries:

> **A name on the right-hand side resolves to the version current at the start of the commit.
> Names introduced by the commit resolve within it. The resulting graph must be acyclic.**

Under that rule `Customer = Customer { *, status as account_status }` is not circular: the right
side is the previous `Customer`, and the left side is the new one.

**A binding whose source is superseded in the same commit is frozen into storage** at that
commit. It can no longer be recomputed, because the definition it was written against is no
longer the current one, and a derived table that cannot be recomputed is stored rows. This is the
argument [aggregates.md](aggregates.md#a-rollup-is-two-appends-not-a-rewrite) already makes for
rollup levels, reaching one case further.

## Redeclare a table

Redeclare the body. The system diffs the new declaration against the last version.

Use `*` to carry forward every field the body does not mention:

```
table app.commerce.Customer { *, loyalty_tier : Tier = Bronze }
```

| Edit | Effect |
|---|---|
| Field added | New column; uses the field default if provided |
| Field omitted, body has `*` | Carried forward unchanged |
| Field omitted, body has no `*` | Deprecated. Hidden from queries; data stays in the graph. |
| Trait list changed | Applies to the new version |

**`*` is what makes omission unambiguous.** Without it you must restate the whole table, so
anything you left out you meant to leave out. With it you plainly did not list everything, so
omission carries no meaning and you drop a field with `deprecate`. Both readings are what a
reader would already assume, which is why the rule is safe to make positional.

`*` is the same selector a projection uses, doing the same job one position over. See
[queries.md](queries.md#the--selector).

`*` in a body with no previous version is a compile-time error rather than an empty expansion,
because it is a typo in every case that reaches it.

## Rename a field

A rename is a projection that mentions the source field under a new name:

```
Customer = Customer { *, status as account_status }
```

Mentioning `status` removes it from `*`, so the old column does not survive alongside the new
one. A field-level `rename from` clause used to say this and has been **withdrawn**: it was a
second spelling for something the projection already expressed, and it was the last surviving use
of `FieldDecl`'s `SourceClause`, which is gone with it.

## Change a type

A type change is a projection that applies the migration functor:

```
Customer = Customer { *, toTier (loyalty_tier) as loyalty_tier }
```

There is no separate syntax for the migration, and none is needed. A projected expression already
mints a computed type named by the field's path
([queries.md](queries.md#field-types)) and is already recorded as an edge in the schema graph,
which is exactly what a migration functor is.

## Change a validation

Validations are not added or removed by a dedicated statement. Redeclare the field with the
`where` block you want. The diff is taken per address (see
[README.md](README.md#addressing-validations)), so unchanged predicates stay put, new ones are
added, and omitted ones are dropped:

```
table app.commerce.Customer {
  *,
  email : Email
    where
      isValidEmail      -- unchanged
      maxLen 254        -- added
}
```

A predicate inherited from a trait is addressed at its trait path and cannot be dropped by
redeclaring the table. Change the trait instead.

### Add a predicate to a populated field

Existing rows were committed under a schema node where the new predicate did not apply, and the
append-only guarantee means they cannot be retroactively rejected. **The transaction that adds
the predicate must state an enforcement mode**, or it is refused:

```
table app.auth.User { *, username : Username where minLen 12 }

enforce app.auth.User.username / minLen12 forward
```

The system computes the blast radius before the commit — how many existing rows the new predicate
would mark — and reports it, because the choice between rejecting those rows' next write and
grandfathering them is only sensible to make with that number in hand. Full treatment in
[../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field).

Relaxing or removing a predicate needs no mode: nothing that conformed before can stop
conforming.

## Split and merge a table

A split is a set of bindings projecting one source. A merge is a binding joining them:

```
Person      = Customer { email, name, birth_date }
ContactInfo = Customer { email, phone }
Customer    = Person >< ContactInfo
```

All three are ordinary queries, so the derived-key rules check the decomposition that the
withdrawn `split` and `merge` statements could only assert. That check is the reason for the
change: `split Customer into { ... }` could produce fragments that no join could reassemble, and
nothing in the language would say so.

### The fragment holding the key is the root

> **The fragment that retains the source's candidate key is the root. Every other fragment gets
> a `:>` to it. If no fragment retains the key, or more than one does, the split is rejected.**

That is losslessness made structural. A fragment that drops the key derives a degenerate one
([queries.md](queries.md#keys-are-computed-never-declared)), which cannot be maintained
incrementally and would pin its source against `deprecate` — so the rejected cases are the ones
that would have stranded the schema anyway.

The generated FK is named after the root table in `lower_snake_case`, so `ContactInfo.person`
references `Person`. Rename it like any other column if the derived name collides:

```
ContactInfo = ContactInfo { *, person as owner }
```

Source tables stay visible after a split or merge. Deprecate them explicitly.

### Splitting with `group`

`group` splits a denormalized table on a repeating key, which is the shape an ETL import
usually needs. The nested table carries the residual columns and the FK back:

```
Product : Reference = DenormalizedSales
  group { product_sku, product_name }
        { product_sku, product_name, rows as Sale : UserData via product }
```

Two tables result: `Product`, keyed by the group keys, and `Sale`, holding every other column
plus `Sale.product`. The trait list is load-bearing here — a nested table is a `Component` by
default, and sales must outlive the product row they were grouped under. See
[queries.md](queries.md#naming-the-nested-table).

## Keep old names

If the redeclaration uses a *different* name, both old and new stay visible. Deprecate the old
one when ready.

```
CustomerV2 = Customer { ... }   -- Customer still accessible by name
deprecate Customer              -- hide later, when migration is complete
```

## Deprecate and prune

```
deprecate Customer          -- hides the table; dependents stay alive; data stays in the graph
deprecate Customer.phone    -- hides one field
prune Customer              -- permanently removes data; valid only once no live references remain
```

`prune` removes schema objects and orphaned branches. It does **not** remove log rows: a
`LogData` table is discarded only by a `retain` chain, and one with no chain is never pruned at
all. See [aggregates.md](aggregates.md#pruning-is-only-ever-a-consequence).

### A degenerate dependent blocks deprecation

Whether a derived table survives its sources being retired depends on the key the system derives
for it ([queries.md](queries.md#keys-are-computed-never-declared)):

- A **meaningful** key admits incremental maintenance, so the table has an existence independent
  of its sources' full extent. It is a **candidate to replace them** — the general form of what a
  retention chain does when a rollup supersedes the raw table it summarizes.
- A **degenerate** key admits only rebuilding by rescan. Deprecating the source would strand the
  dependent with no way to refresh or reconcile.

So `deprecate` on a table with a degraded dependent is rejected:

```
datacode[app.commerce]> deprecate app.commerce.Order
error: app.commerce.OrderSummary depends on app.commerce.Order and has a degenerate key,
       so it cannot be maintained without rescanning it.
       Project `customer` and `order_num` into it, or deprecate it first.
```

Alter the dependent to carry its sources' key columns, or deprecate it first. A degenerate key is
not merely untidy — it pins the schema.

## Extend and shrink an ADT

Sum types can gain or lose variants after the fact. Removing a variant that has existing data
requires specifying how those rows migrate.

```
extend Customer.status with Archived

shrink Customer.status removing Archived migrate (\_ -> Closed)
```

### Variant tags are permanent

Variants are stored as 2-byte tags assigned monotonically in declaration order. **A tag is never
reused and never renumbered.** `extend` appends; `shrink` tombstones the tag and leaves the
numbering of every other variant untouched.

This is not an implementation detail to be optimized later. Renumbering would silently change the
meaning of every historical row carrying the old tag, which is precisely the class of retroactive
rewrite the transaction graph exists to prevent.

The same applies to `Reference` tables, whose rows *are* variants — see
[traits.md](traits.md#reference-tables-are-code).

### Automatic extension

A `Reference` table carrying the `Extensible` marker trait may be extended by an automated
process rather than by a schema author:

```
table app.commerce.OrderStatus : Reference, Extensible { name : Text unique }
```

When a connector meets a code value the table does not have, it issues the `extend` transaction
itself and records which connector and token did it. Without the trait, the unknown value is
recorded as a violation instead. Both surface in the same review queue, so "a code appeared on
its own" and "a row broke a rule" are one thing to watch rather than two.

Extension is opt-in because every extension is a schema commit replicated to every server, and an
unthrottled source inventing codes is schema churn across the whole cluster. `Extensible` tables
are rate-limited per connector.

## Set visibility

Visibility is a presentation hint stored on the schema graph node. Changing it affects the IDE
and PageRank weighting, not query behaviour. See [../namespaces.md](../namespaces.md) for the
level definitions.

```
set visibility app.commerce.Order standard
set visibility connectors.mariadb.production.* connector
```

## Coercion between schema nodes

Because all functors are transparent, the system derives a coercion path between any two schema
graph nodes:

- **Adding a field** — old records get `NotFound` for it.
- **Removing a field** — new records do not have it; old records still do, in the historical
  graph.
- **Changing a type** — the projection that made the change is the coercion, recorded as an edge.

This is what enables backwards compatibility (old clients read from historical schema nodes), A/B
testing (two schema variants coexist at different graph nodes, data coerced on the fly), and
zero-downtime schema changes (no `ALTER TABLE` locks).
