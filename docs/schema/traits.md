# Traits

Traits are abstract table types. They cannot be instantiated directly — they are extended
by concrete tables. A trait adds fields, functions, replication policy, and (optionally) UI
template hints to every table that extends it.

## Declaring a Trait

```
trait Active {
  is_active : ActiveStatus | InactiveStatus,

  -- Functions defined in a trait are available on any table extending it
  active   self = self where is_active is ActiveStatus,
  inactive self = self where is_active is InactiveStatus
}
```

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
  owner :> system.auth.User,
  claimed_at : Timestamp | Pending
}
```

## Extending a Table from Traits

The `:` operator after the table name declares which traits the table extends. Same
colon-as-"is a kind of" convention used throughout the type system — the right-hand side
here is a list of traits, never types or tables.

```
table app.commerce.Customer : Active, UserData {
  email : Email unique,
  name  : Text
}

-- active/inactive functions now work on Customer
active (app.commerce.Customer where email is not NotGiven)
```

## Multiple Inheritance

Tables may extend multiple traits. If two traits define a field with the same name, the
concrete table must resolve the conflict explicitly:

```
trait A { name : Text where isNotEmpty }
trait B { name : Text where maxLen 100 }

-- Keep both fields separately: rename A's field
table Foo : A, B {
  a_name : Text from A.name   -- rename; keeps A's validations; B's name unchanged
}

-- Or merge into one field: inherits validations from both A and B
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

`from A.name` in the rename form uses the same path syntax, which is why renaming keeps the
originating trait's validations rather than dropping them. See
[README.md](README.md#addressing-validations).

## Replication Traits

The shard types map to built-in traits. Tables declare their replication policy by
extending one of these.

| Trait | Replication | Cardinality |
|---|---|---|
| `Reference` | All servers | Low–medium |
| `Configuration` | All servers | Medium |
| `UserData` | Shard-local | High |
| `LogData` | Server-local, prunable | Very high |
| `Component` | Wherever the parent is | Bounded by the parent |

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

Built-in replication traits are regular traits — user-defined traits can extend them
freely:

```
trait Catalog : Reference {
  is_visible : Bool = True
}

table app.commerce.Product : Catalog, Active {
  name  : Text unique,
  price : Amount
}
-- Product replicates to all servers (inherits Reference via Catalog)
```

Having multiple replication base traits in a single inheritance hierarchy is a compile-time
error.

See [../distribution.md](../distribution.md) for what each replication policy means
operationally.

## Traits Are Not Configuration

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

It is a member of the replication-trait family rather than a separate axis, because a
component's replication policy genuinely is determined: it must be wherever its parent is.
The existing "one replication base trait per hierarchy" rule therefore applies unchanged, and
`table T : Component, UserData` is an error for exactly the reason `UserData, LogData` is.

```
table app.commerce.Customer : UserData {
  email   : Email unique,
  address :> Address {           -- inline sub-table, as always
    street : Text,
    city   : Text,
    zip    : Zip
  }
}

table app.commerce.Address : Component { ... }   -- the generated sibling
```

### What `Component` Changes

**Identity.** A component row has no `DataId`. It is identified by its parent's identifier
plus a 4-byte `Ordinal`, and only the ordinal is stored — the timestamp, server node, and
sequence are inherited through the containment link. The parent reference therefore costs
zero bytes, because the parent *is* the identifier prefix. See
[../transaction-graph.md](../transaction-graph.md#component-ordinals).

The inheritance shows up in the virtual columns: `created_at` and `origin_server` come from
the parent, since a component has no identifier bytes of its own beyond its ordinal. In
exchange it gains a fourth, **`ordinal`** — its position under that parent, at its own nesting
level — which is how document order is stated in a query rather than merely received from a
range scan. See [tables.md](tables.md#basic-syntax).

**Locality.** A component is always in its parent's shard. Ordinal assignment is a
read-modify-write against the parent's current maximum, which needs no coordination because
the shard primary linearizes writes. This is the invariant that makes the compact identifier
sound rather than merely small.

### Invariants

| Rule | Reason |
|---|---|
| A component cannot be reparented | The parent is the identifier; moving it would change its identity |
| Nothing outside the parent's subtree may reference a component | Otherwise the subtree is not wholly dependent and cannot be pruned as a unit |
| A component may reference outward freely | An outbound FK creates no inbound dependency |
| Pruning the parent prunes the subtree | Composition; the subtree is orphaned by definition |
| At most 2^32 components per parent | Overflow is a schema design error, not a runtime condition, and is rejected |

Components are versioned and updated like any other row — a 1:1 component such as an address
is edited normally, producing a new version under the same ordinal. What is forbidden is
moving one, not changing one.

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

It is not a replication trait and occupies no slot; it composes with whichever one the table
already carries.

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

It is not a replication trait and occupies no slot. What it changes is what history returns
after an `erase`: on an ordinary table a tombstoned row stays readable at earlier sample
moments, and on a `Personal` table an erased row reads `Erased` at every moment unless the token
holds `bypass erasure`.

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

Beyond that field the trait body is empty, because what makes a queue a queue is four rules
about field *types*, and the grammar has no way to say "a foreign key to any table carrying
trait X". They are checked at schema commit:

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

The `QueueState` field is the **one exemption from append-only in the whole system**, and it is
narrow: one field, on a `Queue` table, written only by the handler bound to that queue. That
exemption is what makes a queue row pollable by a client — it reads a domain-meaningful state
(`Bound`, `Applied`) while the scheduler reads that state's `disposition`. Anything else needing
a record after the fact goes in its own `LogData` table with a `:>` back to the queue row, which
is what the [attempt history](../events.md#attempt-history) is.

`handler` was previously valid on any `LogData` table and is now valid only on a `Queue`. A log
is not a work list. Full treatment in [../events.md](../events.md#queue-tables).

## `Reference` Tables Are Code

`Reference` has always been described as "code tables, treated as code, propagated
everywhere". That is meant literally: **inserting a row into a `Reference` table is a schema
transaction**, committed to the schema graph in the `system` shard, not a data transaction.

Four consequences:

- **A field referencing a `Reference` table stores a 2-byte variant tag**, not a 12-byte
  `DataId`. On a billion-row table with three code fields that is 30 GB.
- **`is` against a `Reference` row is checked at schema-commit time.** `status is Shipped`
  fails to compile if no row named `Shipped` exists at that schema node, so a mistyped code
  name is a compile error rather than a query that silently returns nothing.
- **Variant tags are assigned monotonically and never reused.** `shrink` tombstones a tag
  rather than renumbering, because renumbering would silently change the meaning of every
  historical row.
- **Past 65 535 variants the table is not a code table.** This is rejected at commit with
  that diagnostic, which gives the "low–medium cardinality" guidance actual teeth.

The token does not change. A field referencing a `Reference` table is still declared with
`:>`, still carries an FK functor, and still adds an edge to the join graph — the FK functor
simply resolves a tag instead of a `DataId`. The
[`:` versus `:>` rule](README.md#-versus-) is load-bearing and stays exactly as it is; every
benefit above is a storage and checking change underneath it.

### When a `Reference` Table Is Warranted

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

## Behaviors in Traits

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

Behaviors merge across multiple inheritance the same way fields do: two traits defining the
same behavior name is a conflict the concrete table must resolve, by rename or by
redeclaration.

## UI Template Hints

Traits can declare UI hints that are stored in system tables and used by the HTML rendering
engine (see [../api-and-rendering.md](../api-and-rendering.md)):

```
trait Card {
  ui { template = "card", density = "compact" }
}
```

Exact syntax for UI hints is TBD.
