# Constraints and access control

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

## The variety is decided by the body

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

**The scan covers the assert body and nothing else, and that is what makes it exact.**
`authed_user` is bound in no other position an assert can reach — see
[railroad.md](railroad.md#contextual-bindings). Admitting it into function scope would turn a
one-body test into a whole-call-graph analysis, and both failure directions are silent. A rule
written as `assert x { isOwner self }`, with the token mentioned inside `isOwner`, would
classify as a data constraint: never evaluated on read, so the row is never redacted, and not
skipped by `bypass access`, so an administrator is blocked by a rule that is in fact access
control.

```
table app.pm.Document : UserData {
  project :> Project,
  title   : Text,
  unique docTitle { project, title },

  -- data constraint: no authed_user, so commit-time only
  assert liveProject { project.status is not Archived },

  -- access constraint: mentions authed_user, so read and write
  assert memberAccess { self >< Project >< Member >< authed_user }
}
```

### Every assert conjoins

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

This also keeps the static analysis tractable — one expression per rule, rather than a set of
rules with unstated combination semantics.

## The three shapes

An assert body is an `Expr`. A query reaches it as an ordinary atom and denotes its
non-emptiness in any `Bool` position, so the body may be an expression, a query, or any
boolean combination of the two. That admits exactly three useful shapes.

The grammar took a widening to get here. It previously read `AssertBody ::= Expr | Query`,
which admitted a query *or* an expression and never a query *inside* an expression — so the
`||` above did not derive, and neither did the absence shape below. Lifting "a query in a
`Bool` position asserts non-empty" out of assert position and into every `Bool` position
repairs both and retires `AssertBody` entirely. See
[railroad.md](railroad.md#functions-and-expressions).

### Data match

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

The body is a query, and a query asserts that its result is **non-empty**.

```
table app.pm.Document : UserData {
  project :> Project,

  -- some Member row links the requester to this document's project
  assert memberAccess { self >< Project >< Member >< authed_user }
}
```

Read it as the reachability question it is: is this document's project joined to a membership
joined to me? The requester enters as a join term, so the equality *is* the join and nothing
has to be spelled out with a comparison.

`authed_user` is a row, not a table, so `>< authed_user` is the join along the declared `:>`
edge to `system.auth.User` restricted to that one row — at most one match per left row. `via`
names the edge when the linking table has more than one (`>< authed_user via reviewer`). The
join itself is [queries.md](queries.md#joining-against-the-reference-direction)'s, and `as` is
not needed here because an assert never names the source.

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
a projection, where the absence is a value you want to project or branch on; in an assert
nothing consumes the variant, and the guard form invites the one mistake that matters:

```
-- WRONG: an account whose every suspension is lifted yields zero rows rather than a
-- NoSuspension row, so this asserts the opposite of what it says
self >< Account >< Suspension | NoSuspension as suspension
  where lifted is NotLifted && suspension is NoSuspension
```

A filter on an outer-joined source belongs inside the join term; the rule and its diagnostic
are [queries.md](queries.md#filter-before-guard)'s. What is specific to an assert is the
symptom. In a query the mistake costs missing rows, which a reader notices; in an assert it
costs a constraint that enforces the opposite of what it reads as, which nobody notices. That
is why the grammar closes it rather than the documentation warning about it.

## Anchoring

> **An assert's query must be rooted at `self`, and every subsequent source must be reached
> by a join along a declared `:>` edge in either direction.**

An unanchored source is a compile-time error. The reason is read cost: an access assert runs
on every read of the row, so an assert free to scan would scan on every read. Anchoring bounds
the work to the row's own connected component, and any number of hops within it is fine — the
constraint is that each hop is an edge, not that there are few of them.

**Assert evaluation is part of the access decision, not a client read**, so it does not itself
apply access asserts. The alternative deadlocks: a requester who may not read `Member` could
never satisfy any assert traversing it, and two tables guarding each other would deny both. The
price is that an assert body is an authorization-relevant surface — it can observe rows its
author's token cannot — and the anchoring rule is what bounds what it observes.

An erased row is the exception, because erasure is a restriction on *processing* and evaluating
an assert is processing. Its fields resolve to `Erased` for an assert traversal exactly as for
any other read, so an assert depending on them fails and the row redacts. See
[../integrity.md](../integrity.md#erasure-restricts-scrub-destroys).

Two things anchoring does *not* buy:

**It does not bound locality.** An FK may point into another shard, and then the check costs a
remote hop per read. Schema commit warns and names the crossing edge, and the attachment is
restricted to `enforce forward`, `monitor`, or `repair into` — never `enforce always`, because
a constraint whose revalidation set is in another shard cannot promise to reject the write that
breaks it. The breach surfaces as a `system.integrity.Violation` instead. The commit is not
refused; the declared mode is what it cannot keep. See
[../distribution.md](../distribution.md#constraints-that-cross-shards-cannot-promise-enforce-always).
The pattern to reach for is the `Reference` trait on the role and policy tables an access rule
traverses: a `Reference` row is schema, replicated to every server, so those hops cost nothing.
A membership table is genuine user data and stays `UserData`; keep it rooted at the same shard
root the rule starts from and the traversal is shard-local.

**It does not make absence cheap to maintain.** A negative assertion changes truth when a row
is written to a *different* table, so an insert into `Suspension` must revalidate the
`Invoice` rows that reach it. Anchoring is what makes that set findable: it is the FK chain,
traversed backwards. Without it there would be no bound at all.

## Mixed conjuncts

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

The warning is also the honest statement of the boundary. A `bypass access` grant is exempt
from every assert that mentions `authed_user` and from no other assert, which is not quite the
same as "exempt from access control, never from data integrity" — the intent — because a data
term sharing an assert with a token term goes with it. Splitting the assert is what makes the
intent true.

## Reclassification is reported

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
the field as a default (`created_by :> User = authed_user`), not in an assert — on a new table
or a new field of an empty one. A field **added to a populated table** may not default to
`authed_user`: the default would resolve on the read path, to whoever is reading, so
`created_by` would differ between two readers of one row. See
[evolution.md](evolution.md#redeclare-a-table).

## Redaction scope

A failed access assertion on a **read** does not abort the query. An assert is row-scoped, so
what fails is the row, and **every one of its fields resolves to `Redacted`** — including the
key. `Redacted` is a built-in `Null`-derived absence type (see
[types.md](types.md#absence-types)), so the row's presence in the result is what tells a client
"you may not see this" as distinct from "there is nothing here", and it tells them nothing
further.

Exempting key fields was considered and rejected. It reads plausibly — a query that filtered
on the key already knows it — but the case that matters is a scan, where surviving keys would
enumerate the identities of rows the requester may not read. The row-as-opaque-marker already
carries the whole signal the typed absence exists to carry.

Key *eligibility* is judged on the declared type, not on what a read may return, and the two do
not collide: a redacted row is excluded from key-identified lookup rather than presenting a
`Redacted` key to match against. So `unique` still rejects a `Null`-derived variant in a
declared key ([tables.md](tables.md#ineligible-key-fields)) and no derived key degenerates
because of who is asking. The read-side widening — which absence variants a field can yield
that its declaration does not name — is [types.md](types.md#absence-types)'s.

How a redacted row behaves inside an aggregate, a `group`, an `order by`, or a materialized
view is query semantics and belongs to [queries.md](queries.md).

A failed access assertion on a **write** rejects the transaction, exactly as a data constraint
does.

## Schema-level access and bypass

Row-level access is what an `assert` mentioning `authed_user` expresses. Two things sit above
it, and neither is syntax:

- **Client scope** — which tables and fields a client token may reach at all is decided by its
  `system.auth.Client` row, not by an assert. See
  [../auth.md](../auth.md#schema-level-access-and-bypass).
- **Bypass** — a grant may declare that row-level access does not narrow it. `bypass access`
  skips every assert mentioning `authed_user` and nothing else; `bypass erasure` is the second,
  independent kind. See [../namespaces.md](../namespaces.md#bypass).

**There is deliberately no `authed_client` binding.** Which rows a request may reach is what an
assert decides; what a client kind may reach at all is what a `Client` row decides. Admitting
the client into an assert body would put one decision in two places, and every version that
tried it opened a fail-open path.

## Standalone form

Both varieties may be added after the table is already defined, and this is the **only** form
available for a derived table, which has no body to hold one:

```
assert Order.billingMatch { customer.billing_address == bill_addr }
assert Order.ownerAccess  { self >< Customer >< authed_user }
unique Order.orderRef     { customer, order_num }
```

Fully-qualified names work the same way:

```
assert app.commerce.Order.billingMatch { customer.billing_address == bill_addr }
```

The standalone and in-body forms share one body grammar, which is what gives a derived table
the full range. A presence or access assert on a binding was unwritable while the standalone
production admitted only an expression:

```
app.commerce.OpenOrder = Order where status is Pending

assert app.commerce.OpenOrder.ownerAccess { self >< Customer >< authed_user }
```

## Events are not assertions

An event registration declares a deferred side effect, not an invariant, so it is not written
with `assert`. It has its own statement:

```
on status is Shipped emit app.events.EmailQueue { recipient = customer.email }
```

`assert` states something that must always hold and can abort a commit. `on … emit` states
something that should happen once a condition starts holding, and can never abort anything —
inserting the queue row *is* the commit. Conflating them was the defect in the earlier
`assert event` placeholder, which this replaces. See [../events.md](../events.md#triggering-an-event).

## Implementation

Both varieties are the same functor kind: path constraint, kind 3, stored as a `FunctorRef`
in the system schema. See [functors.md](functors.md).
