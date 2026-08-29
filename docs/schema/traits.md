# Traits

Traits are abstract table types. They cannot be instantiated directly — they are extended
by concrete tables. A trait adds fields, functions, replication policy, and (optionally) UI
template hints to every table that extends it.

## Declaring a trait

```
trait Active {
  is_active : ActiveStatus | InactiveStatus,

  -- Functions declared in a trait are available on every table extending it
  active   = is_active is ActiveStatus,
  inactive = is_active is InactiveStatus
}
```

**A trait function declares no parameter for the row.** `self` is bound to the row under
evaluation by the context the function runs in, and no declaration may introduce a name that
collides with a binding in scope, so `active self = …` is rejected — see
[railroad.md](railroad.md#contextual-bindings). Bare field paths resolve against that row;
write `self` explicitly only where a query needs a root, as an
[assert](constraints.md#anchoring) does. See [functions.md](functions.md#trait-functions).

A trait may extend another trait with `:`:

```
trait Catalog : Reference {
  is_visible : Bool = True
}
```

Trait fields use the same declaration syntax as table fields, including `:>` for
references and `where` for validation:

```
trait Owned {
  owner      :> system.auth.User,
  claimed_at : Timestamp | Pending
}
```

## Extending a table from traits

The `:` operator after the table name declares which traits the table extends. Same
colon-as-"is a kind of" convention used throughout the type system — the right-hand side
here is a list of traits, never types or tables.

```
table app.commerce.Customer : Active, UserData {
  email : Email unique,
  name  : Text
}

-- active and inactive are now predicates on a Customer row
app.commerce.Customer where active
```

## Multiple inheritance

Tables may extend multiple traits. Two traits declaring a field with the same name is a
collision, and there is exactly one resolution: **merge, by bare redeclaration**.

```
trait A { name : Text where isNotEmpty }
trait B { name : Text where maxLen 100 }

table Bar : A, B {
  name : Text   -- bare redeclaration; validations from A and B are both applied
}
```

This is the one place conjunction arises without appearing in the syntax. `Bar.name` behaves
as though every inherited predicate had been written in a single `where` block on it —
there is no repeated `where` in the source, and none is needed.

The origin addresses survive the merge. A predicate inherited from `A` is still addressed at
`A.name`, one from `B` at `B.name`, and anything `Bar` adds itself at `Bar.name`:

```
table Bar : A, B {
  name : Text where isTitleCase
}
-- A.name        → isNotEmpty
-- B.name        → maxLen 100
-- Bar.name      → isTitleCase
-- all three are enforced on Bar.name
```

Those paths are the ordinary inherited-field path form. See
[README.md](README.md#addressing-validations).

The merge is rejected where the two declarations disagree on anything but predicates:
different types, different `:>` targets, or a `Behavior` on either side. Predicates conjoin;
definitions do not.

### Keeping both fields is not available

A field-level `from A.name` clause used to spell a rename that kept `A.name` and `B.name` as
two columns. It went with `SourceClause` ([railroad.md](railroad.md#fields)) and nothing
replaces it, because a per-table rename cannot work: **a trait's functions and validations name
its own fields**, so renaming `A.name` to `a_name` on one extending table would leave `A`'s
functions naming a field that table does not have. The rename would have to rewrite the trait
for one extender, which is the opposite of what extending a trait means.

Where the two fields genuinely mean different things, do not extend both traits — rename the
field in one of them, or split the trait. Renaming *downstream* of the table, for a caller or
an export, is a projection and stays available:
`Bar2 = Bar { *, name as display_name }` ([evolution.md](evolution.md#rename-a-field)).

### A table may supply a default for an inherited field

Bare redeclaration also carries a `DefaultClause`, for that table only:

```
-- Customer already has rows; gaining Active adds is_active as a new column
table app.commerce.Customer : Active, UserData {
  *,
  is_active : ActiveStatus | InactiveStatus = ActiveStatus
}
```

The redeclaration changes nothing on the trait and nothing on any other extender. It is the
discharge route for the rule below.

## Adding a field to a trait

A trait adds its fields to every table extending it, so **the added-field default rule reaches
the trait path** ([evolution.md](evolution.md#every-added-field-declares-a-default)). It is
checked at two sites, and both are needed:

- **At the trait.** A field added to an existing trait carries a `DefaultClause`. The check
  cannot be conditional on whether a table has rows, because the set of extending tables grows
  after the commit — a table that extends the trait tomorrow is populated today.
- **At the table gaining a trait.** Extending a trait adds its fields as columns to a table
  that may already have rows, and those fields may predate the rule. Every field the trait
  contributes must carry a default — on the trait, or on the table by
  [bare redeclaration](#a-table-may-supply-a-default-for-an-inherited-field).

The second site is a stronger argument for making the rule unconditional than the
development-versus-production one: most traits in this document declare no defaults, so they
are unaddable to a populated table until a default appears somewhere. [`Accruing`](#behaviors-in-traits)
is the clearest case — its `balance` behavior needs nothing, because a behavior is computed at
read and stores nothing, while `principal`, `rate`, and `opened_at` each need a default before
any populated table may extend it.

A trait is redeclared like a table: `*` carries forward every field the new body does not
mention, and without it omission deprecates. See
[evolution.md](evolution.md#redeclare-a-table).

## Replication traits

The shard types map to built-in traits. Tables declare their replication policy by
extending one of these.

| Trait | Replication | Cardinality |
|---|---|---|
| `Reference` | Every server | Low–medium |
| `Configuration` | Every server | Medium |
| `UserData` | Shard-local | High |
| `LogData` | Shard-local, prunable | Very high |

**`LogData` replicates.** Every shard has two secondaries, `LogData` included. What differs is
that a `LogData` primary commits when its own append is durable and ships accumulated deltas
afterwards, so log volume never puts two network round trips on the hottest path in the
cluster. This replaces an earlier "server-local, not cross-replicated" reading: a segment is
still contiguous on the server that wrote it, and it is no longer the only place it is read.
The class is a default rather than a property of the trait — some `LogData` is audit evidence
that cannot be reconstructed — so `system.shards.DurabilityPolicy` overrides it per table. See
[../distribution.md](../distribution.md#two-durability-classes).

`LogData` means **prunable, not pruned**. A `LogData` table is discarded only by a `retain`
chain, and one with no `retain` statement is never discarded at all — silence means keep,
because "prune the log shard" is the operation most likely to be run under pressure. It is
also the trait that exempts a table from needing a candidate key, and the two facts have the
same root: its rows are occurrences. See [aggregates.md](aggregates.md).

**There is no `system` replication trait.** `system` is a namespace, and a table in it carries
whichever of the above fits: `system.integrity.Violation` and the `system.events` queues carry
`LogData`, `system.shards.Node` carries `Configuration`. The namespace says whose a table is
and who may see it ([../namespaces.md](../namespaces.md)); the trait says how it propagates.
Neither implies the other. `system` was previously listed as a fifth shard type in
[../transaction-graph.md](../transaction-graph.md#data-shards), which is corrected there.

**`Component`, `Keyless`, `Personal`, and `Extensible` are marker traits.** They occupy no
replication slot and compose with whichever one the table carries, so
`table app.commerce.OrderTag : UserData, Component` is legal.

Built-in replication traits are regular traits — user-defined traits can extend them
freely:

```
table app.commerce.Product : Catalog, Active {
  name  : Text unique,
  price : Amount
}
-- Product replicates to every server: Catalog extends Reference
```

Having multiple replication base traits in a single inheritance hierarchy is a compile-time
error.

See [../distribution.md](../distribution.md) for what each replication policy means
operationally.

## Traits are not configuration

A trait is part of a table's declaration, so changing one is a schema commit that replicates to
every server. That makes it the wrong home for anything an operator tunes per deployment:

> **A trait declares what a table *is*. A configuration row declares how a deployment *treats*
> it.** If the value should be identical in every deployment and changing it deserves a schema
> commit, it is a trait. Otherwise it is a row.

Extent size and segment period fail that test — they track hardware, and staging and production
must be able to differ without branching the schema. So does replication durability: `LogData`
sets the default, and `system.shards.DurabilityPolicy` overrides it per table
([../distribution.md](../distribution.md#two-durability-classes)). They are therefore rows in
`system.shards.ExtentPolicy`, keyed by table path, with a per-server override in
`system.shards.ExtentOverride` keyed by `{ table, server }`, resolved most-specific-first. Two
tables rather than one key with an "all servers" variant, because a `Null`-derived variant in a
key is rejected ([tables.md](tables.md#ineligible-key-fields)) and rightly so. This is the same
separation that keeps enforcement modes ([../integrity.md](../integrity.md)), queue retry policy
([../events.md](../events.md)), and retention ([aggregates.md](aggregates.md)) out of table
bodies.

**Traits take no parameters**, and `TraitList` admits a bare `QName` only. Where a declaration
genuinely must name a policy, the established spelling is a reference to a policy row rather
than a literal argument —

```
type Password : Hashed Text using system.crypto.HashPolicy.password_v2
```

— which keeps the values in a table where they can be changed, versioned, and access-controlled
like anything else.

## `Component`

`Component` marks a table whose rows exist only within a single parent row: they are created
with it, live in its shard, and are destroyed with it. This is composition in the strict
sense — the part has no independent existence.

**It is a marker trait, not a replication trait.** It occupies no slot, so
`table app.commerce.OrderTag : UserData, Component` is legal. "Wherever the parent is" is not a
replication *policy* — it is what rooted placement already means — and the row's real
replication answer comes from `UserData`. This replaces the earlier rule that made
`Component, UserData` an error for the reason `UserData, LogData` is one.

**What `Component` declares is one bit: does deleting the owner destroy the owned?**
`Component` means cascade; its absence means restrict. Everything it used to bundle beyond that
— the ordinal representation, `created_at` inheritance, placement — follows from the key
instead. The declaration side, with the cardinality rules, the many:many guidance and the cost
tables, is in [tables.md](tables.md#component-sub-tables).

```
table app.commerce.Customer : UserData {
  email   : Email unique,
  address :> Address : Component {   -- inline sub-table
    street : Text,
    city   : Text,
    zip    : Zip
  }
}

table app.commerce.Address : UserData, Component { ... }   -- the generated sibling
```

`: Component` on the inline declaration is what makes the sibling a component. Without it the
generated table is an ordinary one, needing a candidate key and a `DataId` of its own. The
sibling takes the parent's replication trait and adds the marker.

### What `Component` changes

**Identity.** A component row has no `DataId`. It is identified by its parent's identifier
plus a 4-byte `Ordinal`, and only the ordinal is stored — the timestamp, server node, and
sequence are inherited through the containment link. The parent reference therefore costs
zero bytes, because the parent *is* the identifier prefix. See
[../transaction-graph.md](../transaction-graph.md#component-ordinals).

The inheritance shows up in the virtual columns: `created_at` and `origin_server` come from
the parent, since a component has no identifier bytes of its own beyond its ordinal. Declare a
`Timestamp` field where the component needs a creation time of its own; decide that at
declaration rather than finding it later. In exchange the row gains a fourth virtual column,
**`ordinal`** — its position under that parent, at its own nesting level — which is how
document order is stated in a query rather than merely received from a range scan. See
[tables.md](tables.md#basic-syntax).

**Locality.** A component is always in its parent's shard. Ordinal assignment is a
read-modify-write against the parent's current maximum, which needs no coordination because
the shard primary linearizes writes. This is the invariant that makes the compact identifier
sound rather than merely small. It is still a serialization point on that parent, so schema
commit prices it with the same diagnostic a table-wide `next` gets, naming the serialization it
introduces ([tables.md](tables.md#sequences)).

**Keys.** A component is exempt from *needing* a candidate key and is not forbidden one. Its
identity is already the parent plus its `Ordinal`, which is why the key is optional rather than
unavailable. A `unique` declared on a component is checked within the parent, so it costs one
shard-local check: `unique linkRef { order, tag }` on a component of `Order` means "this order
has at most one link to this tag". See
[tables.md](tables.md#candidate-keys-are-mandatory).

### Invariants

| Rule | Reason |
|---|---|
| A component may be reparented only within its shard root | The parent is the identifier prefix; a write that changes the shard root is a delete plus an insert, which mints a new identity |
| A component may reference outward freely | An outbound FK creates no inbound dependency |
| Nothing outside the parent's subtree *should* reference a component | Warned, not forbidden: an outside reference makes the subtree non-prunable as a unit, and blocks the parent's delete while it is live |
| Pruning the parent prunes the subtree | Composition; the subtree is orphaned by definition |
| A parent holds at most 2³² − 1 components at each nesting level | The ordinal is four bytes |

The reparenting rule used to be absolute. It is now narrower and derived rather than declared.
A reparent within one shard root keeps the shard and re-prefixes the subtree. A write that
changes the shard root is [a delete plus an insert](tables.md#changing-a-placement-key) — two
ordinary mutations in one two-participant transaction, not an update to forbid — and what lands
is a new row with a new identity. Ordinals inside a moved subtree are preserved by prefix
substitution rather than reassigned, which is what keeps one key pair sufficient to name the
whole subtree.

Ordinals are allocated at insert against a running maximum, so exhaustion is by construction a
runtime condition and cannot be detected at schema commit. The overflowing insert is rejected
with a diagnostic naming the parent row and the nesting level, and the diagnostic says what the
number means: a parent that can plausibly reach the bound has a child that should not be a
component. Tombstoned ordinals are not reclaimed, because "never reused" is what keeps a
deleted component's history addressable — editing costs no ordinal, since a new version lands
under the same one, so the bound is reached only by inserting and deleting 2³² siblings under
one parent. This matters most for shredded documents, where component subtrees are generated
from external payloads rather than authored.

Components are versioned and updated like any other row — a 1:1 component such as an address
is edited normally, producing a new version under the same ordinal.

Nesting is permitted and appends another ordinal per level. Because every descendant shares
the parent's byte prefix, an entire component subtree is one contiguous LMDB range scan; this
is what makes [documents.md](documents.md) practical.

## `Keyless`

`Keyless` is a marker trait — no fields, no functions — that waives the mandatory candidate
key (see [tables.md](tables.md#candidate-keys-are-mandatory)):

```
table app.staging.Import : UserData, Keyless {
  received_at : Timestamp,
  payload     : Doc
}
```

It occupies no replication slot and composes with whichever one the table already carries.

The polarity is deliberate. A rule you have to remember to opt into is absent from exactly
the table that most needed it, so the key requirement is on by default and `Keyless` is the
waiver. This is the same shape as enforcement modes, where `enforce always` is the default
and weakening it is an explicit, recorded act ([../integrity.md](../integrity.md)) — and it
is the opposite polarity from `Extensible` below, because extensibility is a capability you
choose and keylessness is a defect you are admitting.

`Keyless` is written on a table whose rows genuinely have no natural identity. It is not for
a table whose key is merely inconvenient to work out; a table that has a key and does not
declare it silently loses merge reconciliation, upsert-by-key, and a defined default
ordering.

Connector shadow tables carry `Keyless` automatically when the external source has no primary
key, and the connector records why — see
[../integrity.md](../integrity.md#connector-tables-without-a-source-key).

## `Personal`

`Personal` is a marker trait — no fields, no functions — that makes a table's rows eligible for
erasure:

```
table app.crm.Contact : UserData, Personal {
  email : Email unique,
  name  : Text
}
```

It occupies no replication slot. What it changes is what history returns after an `erase`: on an
ordinary table a tombstoned row stays readable at earlier sample moments, and on a `Personal`
table an erased row reads `Erased` at every moment unless the token holds `bypass erasure`.

Eligibility is opt-in because erasure is the one act that closes history, and a table whose rows
are not about a person has no reason to admit it. Scrubbing has the opposite polarity and needs
no trait, because a leaked credential lands wherever the API put it. See
[../integrity.md](../integrity.md#erasure-restricts-scrub-destroys).

## `Queue` and `QueueState`

`Queue` extends `LogData` and marks a table as a work list for the event scheduler:

```
trait Queue : LogData {
  scheduled_at : Timestamp = created_at
}
```

Beyond that field the trait body is empty, because what makes a queue a queue is four rules,
two of them about field *types*, and the grammar has no way to say "a foreign key to any table
carrying trait X". They are checked at schema commit:

1. Exactly **one** `handler`.
2. Exactly **one** `:>` field to a table carrying `QueueState`.
3. At most **one** field whose type is `Priority`.
4. Every field other than the `QueueState` field is append-only, as `LogData` requires.

Rules 2 and 3 read the field's **type**, never its name — the same structural reading that
decides an assert's variety from its body rather than its identifier.

```
trait QueueState : Reference {
  name        : Text unique,
  disposition : Pending | InFlight | Done | Failed
}
```

The `QueueState` field is the **one exemption from append-only**, and it is narrow: one field,
on a `Queue` table, written only by the handler bound to that queue. That exemption is what
makes a queue row pollable by a client — it reads a domain-meaningful state (`Bound`,
`Applied`) while the scheduler reads that state's `disposition`.

**Every other after-the-fact state on a `LogData` table goes in its own `LogData` table** with a
`:>` back to the row it describes, and the current state is a read over the latest such row.
That is the general rule the exemption is an exception to, and it covers a consumed challenge, a
waived violation, and a sampled trigger's held bit as much as it covers a queue's attempt
record; the [attempt history](../events.md#attempt-history) is the worked case.

`handler` was previously valid on any `LogData` table and is now valid only on a `Queue`. A log
is not a work list. Full treatment in [../events.md](../events.md#queue-tables).

## `Reference` tables are code

`Reference` has always been described as "code tables, treated as code, propagated
everywhere". That is meant literally: **inserting a row into a `Reference` table is a schema
transaction**, committed to the schema graph rather than to a data shard. The schema graph is
rooted at a branch, so a `Reference` row lives on the branch shard with the declarations beside
it — which is what makes the offline local-branch workflow possible, since an administrator
clones the schema graph to the branch point plus its `Reference` rows and nothing else. See
[../distribution.md](../distribution.md#schema-shards-are-rooted-at-a-branch).

Four consequences:

- **A field referencing a `Reference` table stores a 2-byte variant tag**, not a 12-byte
  `DataId`. On a billion-row table with three code fields that is 30 GB.
- **`is` against a `Reference` row is checked at schema-commit time.** `status is Shipped`
  fails to compile if no row named `Shipped` exists at that schema node, so a mistyped code
  name is a compile error rather than a query that silently returns nothing. The operator's own
  two readings are in [types.md](types.md#the-is-operator).
- **Variant tags are assigned monotonically and never reused.** `shrink` tombstones a tag
  rather than renumbering, because renumbering would silently change the meaning of every
  historical row ([evolution.md](evolution.md#variant-tags-are-permanent)).
- **Past 65 535 variants the table is not a code table.** This is rejected at commit with
  that diagnostic, which gives the "low–medium cardinality" guidance actual teeth.

**The row is branch-versioned; the tag is cluster-wide.** Tag allocation cannot be
branch-scoped for the reason renumbering is forbidden: two branches would allocate tag 7 to
different names, and a merge would carry two meanings for one tag with no repair available. The
allocator is an ordinary table-wide `next` living on the constraint's own shard. A genuinely
offline branch cannot reach it, so its `Reference` rows exist **by name** on the branch and
receive tags at upload — sound, because a local branch holds no user data, so nothing on it was
ever stored under a tag. See
[../distribution.md](../distribution.md#the-row-is-branch-versioned-the-variant-tag-is-cluster-wide).

The token does not change. A field referencing a `Reference` table is still declared with
`:>`, still carries an FK functor, and still adds an edge to the join graph — the FK functor
resolves a tag rather than a `DataId`. The
[`:` versus `:>` rule](README.md#-versus-) is load-bearing and stays exactly as it is; every
benefit above is a storage and checking change underneath it.

### When a `Reference` table is warranted

> **A `Reference` table is needed exactly where a fact originates outside the schema graph.**

Because a `Reference` row *is* a schema fact, it is tempting to mirror the schema into
`Reference` tables in the name of self-hosting. That is the wrong reading:
[self-hosting](README.md#self-hosting-principle) means system *state* is queryable, and the
schema graph is already queryable. Restating a declaration as a row gives two authorities for
one fact.

The test is where the fact comes from:

| Fact | Origin | Table? |
|---|---|---|
| A queue exists and binds this handler | `table … : Queue { … handler … }` | **No** — already the declaration |
| A handler named `system.connectors.ldap.sync` exists | compiled-in Haskell | **Yes** — nothing else records it |
| `OrderStatus.Shipped` exists | nowhere else | Yes |
| An external code value a connector met | the external system | Yes, with `Extensible` |
| How often to retry that queue | an operator's judgement | `Configuration`, not `Reference` |

`system.events.Handler` is the case that matters: it is the bridge that makes `handler
system.connectors.ldap.sync` resolve and compile-check against Haskell the schema graph cannot
see. `system.events.Queue` was specified and then removed on this rule — see
[../events.md](../events.md#system-tables).

A `Reference` table may also hold **function literals**, because inserting the row is a schema
transaction. This is what lets templates, render functions, and per-row operations be data
without being uncompiled data. See
[functions.md](functions.md#functions-as-column-values).

### `Extensible`

`Extensible` is a marker trait — no fields, no functions — that permits a `Reference` table
to be extended by an automated process rather than by a schema author:

```
table app.commerce.OrderStatus : Reference, Extensible {
  name : Text unique
}
```

When a connector meets a code value an `Extensible` table does not have, it issues the schema
transaction extending the table — the same operation as
[`extend`](evolution.md#extend-and-shrink-an-adt), performed automatically — and records which connector
and token did it. Without the trait, the unknown value is recorded as a violation instead.
Both land in the same review queue; see [../integrity.md](../integrity.md).

Extension is opt-in because it is not free: every extension is a schema commit that
replicates to every server, so an unthrottled source inventing codes produces schema churn
across the whole cluster. `Extensible` tables are rate-limited per connector.

A marker trait rather than a keyword, because `open` — the obvious keyword — is a plausible
field name, and because extensibility then composes through the trait list that already
exists rather than through a new modifier slot.

## `DocKeys`

`DocKeys` is the shape shared by the key tables generated for every `Doc indexed` field:

```
trait DocKeys : Reference, Extensible {
  name : Text unique
}
```

Key tables are generated per field. See
[documents.md](documents.md#keys-are-interned-per-field).

## Behaviors in traits

A [behavior](types.md#behaviors) closes over the row's stored fields, so a reusable behavior
has to be able to *require* those fields. That is what a trait already does, which is why
behaviors are shared through traits rather than through a behavior-carrying type:

```
trait Accruing {
  principal : Amount,
  rate      : Rate,
  opened_at : Timestamp,

  balance : Behavior Amount = \t -> principal * (1 + rate * (t - opened_at) / day)
}

table app.billing.Loan       : Accruing, UserData { customer :> Customer, ... }
table app.billing.CreditLine : Accruing, UserData { customer :> Customer, ... }
```

A type cannot do this. `type AccruedBalance : Amount` has no way to name `principal` on a
table it has never seen — it would have to demand those fields, and demanding fields is a
trait. Compound interest is therefore written once and extended, and no new mechanism is
needed for it.

A behavior is **not** a fifth functor kind. The four kinds each enforce something: validation
rejects, foreign keys resolve, path constraints assert, events enqueue. A behavior does none
of them — it is a projection, and specifically it is the field-scoped computed type that `:`
already creates at `<namespace>.<table>.<field>`, whose inhabitants happen to be functions of
`Moment`. See [functors.md](functors.md).

Two traits defining the same behavior name is a collision, and **unlike a field collision it
cannot be merged**. A field merge conjoins predicates, which compose; a behavior's content is a
definition, and two definitions do not conjoin — one would have to win, and nothing says which.
The concrete table restates the definition, which supersedes both. The same holds for a `:>`
field inherited from two traits with different targets: there is no conjunction of two target
tables, so the table restates the field and names one.

## UI template hints

Traits can declare UI hints that are stored in system tables and used by the HTML rendering
engine (see [../api-and-rendering.md](../api-and-rendering.md)):

```
trait Card {
  ui { template = "card", density = "compact" }
}
```

The syntax is settled — `ui` is a reserved word and `UiHint` is a `TraitItem`, never a
`BodyItem`, so hints attach to traits only. See
[railroad.md](railroad.md#tables-bindings-traits). What remains open is the hint *vocabulary*:
which keys a theme is obliged to honour, and what a theme does with one it does not recognize.
That is [../api-and-rendering.md](../api-and-rendering.md)'s to settle.
