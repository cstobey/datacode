# Schema Evolution

All previous versions of a table are always present in the transaction graph. "Evolution"
means creating a new schema node, not modifying historical data. See
[../transaction-graph.md](../transaction-graph.md) for the underlying graph model.

## Redeclaring a Table

Redeclare the table body. The system diffs the new declaration against the last version:

- **Column added** → new column; uses field default if provided
- **Column omitted** → deprecated (hidden from queries; data stays in graph)
- **`rename from` hint** → rename (explicit because rename vs. add+remove is ambiguous)
- **Same name** → old type is auto-hidden in the current schema node; still reachable via version tokens
- **Type change** → requires a migration functor (syntax TBD)

```
-- Old Customer had: email, name, status, phone
-- New Customer: renames status, adds loyalty_tier, drops phone
table Customer {
  account_status : AccountStatus rename from status,
  loyalty_tier   : Tier = Bronze
  -- phone omitted → deprecated
}
```

`rename from` is a trailing clause and precedes `unique`, `=`, and `where`:

```
account_status : AccountStatus rename from status = Pending where isKnownStatus
```

## Changing a Validation

Validations are not added or removed by a dedicated statement. Redeclare the field with the
`where` block you want; the diff is taken per address (see
[README.md](README.md#addressing-validations)), so predicates that are unchanged stay put,
new ones are added, and omitted ones are dropped:

```
-- Was: email : Email where isValidEmail
table Customer {
  email : Email
    where
      isValidEmail      -- unchanged
      maxLen 254        -- added
}
```

A predicate inherited from a trait is addressed at its trait path and cannot be dropped by
redeclaring the table — change the trait, or rename the field away from it with
`from A.name`.

## Keeping Old Names

If the redeclaration uses a *different* name, both old and new stay visible. Deprecate the
old one manually when ready.

```
table CustomerV2 { ... }   -- Customer still accessible by name
deprecate Customer         -- hide later when migration is complete
```

## Deprecation and Pruning

```
deprecate Customer          -- hides table; existing views stay alive; data stays in graph
deprecate Customer.phone    -- hide a single field
prune Customer              -- permanently remove data (only valid once no live references remain)
```

## Table Split and Merge

```
split Customer into {
  Person      { name : Text, birth_date : Date },
  ContactInfo { email : Email, phone : Phone | NotGiven }
}

merge Person, ContactInfo into Customer {
  name       : Text,
  birth_date : Date,
  email      : Email,
  phone      : Phone | NotGiven
}
```

Source tables in a split/merge stay visible by default; deprecate them explicitly.

## ADT Extension

Sum types can gain or lose variants after the fact. Removing a variant that has existing
data requires specifying how those rows are migrated.

```
extend Customer.status with Archived

shrink Customer.status removing Archived migrate (\_ -> Closed)
```

## Schema Visibility

Visibility is a presentation hint stored on the schema graph node. Changing it affects the
IDE and PageRank weighting, not query behaviour. See [../namespaces.md](../namespaces.md)
for the level definitions.

```
set visibility app.commerce.Order standard
set visibility connectors.mariadb.production.* connector
```

## Coercion Between Schema Nodes

Because all functors are transparent, the system can derive a coercion path between any two
schema graph nodes:

- Adding a field: old records get `NotFound` for that field
- Removing a field: new records simply don't have it; old records still have it in the historical graph
- Changing a type: a migration functor must be provided that maps old values to new values; it is recorded in the schema graph as an edge

This enables backwards compatibility (old clients read from historical schema nodes), A/B
testing (two schema variants coexist at different graph nodes, data coerced on the fly),
and zero-downtime schema changes (no `ALTER TABLE` locks).
