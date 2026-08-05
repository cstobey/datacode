# Constraints and Access Control

Data constraints and access control are **the same thing**: an assertion that two paths
through the schema graph resolve to the same value. Both are written with `assert`, both
compile to a path-equivalence functor, and both are analyzable the same way. The only
difference is what the two path terms refer to — two data paths, or the requesting token and
a data path.

The two varieties are therefore documented together below. See
[functors.md](functors.md#path-equivalence-and-its-two-varieties) for the shared
implementation.

## `where` versus `assert`

The two constraint forms differ in scope and in how they are addressed:

| Form | Scope | Addressed by | Where it appears |
|---|---|---|---|
| `where <predicate>` | one field or type | the field's path — implicit | trailing clause on a type or field declaration |
| `assert <name> { <expr> }` | whole row | an explicit name | table body, or standalone |

Both are addressable; they differ only in where the address comes from. A field's `where`
already has a path — `app.commerce.Customer.email` names the computed field type and the
predicates on it — so no name is written. An `assert` spans two paths and belongs to no
single field, so it has no path to inherit and must be named.

```
app.commerce.Customer.email      -- a field validation
app.commerce.Order.billingMatch  -- an assert
```

The two forms are addressed uniformly, which is what makes error messages, `:describe`, and
per-path evolution diffs work the same way for both.

See [types.md](types.md) and [tables.md](tables.md) for `where`, and
[README.md](README.md#addressing-validations) for how paths survive trait inheritance.

## The Two Varieties

| | Data constraint | Access control |
|---|---|---|
| Written | `assert <name> { p == q }` | `assert access { user.x == q }` |
| Left term | a data path from the row | the requesting user token |
| Evaluated | on commit | on read **and** write |
| On failure, write | reject the transaction | reject the transaction |
| On failure, read | n/a — not evaluated on read | field resolves to `Redacted` |

The name `access` is what selects the access-control variety. Any other name is a data
constraint.

```
table Order {
  customer  :> Customer,
  bill_addr :> Address,

  -- Data constraint: two paths must reach the same address
  assert billingMatch { customer.billing_address == bill_addr },

  -- Access control: requesting user must be reachable from this row
  assert access { user.id == customer.user_id }
}
```

`user` refers to the requesting user token. The exact fields exposed on it (full user row
vs. just `user.id`) are TBD — see [../auth.md](../auth.md).

A failed access assertion on a **read** does not abort the query. The field resolves to
`Redacted`, a built-in `Null`-derived absence type (see [types.md](types.md)), so a client
can distinguish "you may not see this" from "there is nothing here". A failed access
assertion on a **write** rejects the transaction, exactly as a data constraint does.

## Schema-Level Access

Row-level access is what `assert access` expresses. Schema-level access — which tables and
fields a *client* token may reach at all — is configured in `system.auth.*` tables, not with
`assert`. A client token scoped to `app.commerce` cannot reach `app.hr.*` regardless of what
row-level `assert access` rules exist there. See [../auth.md](../auth.md).

## Standalone Form

Both varieties may be added after the table is already defined:

```
assert Order.billingMatch { customer.billing_address == bill_addr }
assert Order.access       { user.id == customer.user_id }
unique Order.orderRef     { customer, order_num }
```

Fully-qualified names work the same way:

```
assert app.commerce.Order.billingMatch { customer.billing_address == bill_addr }
```

## Event Assertions — Syntax TBD

`assert event` links a queue table to the connector functor that processes it:

```
table app.events.email_queue {
  recipient : Email,
  template  : EmailTemplate,
  payload   : JsonObject,
  assert event { system.connectors.email.SendFunctor }
}
```

**This form is a placeholder.** An event registration is not an assertion — it declares a
deferred side effect, not an invariant — and this syntax carries no trigger condition, queue
binding, or retry policy. The event functor is a real and settled part of the model; only
its surface syntax is outstanding. See [../events.md](../events.md) and
[functors.md](functors.md#event-functor).

## Implementation

Both varieties are the same functor kind: path equivalence, kind 3, stored as a
`FunctorRef` in the system schema. See [functors.md](functors.md).
