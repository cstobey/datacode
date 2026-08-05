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

## UI Template Hints

Traits can declare UI hints that are stored in system tables and used by the HTML rendering
engine (see [../api-and-rendering.md](../api-and-rendering.md)):

```
trait Card {
  ui { template = "card", density = "compact" }
}
```

Exact syntax for UI hints is TBD.
