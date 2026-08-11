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
  owner :> system.auth.users,
  claimed_at : Timestamp | Pending
}
```

## Extending a Table from Traits

The `:` operator after the table name declares which traits the table extends. Same
colon-as-"is a kind of" convention used throughout the type system — the right-hand side
here is a list of traits, never types or tables.

```
table app.commerce.Customer : Active, UserData {
  email : Email,
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

Built-in replication traits are regular traits — user-defined traits can extend them
freely:

```
trait Catalog : Reference {
  is_visible : Bool = True
}

table app.commerce.Product : Catalog, Active {
  name  : Text,
  price : Amount
}
-- Product replicates to all servers (inherits Reference via Catalog)
```

Having multiple replication base traits in a single inheritance hierarchy is a compile-time
error.

See [../distribution.md](../distribution.md) for what each replication policy means
operationally.

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
[`extend`](evolution.md#adt-extension), performed automatically — and records which connector
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

## UI Template Hints

Traits can declare UI hints that are stored in system tables and used by the HTML rendering
engine (see [../api-and-rendering.md](../api-and-rendering.md)):

```
trait Card {
  ui { template = "card", density = "compact" }
}
```

Exact syntax for UI hints is TBD.
