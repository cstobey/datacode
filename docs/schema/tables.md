# Table Definitions

See [README.md](README.md) for the `:` / `:>` rule, clause order, `where`, and the
termination and layout rules assumed here.

## Basic Syntax

```
-- DataId primary key is always implicit — no declaration needed
-- Namespace created implicitly on first use
table app.commerce.Customer {
  email        : Email,
  name         : Text,
  status       : Active | Suspended | Closed,
  phone        : Phone | NotGiven,
  loyalty_tier : Tier = Bronze      -- field default with =
}
```

Field declarations are separated by `,`; the body is closed by `}`. A comma before the
closing `}` is permitted. Where any field carries a block `where`, put the separator at the
start of the next declaration instead — see below.

Every table has two automatic virtual columns:

- `created_at` — timestamp extracted from the row's `DataId`
- `updated_at` — timestamp of the most recent `PhysicalLocator` that mutated the row

`PhysicalLocator` (the physical address of one row version) is internal only and not exposed
in the schema DSL. See [../transaction-graph.md](../transaction-graph.md).

A table carrying the `Component` trait has no `DataId` of its own; its rows are identified by
the parent's identifier plus an `Ordinal`, and `created_at` is inherited from the parent. See
[traits.md](traits.md#component).

## Field Declarations

A field declaration is a name, a type token, a type, and up to five trailing clauses in a
fixed order:

```
field ( ":" | ":>" ) Type [ rename from Old | from Source ] [ unique ] [ indexed ] [ = Default ] [ where Predicate ]
```

```
table app.commerce.Order {
  loyalty_tier : Tier   = Bronze,
  name         : Text   = "Unknown",
  is_active    : Bool   = True,
  email        : Email  unique where isCorporateDomain,
  total        : Amount = 0 where \a -> a >= 0
}
```

The default precedes `where` so that an `=` inside the predicate is never mistaken for a
field default.

`indexed` sits beside `unique` because both are storage hints rather than parts of the
field's meaning. It is currently valid only on a `Doc` field, where it requests the shredded
form — see [documents.md](documents.md#storage-bytes-first-shredded-second).

### Validation Blocks

One `where` per field. Several predicates go in an indented block beneath it, implicitly
conjoined. Use leading commas so the separator does not strand itself after the block:

```
table app.commerce.Customer {
  email : Email unique
    where
      isValidEmail
      maxLen 254
      \e -> not (isDisposableDomain e)
  , name : Text
    where isNotEmpty
  , phone : Phone | NotGiven
}
```

A field's validation is addressed by the field's path —
`app.commerce.Customer.email` denotes both the computed field type and the predicates on it.
There is no separate name for it. See
[README.md](README.md#addressing-validations).

## Uniqueness Constraints

```
-- Single-field: `unique` keyword suffix
email : Email unique

-- Multi-field: named constraint in table body
table Order {
  customer  :> Customer,
  order_num : Int,
  unique orderRef { customer, order_num }
}

-- Standalone post-definition (add after table exists)
unique Order.orderRef { customer, order_num }
```

Multiple unique constraints per table are all enforced. `DataId` remains the primary key;
unique constraints define natural keys used for fast lookup.

## Default Ordering

```
table Order {
  placed_at : Timestamp,
  total     : Amount,
  order by placed_at desc    -- default ordering for queries against this table
}
```

System default (if no `order by` declared): unique key ascending. Overridable per-query.

## Foreign Keys

`:>` declares a field that references a row in another table. It creates a field-scoped
type (`namespace.table.field`) wrapping the referenced table's `DataId`, attaches an FK
functor (kind 2 — see [functors.md](functors.md)), and adds an edge to the join graph used
by `><`.

```
table app.commerce.Order {
  customer  :> Customer,      -- FK to Customer; creates Order.customer type
  placed_at : Timestamp,
  total     : Amount
}
```

`:>` is required whenever the head of the type expression names a table or view. Writing
`customer : Customer` is a compile-time error, as is `email :> Email` where `Email` is a
type.

### Nullable and Fallback References

The head rule allows absence types and further tables in the tail:

```
-- Reference may be absent; the reason is typed
table app.commerce.Order {
  customer :> Customer | MissingCustomer
}

-- Fallback chain: resolve against Customer, else HistoricalCustomer, else absent
table app.commerce.Order {
  customer :> Customer | HistoricalCustomer | MissingCustomer
}
```

The field's type is the full sum. The FK functor applies only to the table variants;
`Null`-derived variants carry no reference and always match. This mirrors outer-join guard
semantics exactly — see [queries.md](queries.md).

### Multiple References to One Table

Two `:>` fields may target the same table. Queries must then name the path explicitly with
`via` (see [queries.md](queries.md)):

```
table app.commerce.Shipment {
  origin      :> Warehouse,
  destination :> Warehouse
}
```

## Inline Sub-Tables

Defining a table inline inside a field declaration creates the sub-table as a sibling in
the parent's namespace, and makes the field a reference to it. The token is therefore `:>`:

```
-- Creates app.commerce.Address as a sibling table;
-- Customer.address references a row in it
table app.commerce.Customer {
  address :> Address {
    street : Text,
    city   : Text,
    zip    : Zip
  }
}
```

There is no embedded product-in-row. An inline sub-table is sugar for "declare a sibling
table, then reference it", and `:>` states that plainly. The two forms below are equivalent:

```
table app.commerce.Customer {
  address :> Address { street : Text, city : Text, zip : Zip }
}
```

```
table app.commerce.Address {
  street : Text,
  city   : Text,
  zip    : Zip
}

table app.commerce.Customer {
  address :> Address
}
```

To place the sub-table in a different namespace, use a fully-qualified name in the inline
definition.

### Component Sub-Tables

A sub-table that has no independent existence — it is created with its parent, lives in the
parent's shard, and is destroyed with it — declares the `Component` trait. Its rows are then
identified relative to the parent by an `Ordinal` rather than getting a `DataId` of their
own, and the reference back to the parent costs no bytes at all:

```
table app.log.Request : LogData {
  received_at : Timestamp,
  headers    :> RequestHeader : Component {
    name  : Text,
    value : Text
  }
}
```

`Component` is a replication trait, so it occupies the same slot as `UserData` or `LogData`
and cannot be combined with one. Full treatment, including the invariants that make the
compact identifier sound, is in [traits.md](traits.md#component).

## Constraints and Access Control

Table bodies may contain `assert` blocks alongside field declarations, separated the same
way. Full treatment in [constraints.md](constraints.md):

```
table Order {
  customer  :> Customer,
  bill_addr :> Address,

  assert billingMatch { customer.billing_address == bill_addr },
  assert access       { user.id == customer.user_id }
}
```

## Traits

The `:` after the table name declares which traits the table extends. Full treatment in
[traits.md](traits.md):

```
table app.commerce.Customer : Active, UserData {
  email : Email unique,
  name  : Text
}
```
