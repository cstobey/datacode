# Schema evolution

Every previous version of a table stays in the transaction graph. Evolution creates a new schema
node; it never modifies historical data. See
[../transaction-graph.md](../transaction-graph.md) for the underlying graph model.

Two statements do the work. Redeclare a `table` to change stored structure. Bind a query to
reshape one — rename, drop, retype, split, or merge. A binding rooted at the name it binds
redeclares the stored table; one that is not replaces it with a derived table.

## How a commit resolves names

A binding may refer to the thing it redefines, which is what lets evolution be written as
ordinary queries:

> **A name on the right-hand side resolves to the version current at the start of the commit.
> Names introduced by the commit resolve within it. The resulting graph must be acyclic.**

Under that rule `Customer = Customer { *, status as account_status }` is not circular: the right
side is the previous `Customer`, and the left side is the new one.

### A self-rooted binding redeclares the table

> **A binding whose query is rooted at the name it binds redeclares that table.** The declared
> key, `unique` constraints, asserts, `order by`, trait list, and storage carry forward,
> addressed by path exactly as `*` and the validation diff are. A binding whose query does not
> mention the name it binds replaces the table with a derived table.

Without the first half there is no way to rename or retype a field on a stored table. A
`TableBody` admits no projection item and `FieldDecl`'s `SourceClause` is withdrawn, so the
reshaping has to be written as a query — and a query at a stored table's path would otherwise
drop the declared key silently, taking placement with it, since on a `UserData` table the key
declaration is also the sharding declaration ([tables.md](tables.md#keys-must-be-rooted)).

The second half is what keeps a merge a merge. `Customer = Person >< ContactInfo` does not
mention `Customer` on the right, so it replaces the stored table with a derived one and the
derived-key rules apply to it. See [Split and merge a table](#split-and-merge-a-table).

### Superseding a source freezes the binding

**A binding whose source is superseded in the same commit is frozen into storage** at that
commit. What it loses is currency, not recomputability: the source stays in the graph and stays
queryable at its own node, so the extent can still be derived and checked — but the name the
binding reads now denotes something else, so it can never pick up another write. A derived table
that cannot track its source is stored rows. This is the argument
[aggregates.md](aggregates.md#a-rollup-is-two-appends-not-a-rewrite) already makes for rollup
levels, reaching one case further.

Freezing is also the **one deliberate backfill in the language**, and the only escape from the
defaults that [Every added field declares a default](#every-added-field-declares-a-default)
rejects. `Customer = Customer { *, Bronze as loyalty_tier }` writes `Bronze` into every stored
row, where `table app.commerce.Customer { *, loyalty_tier : Tier = Bronze }` writes nothing and
computes the value at read. Two spellings, opposite costs — so the commit reports the difference:
a projection over a superseded source that introduces a constant column is diagnosed with the row
count it will write.

## Redeclare a table

Redeclare the body. The system diffs the new declaration against the last version.

Use `*` to carry forward every field the body does not mention:

```
table app.commerce.Customer { *, loyalty_tier : Tier = Bronze }
```

| Edit | Effect |
|---|---|
| Field added | New column. A `DefaultClause` is mandatory and is what every existing row reads. Nothing is rewritten. |
| Field restated | Not an add. The diff is taken per address, so no default is required. |
| Field omitted, body has `*` | Carried forward unchanged |
| Field omitted, body has no `*` | Deprecated. Hidden from queries; data stays in the graph. |
| Trait list omitted | Carried forward from the previous version |
| Trait list changed | Applies to the new version. Fields the added trait contributes are added columns and need defaults. |

**`*` is what makes omission unambiguous.** Without it you must restate the whole table, so
anything you left out you meant to leave out. With it you plainly did not list everything, so
omission carries no meaning and you drop a field with `deprecate`. Both readings are what a
reader would already assume, which is why the rule is safe to make positional.

`*` is the same selector a projection uses, doing the same job one position over. See
[queries.md](queries.md#the--selector).

`*` in a body with no previous version is a compile-time error rather than an empty expansion,
because it is a typo in every case that reaches it.

**An omitted trait list is carried forward; it is not an empty one.** Omission deprecates a
*field* because `*` gives you a way to say otherwise, and there is no equivalent selector for
traits. Reading the omission as "no traits" would strip `Active` and `UserData` from the example
above, and a table with no replication trait has no defined placement.

### Every added field declares a default

> **A field added to an existing table must carry a `DefaultClause`. Omitting one is a
> compile-time error.**

The rule is unconditional. It does not depend on whether the table currently has rows, which is
the opposite polarity from
[../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)'s "a mode is mandatory
on a populated field". The asymmetry is deliberate: that rule is conditional because the
blast-radius *number* is what the author needs in hand, and here there is no number. The answer
is the same at zero rows and at forty million, so a conditional rule would only produce a schema
file that succeeds in development and fails in production. The trait path settles it — a field
added to a trait lands on every table extending it, and the set of extending tables grows after
the commit, so "does the table have rows" is not decidable where the field is declared.

**Nothing is backfilled.** No old row is rewritten. The value is computed at read from the schema
node **current for the row version being read** — not "the node that added the field", which need
not be unique: a two-parent merge where both branches added it, or a field deprecated and
re-declared, each give more than one.

The read-time default is a **fallback, not a derivation.** It stops applying to a row the moment
that field is written on that row, so "nothing is backfilled" holds per row until the first
write.

This replaces three contradictory answers to what an added field reads on an older row: the
default, `NotFound`, and `NotGiven`. The latter two are wrong for one reason — both sit
**outside the field's declared type**. `loyalty_tier : Tier` returning `NotFound` makes an
exhaustive match over `Tier` non-exhaustive, and it does so because of an evolution that happened
*later*, which would make [../category-model.md](../category-model.md#absent-values)'s "every
consumer is forced by the type system to handle the absent case" untrue of every field in the
database.

Requiring the default outright is stronger than requiring *either* a default *or* a
`Null`-derived variant in the type, and better. The weaker rule has to infer which variant an old
row reads, and a type may carry two (`Phone | NotGiven | Redacted`). Writing the default removes
the inference.

#### Which defaults are admissible

> **A default is admissible on an added field exactly when it is `Pure` *and* stable for the life
> of the row** — reproducible at read from the old row plus the schema node, and identical to
> what an insert after the add would have stored.

`Pure` alone is too weak. `= other_field * 2` and `= (OrderStatus where name == "Pending")` take
no ambient input, but an old row recomputes them at read while a row inserted after the add froze
the value at insert. The two populations diverge with nothing in the row saying which regime it is
under. [tables.md](tables.md#ineligible-key-fields) already excludes `updated_at` from a key on
exactly that ground.

| Default form | Admissible on an added field? | Why |
|---|---|---|
| Literal — `= 0`, `= "Unknown"`, `= True` | **Yes** | Closed, constant-folded at schema commit. The value is a property of the schema node, not of any row. |
| Nullary variant — `= Bronze`, `= NotGiven` | **Yes** | Closed constant. The canonical added-`:>` shape is `f :> T \| NotGiven = NotGiven`. |
| Variant with payload — `= Waived "migrated"` | **Yes**, if every argument is | Constructor application over admissible arguments is itself closed. |
| Function application — `= defaultTier`, `= percent x 2` | **Yes**, if the inferred effect is `Pure` and every argument is admissible | Not a new rule. [functions.md](functions.md#the-effect-ladder) infers the effect from the body and checks it against the position; here the ceiling is `Pure` rather than `Tx`. |
| `if`, `let`, parentheses | **Yes**, if every sub-expression is | Structural; carries no effect of its own. |
| A path into an immutable virtual column — `= created_at`, `origin_server`, `ordinal`, `grain` | **Yes** | [tables.md](tables.md#ineligible-key-fields) certifies exactly this set as immutable for the life of the row, for exactly this reason. |
| A path into a stored or mutable field — `= total * 0.01`, `= updated_at` | **No** | `Pure` but not stable. A row inserted after the add computes once and stores; an old row computes at read from its current version. |
| `= authed_user` | **No** | Transaction-ambient input, not row data. It *does* resolve on a read path — to whoever is reading — so `created_by` would differ between two readers of one row. Failing silently is worse than failing. |
| A lambda on a `Behavior` field — `= \t -> …` | **Yes**; the rule is vacuous | The clause is already mandatory and is the behavior's definition rather than a default. Nothing is stored, so both populations read identically. This is the mechanism the rule generalizes. See [types.md](types.md#behaviors). |
| A name or literal on a function-typed field | **Yes**, subject to [functions.md](functions.md#where-a-literal-is-admissible) | The value is a name or a serialized term living in the schema graph. It takes no row input at all. |
| A query | **No** | `Read`, not `Pure`. The sample moment is a parameter rather than a clock, but an old row's value still moves with each reader's moment while a post-add insert is frozen. A default that varies per observation is a `Behavior` with the `Moment` hidden, and the lambda row above is the honest spelling. |
| A record literal constructing a row — `= { theme = Dark }` | **No — and none is needed** | The construction inserts a row in the same transaction, and a row committed last year has none. But a `:>` whose target carries `Component` is table-valued, so its old-row value is the **empty table** — inside the declared type, no write, no ambient input. Add such a field with no `DefaultClause` at all. |
| `= next <unique>` | **No** | It allocates rather than evaluates: a read-modify-write on a counter row ([tables.md](tables.md#sequences)). It is the one genuinely `Tx` default. |
| No clause at all | **No**, except a `Behavior` field and a `:>` to a `Component` target | A `Behavior` already carries a mandatory clause that is not a default; a table-valued `:>` has a well-typed empty value. Everything else is a compile-time error. |

Two rules travel with the table:

- **The default must satisfy the field's own `where` block.** It becomes the value of every
  existing row, so a default that fails its own predicate marks 100% of them in one commit — a
  schema error, not a migration choice.
- **No `unique` field may be added to a populated table.** Every admissible default is constant
  and no injective row-local expression is spellable, so the first two existing rows collide. Add
  the column, write the values, then add the constraint.

The rejection diagnostic names a **two-step, two-language** path: a statement that adds the
field, then a mutation that writes the values. Both are admissible in a script; only the first is
a schema-file statement. The diagnostic says which file each belongs in rather than stopping at
"run a bulk mutation".

#### What the rule binds

The rule is over the **effective field set** and over the **commit diff**, never over the text of
one `table` body:

- **Inherited fields count.** A trait that gains a field adds a column to every table extending
  it, so the check runs at two sites: at the trait, and again at a table gaining that trait,
  whose fields may predate the rule. A table discharges the rule for an inherited field by
  restating that field with a default, for that table only. See
  [traits.md](traits.md#extending-a-table-from-traits).
- **Restating is not adding.** A field carried forward by `*`, or restated to change its `where`
  block, already exists in the previous version and needs no default.
- **Generators are bound, not only authors:** a connector's shadow schema, `Doc indexed`
  siblings, rollup levels, and a split's generated `:>`. A connector reads its default off the
  source DDL — the source's own `DEFAULT` where there is one, else `| NotGiven = NotGiven` —
  because a default chosen for tidiness turns one DDL statement into a full-table conflict storm
  at the next verification tick. See [../connectors.md](../connectors.md#schema-auto-discovery).
- **DataCode's own tables are bound.** An upgrade that adds a field to `system.auth.*` ships a
  default and cannot backfill an operator's rows. "The schema is data" leaves the product's own
  author less able to see the data than an application author is.
- **A derived table is out of reach**, and the grammar is what puts it there rather than a check:
  a binding has no body in which to write a field declaration. See
  [queries.md](queries.md#keys-are-computed-never-declared).

## Rename a field

A rename is a projection that mentions the source field under a new name:

```
Customer = Customer { *, status as account_status }
```

Mentioning `status` removes it from `*`, so the old column does not survive alongside the new
one. The query is rooted at `Customer`, so it redeclares the stored table rather than replacing
it with a derived one, and the key, traits, asserts and ordering carry forward — see
[A self-rooted binding redeclares the table](#a-self-rooted-binding-redeclares-the-table).

A field-level `rename from` clause used to say this and has been **withdrawn**: it was a second
spelling for something the projection already expressed, and it was the last surviving use of
`FieldDecl`'s `SourceClause`, which is gone with it.

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
conforming. Neither does a predicate on a *newly added* field: its default is closed, so the
blast radius is 0% or 100%, and a default that fails its own predicate is rejected outright
rather than offered three modes.

## Split and merge a table

A split is a set of two or more bindings projecting one source in a single commit. A merge is a
binding joining them:

```
Person      = Customer { email, name, birth_date }
ContactInfo = Customer { phone }
Customer    = Person >< ContactInfo
```

All three are ordinary queries, so the derived-key rules check the decomposition that the
withdrawn `split` and `merge` statements could only assert. That check is the reason for the
change: `split Customer into { ... }` could produce fragments that no join could reassemble, and
nothing in the language would say so.

The merge line does not mention `Customer` on the right, so it replaces the stored table with a
derived one rather than redeclaring it. It supersedes the fragments' source in the same commit,
so both fragments are frozen into storage.

### The fragment holding the key is the root

> **Exactly one fragment retains the source's candidate key. That fragment is the root; every
> other fragment gains a `:>` to it, minted by the split. If no fragment retains the key, or more
> than one does, the split is rejected.**

The minted foreign key is what makes the decomposition lossless, and it is the only attribute the
fragments share. A vertical decomposition rejoins exactly when the shared attributes are a
superkey of one fragment; here the shared attribute is a reference to the root row, which is a
superkey of the root by construction. So the merge has an edge to join along, rather than the
compile-time error an edgeless `><` would be ([queries.md](queries.md#join-operator)).

Copying the key into a second fragment instead is what the rule rejects, and not for tidiness.
Both fragments become stored tables in this commit, so a copied key is two `unique` constraints
over one value with nothing keeping them equal.

The foreign key is also what keeps a fragment one row per source row. `ContactInfo` projects only
`phone`, and a projection that drops the key derives a degenerate one
([queries.md](queries.md#keys-are-computed-never-declared)) — two customers sharing a phone
number would collapse into one row. The minted `person` distinguishes them, and it is the
fragment's candidate key.

Losslessness is therefore structural rather than asserted. A fragment that drops the key and
gains no reference back could not be maintained incrementally and would pin its source against
`deprecate`, so the rejected cases are the ones that would have stranded the schema anyway.

A split fragment is the one place a derived table holds a column its own query does not project,
beside the inheritance and computation that [queries.md](queries.md#field-types) lists. The
generated FK is named after the root table in `lower_snake_case`, so `ContactInfo.person`
references `Person`. It is an ordinary column: `*` sees it, the merge joins along it, and it is
the fragment's derived key. Rename it like any other column if the derived name collides:

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
plus `Sale.product`. The trait list is load-bearing here. A nested table is a `Component` by
default, and `Component` means owned lifetime — deleting a product would take its sales with it.
Naming `UserData` instead gives the sales rows a lifetime of their own. See
[queries.md](queries.md#naming-the-nested-table).

## Keep old names

If the redeclaration uses a *different* name, both old and new stay visible. Deprecate the old
one when ready.

```
CustomerV2 = Customer { *, toTier (loyalty_tier) as loyalty_tier }  -- Customer still accessible
deprecate Customer                                                  -- hide when migration is done
```

## Deprecate and prune

```
deprecate Customer          -- hides the table; dependents stay alive; data stays in the graph
deprecate Customer.phone    -- hides one field
prune Customer              -- removes the schema object once no live reference remains;
                            -- row data in the graph is untouched
```

`prune` removes schema objects and orphaned branches. It does **not** remove log rows: a
`LogData` table is discarded only by a `retain` chain, and one with no chain is never pruned at
all. See [aggregates.md](aggregates.md#pruning-is-only-ever-a-consequence).

Two things a default pins:

- **The schema node that added a field is pinned against `prune`** by every row older than it,
  because the node is where those rows read their value. One field may carry several generations
  of default, and each generation pins its own node.
- **`deprecate <table>.<field>` is rejected while a live field's default mentions that field.**
  Otherwise a default resolves against data the query layer has been told does not exist.

### A field path is bound to its type for the life of the table

> **Once declared, a field path keeps its declared type for as long as the table exists.
> Re-declaring it with the identical type un-deprecates it and needs no default. Re-declaring it
> with a different type is rejected — choose a new name.**

This mirrors the tag rule under [Variant tags are permanent](#variant-tags-are-permanent), for the
same reason: an identifier that has stood for one thing may not quietly stand for another. Both
other readings break something. Treating a re-declaration as an add makes rows written before the
deprecation read the default instead of their stored value. Treating it as neither leaves rows
written while the field was hidden undefined. Binding the path to its type keeps every stored
value readable, and keeps `deprecate` what it claims to be — hiding, not destruction.

### A degenerate dependent blocks deprecation

Whether a derived table survives its sources being retired depends on the key the system derives
for it ([queries.md](queries.md#keys-are-computed-never-declared)):

- A **meaningful** key admits incremental maintenance, so the table has an existence independent
  of its sources' full extent. It is a **candidate to replace them** — the general form of what a
  retention chain does when a rollup supersedes the raw table it summarizes.
- A **degenerate** key admits only rebuilding by rescan. Deprecating the source would strand the
  dependent with no way to refresh or reconcile.

So `deprecate` on a table with a degenerate dependent is rejected:

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

**The row is branch-versioned; the tag is cluster-wide.** A `Reference` row is schema, so it
lives on the branch that declared it. Its tag does not: two branches allocating tag 7 to
different names would carry two meanings for one tag into a merge, and renumbering is the fix
the paragraph above rules out. The allocator is a table-wide `next` and needs no new mechanism —
it sits in the constraint's own shard, and the cost lands on an operation that is already a
serialized schema commit. An offline branch cannot reach it, so its `Reference` rows exist by
name until upload and receive tags there. That is sound because a local branch holds no user
data, so nothing on it was ever stored under a tag.

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

Because all functors are transparent, the system derives a coercion along the recorded edges, in
the direction they were written:

- **Adding a field** — a row older than the adding node reads that field's mandatory default,
  computed at read. Nothing is backfilled. See
  [Every added field declares a default](#every-added-field-declares-a-default).
- **Removing a field** — new records do not have it; old records still do, in the historical
  graph.
- **Changing a type** — the projection that made the change is the coercion, recorded as an edge.

**The reverse direction is not free.** Transparency gives inspectability, not invertibility.
`toTier` is not injective in general — the same reason a function over a key column degenerates
the key ([queries.md](queries.md#where-propagation-breaks)) — so a new-to-old coercion is
derivable only where the projection is injective on the columns it touched, or where a removed
column has a declared default. Otherwise the coercion is partial and the missing column resolves
to its declared absence variant.

Forward coercion is what carries backwards compatibility (old clients read from historical schema
nodes) and zero-downtime additive change (no `ALTER TABLE` locks). A/B testing across two sibling
branch nodes needs both directions — forward from the common ancestor down one branch, backward
up the other — so it holds only where each backward step is invertible by the rule above.
