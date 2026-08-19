# Constraints and Access Control

Data constraints and access control are **the same thing**: an assertion about what is
reachable from a row through the schema graph. Both are written with `assert`, both compile to
a path-constraint functor, and both are analyzable the same way. The only difference is
whether the requesting token is one of the terms.

The two varieties are therefore documented together below. See
[functors.md](functors.md#path-constraints-and-their-two-varieties) for the shared
implementation.

## `where` versus `assert`

The two constraint forms differ in scope and in how they are addressed:

| Form | Scope | Addressed by | Where it appears |
|---|---|---|---|
| `where <predicate>` | one field or type | the field's path — implicit | trailing clause on a type or field declaration |
| `assert <name> { <body> }` | whole row | an explicit name | table body, or standalone |

Both are addressable; they differ only in where the address comes from. A field's `where`
already has a path — `app.commerce.Customer.email` names the computed field type and the
predicates on it — so no name is written. An `assert` spans paths and belongs to no single
field, so it has no path to inherit and must be named.

```
app.commerce.Customer.email      -- a field validation
app.commerce.Order.billingMatch  -- an assert
```

The two forms are addressed uniformly, which is what makes error messages, `:describe`, and
per-path evolution diffs work the same way for both.

See [types.md](types.md) and [tables.md](tables.md) for `where`, and
[README.md](README.md#addressing-validations) for how paths survive trait inheritance.

## The Variety Is Decided by the Body

| | Data constraint | Access constraint |
|---|---|---|
| Recognized by | body does not mention `authed_user` | body mentions `authed_user` |
| Evaluated | on commit | on read **and** write |
| On failure, write | reject the transaction | reject the transaction |
| On failure, read | n/a — not evaluated on read | the row resolves to `Redacted` |
| Skipped by a `bypass access` grant | no | yes |

**The classification is structural, not nominal.** An earlier draft made the assert *name*
`access` select the variety. That was a magic identifier with no lexical status — it could not
be used as an ordinary constraint name, and it was not a reserved word — and worse, it made
admin bypass depend on a naming convention. A perfectly good access rule named `ownerCheck`
would not have been bypassed, and its author would have had no way to tell from the syntax.
Scanning the body for `authed_user` is exact, so `bypass access` has a mechanical definition
rather than a trusted one.

`access` is consequently an ordinary constraint name again, and every assert gets a real name,
which every error message benefits from.

```
table app.pm.Document {
  project :> Project,
  title   : Text,
  unique docTitle { project, title },

  -- data constraint: no authed_user, so commit-time only
  assert liveProject { project.status is not Archived },

  -- access constraint: mentions authed_user, so read and write
  assert memberAccess { self >< Project >< Member >< authed_user }
}
```

### Every Assert Conjoins

Multiple asserts on a table all hold, regardless of variety. There is no special combination
rule for access asserts: each one further restricts, which is what
[../namespaces.md](../namespaces.md#namespace-access-control) already says functors do —
recursion sets the ceiling, functors lower it. An access assert that *widened* access would
invert that.

Alternatives are therefore written with `||` inside one assert, not as separate asserts:

```
assert readableBy {
  self >< Project >< Member >< authed_user
  || self >< Project >< Department >< authed_user via dept_admin
}
```

This also keeps the static completeness analysis tractable — one expression per rule, rather
than a set of rules with unstated combination semantics.

## The Three Shapes

An assert body is an expression, a query, or a boolean combination of the two. That admits
exactly three useful shapes, and the third is the only one that needed anything new.

### Data Match

Ordinary comparison between paths reachable from the row. `==` is exact equality, `is` is
constructor match ignoring payload, `=~` is regex match.

```
-- two FK paths must reach the same address
assert billingMatch { customer.billing_address == bill_addr }

-- the requester's own row decides
assert ownerAccess { authed_user == customer.user }

-- format, against a pattern that is schema or configuration, never input
assert internalOnly { authed_user.email =~ system.config.EmailPolicy.internal_domain }
```

`=~`'s right operand must be a string literal, a `Reference` path, or a `Configuration` path.
A user-supplied value is a compile-time error. See
[railroad.md](railroad.md#functions-and-expressions) for why the three differ and what a
malformed pattern costs in each.

### Presence

A query in assert position asserts that its result is **non-empty**.

```
table app.pm.Document {
  project :> Project,

  -- some Member row links the requester to this document's project
  assert memberAccess { self >< Project >< Member >< authed_user }
}
```

Read it as the reachability question it is: is this document's project joined to a membership
joined to me? The requester enters as a join term, so the equality *is* the join and nothing
has to be spelled out with a comparison. `via` disambiguates when the linking table has two
edges to the same table (`>< authed_user via reviewer`).

Filtering is the query's own `where`, so a narrower rule needs no new construct:

```
assert editorAccess { self >< Project >< (Member where role is Editor) >< authed_user }
```

### Absence

`not` of a query asserts the result is empty.

```
assert payable { not $ self >< Account >< Suspension where lifted is NotLifted }
```

An outer join with a `Null`-derived catch-all expresses the same thing, and it is what
[queries.md](queries.md#outer-joins) already had:

```
assert payable {
  self >< Account >< (Suspension where lifted is NotLifted) | NoSuspension as suspension
    where suspension is NoSuspension
}
```

Both are correct. **Prefer `not` in an assert.** The guard form earns its length in a query or
a view, where the absence is a value you want to project or branch on; in an assert nothing
consumes the variant, and the guard form invites the one mistake that matters:

```
-- WRONG: an account whose every suspension is lifted yields zero rows rather than a
-- NoSuspension row, so this asserts the opposite of what it says
self >< Account >< Suspension | NoSuspension where lifted is NotLifted && suspension is NoSuspension
```

A filter on an outer-joined source must be written inside the join term, and an outer-level
`where` naming a field of an outer-joined source is a compile-time error. This is SQL's
`ON`-versus-`WHERE` trap; here the symptom is not missing rows but an inverted constraint,
which is why the grammar closes it rather than the documentation warning about it.

## Anchoring

> **An assert's query must be rooted at `self`, and every subsequent source must be reached
> by a join along a declared `:>` edge in either direction.**

An unanchored source is a compile-time error. The reason is read cost: an access assert runs
on every read of the row, so an assert free to scan would scan on every read. Anchoring bounds
the work to the row's own connected component, and any number of hops within it is fine — the
constraint is that each hop is an edge, not that there are few of them.

Two things anchoring does *not* buy:

**It does not bound locality.** An FK may point into another shard, and then the check costs a
remote hop per read. That is a warning at schema commit naming the crossing edge, not an
error. The pattern to reach for is putting role and membership tables in the `system` shard,
which is replicated to every server, so the common case costs nothing — see
[../distribution.md](../distribution.md).

**It does not make absence cheap to maintain.** A negative assertion changes truth when a row
is written to a *different* table, so an insert into `Suspension` must revalidate the
`Invoice` rows that reach it. Anchoring is what makes that set findable: it is the FK chain,
traversed backwards. Without it there would be no bound at all.

## Mixed Conjuncts

An assert mentioning `authed_user` is bypassed *whole* by a `bypass access` grant. A conjunct
that does not mention the token is therefore silently bypassed along with the rest:

```
-- an admin bypasses `total >= 0` too, which was not the intent
assert x { authed_user == created_by && total >= 0 }
```

Schema commit **warns** and names the conjunct, with "split into two asserts" as the fix. It is
a warning rather than an error because `||` between a token term and a data term is a
legitimate rule shape — `authed_user.role is Auditor || status is Published` means exactly
what it says.

## Reclassification Is Reported

Adding `|| authed_user.role is Auditor` to an existing data constraint changes it from
write-only to read-and-write and starts redacting rows. That is a schema commit changing read
behaviour on a table without touching a field, so it is reported explicitly in the commit
diff:

```
datacode[app.pm]> :commit
  app.pm.Document.liveProject is now an ACCESS constraint (mentions authed_user).
  It will be evaluated on read, and rows failing it will resolve to Redacted.
```

`:describe` marks which asserts are access-classified for the same reason.

The pattern to avoid: "only the creator may insert, anyone may read" written as an assert.
Mentioning `authed_user` makes it redact on read, which is not what was meant. That belongs on
the field as a default (`created_by :> User = authed_user`), not in an assert.

## Redaction Scope

A failed access assertion on a **read** does not abort the query. An assert is row-scoped, so
what fails is the row, and **every one of its fields resolves to `Redacted`** — including the
key. `Redacted` is a built-in `Null`-derived absence type (see [types.md](types.md)), so the
row's presence in the result is what tells a client "you may not see this" as distinct from
"there is nothing here", and it tells them nothing further.

Exempting key fields was considered and rejected. It reads plausibly — a query that filtered
on the key already knows it — but the case that matters is a scan, where surviving keys would
enumerate the identities of rows the requester may not read. The row-as-opaque-marker already
carries the whole signal the typed absence exists to carry.

A failed access assertion on a **write** rejects the transaction, exactly as a data constraint
does.

## Schema-Level Access and Bypass

Row-level access is what an `assert` mentioning `authed_user` expresses. Two things sit above
it and are configuration in `system.auth.*` rather than syntax:

- **Client scope** — which tables and fields a *client* token may reach at all. A client token
  scoped to `app.commerce` cannot reach `app.hr.*` regardless of what asserts exist there.
  There is deliberately no `authed_client` binding, so this decision lives in one place.
- **Bypass** — a grant may declare that it is not narrowed by row-level access:

  ```
  grant system.auth.Role.Admin on app.pm bypass access
  ```

  Every assert mentioning `authed_user` is skipped for a token holding that grant. Every other
  assert still runs: an administrator is exempt from access control, never from data
  integrity. This is the whole reason the classification had to become structural.

See [../auth.md](../auth.md) and
[../namespaces.md](../namespaces.md#namespace-access-control).

## Standalone Form

Both varieties may be added after the table is already defined, and this is the **only** form
available for a view, which has no body to hold one:

```
assert Order.billingMatch { customer.billing_address == bill_addr }
assert Order.ownerAccess  { self >< Customer >< authed_user }
unique Order.orderRef     { customer, order_num }
```

Fully-qualified names work the same way:

```
assert app.commerce.Order.billingMatch { customer.billing_address == bill_addr }
```

## Events Are Not Assertions

An event registration declares a deferred side effect, not an invariant, so it is not written
with `assert`. It has its own statement:

```
on status is Shipped emit app.events.EmailQueue { recipient = customer.email, ... }
```

`assert` states something that must always hold and can abort a commit. `on … emit` states
something that should happen once a condition starts holding, and can never abort anything —
inserting the queue row *is* the commit. Conflating them was the defect in the earlier
`assert event` placeholder, which this replaces. See [../events.md](../events.md#triggering-an-event).

## Implementation

Both varieties are the same functor kind: path constraint, kind 3, stored as a `FunctorRef`
in the system schema. See [functors.md](functors.md).
