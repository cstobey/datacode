# Functor Types

This is the operational reference. For why there are four kinds and why access control is a
variety of path constraint rather than a kind of its own, see
[../category-model.md](../category-model.md).

DataCode has four functor kinds. All four are first-class schema objects — defined as rows
in system tables, referenced by `FunctorRef`, and encoded in the GADT DSL (confirmed in
`spikes/dynamic-loading/output.txt`).

| # | Kind | Signature | When it runs | Purpose |
|---|---|---|---|---|
| 1 | **Validation** | `a → Either Error a` | On commit | Rejects invalid field values (range checks, format checks, domain invariants) |
| 2 | **Foreign key** | `DataId → Either Error Row` | On commit | Referential integrity — resolves a DataId to a live row in the referenced table |
| 3 | **Path constraint** | `Row → Either Error ()` | See below | Asserts something about what is reachable from a row through the schema graph. Comes in two varieties: data constraint and access constraint |
| 4 | **Event** | `a → EventRef` | On commit, or on a tick | Schedules a deferred side effect — enqueues a work item in a DataCode queue table rather than executing immediately |

Kinds 1–3 are synchronous and transactional: they run as part of the commit and can abort
it. Kind 4 is asynchronous and decoupled: the commit always succeeds (inserting the queue
row is the commit), and the side effect runs later under the event scheduler.

All four are `Read` or `Tx` — none of them may call out. The **handler** a queue names is not a
fifth kind and is not a functor at all: it runs in `Effect`, outside the commit, and is
compiled-in Haskell rather than a DSL term. That is why it can be arbitrary Haskell when
functors cannot — it needs none of transparency, static access analysis, or replayability. See
[functions.md](functions.md#the-effect-ladder) and [../events.md](../events.md#handlers).

**A [behavior](types.md#behaviors) is not a fifth kind.** Each kind above enforces something —
validation rejects, foreign keys resolve, path constraints assert, events enqueue. A behavior
does none of them; it is a projection, and specifically the field-scoped computed type that
`:` already creates, whose inhabitants are functions of `Moment`. It becomes relevant to
functors only as the subject of an event condition.

## Surface Syntax Mapping

| Kind | Written as | Documented in |
|---|---|---|
| Validation | `where <predicate>` on a type or field | [types.md](types.md), [tables.md](tables.md) |
| Foreign key | `:>` field declaration | [tables.md](tables.md) |
| Path constraint — data | `assert <name> { … }`, body without `authed_user` | [constraints.md](constraints.md) |
| Path constraint — access | `assert <name> { … }`, body with `authed_user` | [constraints.md](constraints.md) |
| Event — transition | `on <condition> emit <queue> { <payload> }` | [../events.md](../events.md) |
| Event — sampled | `every <interval> emit <queue> { <payload> } where <condition>` | [../events.md](../events.md) |

## Order of Operations for a Field Write

Functors are attached at different granularities and must run in a fixed order, because a
type may apply a storage transform that later stages must not see behind.

1. **Coerce** the supplied value to the field's declared type.
2. **Validate** — run the field's `where` predicates, in address order, against the *input*
   value. For a `Hashed` field this is the plaintext, and it is the only stage that sees it.
3. **Decide** — on failure, the attachment's enforcement mode decides whether the transaction
   is rejected or the value is accepted and recorded as a violation (below).
4. **Transform** — apply the type's storage transform: hash the value, intern a document key,
   resolve a `Reference` name to its variant tag. Only now.
5. **Encode** into the transaction's mutation list. Nothing that the transform removed can
   reach the log, because the log is written from this point forward.
6. **Resolve foreign keys** and check `unique` constraints across the row.
7. **Evaluate path constraints** — `assert` blocks, both varieties, across the affected
   subgraph. Anchoring is what makes "the affected subgraph" a finite thing to name: every
   assert is rooted at a row and reaches only along `:>` edges, so writing a row determines
   which asserts on which other rows must be revisited by traversing those edges backwards.
8. **Fire event functors** whose condition transitioned from `False` to `True` across this
   write, and re-solve any behavior-triggered condition on the row, since writing the row
   changes the function the crossing was solved from. Both insert queue rows and can abort
   nothing.

Step 2 before step 4 is the substantive constraint. Validating after the transform would mean
validating a digest, which is meaningless, and steps 4 and 5 in that order are what make
"the plaintext never enters the transaction log" a structural property rather than a
convention. See [types.md](types.md#hashed-types).

## Enforcement Modes

A functor's *attachment* to a field or table carries an enforcement mode, which determines
what step 3 above does and what happens to rows that already violate:

| Mode | Violating write | Rows that already violate |
|---|---|---|
| `enforce always` | reject | recorded |
| `enforce forward` | reject | recorded, otherwise untouched |
| `monitor` | accept | recorded |
| `repair into <queue>` | accept | recorded and enqueued for remediation |

The mode is declared by a separate statement addressed at the validation, not by a clause
inside the `where` block, and stating one is **mandatory** when a predicate is added to a
field that already has rows. Full treatment, including the violations table and why the flag
cannot live on the row, is in [../integrity.md](../integrity.md).

## Signature Restrictions on `Secret` Types

A validation functor attached to a field whose type is `Secret` — which every `Hashed` type
is — admits only the `a -> Bool` signature. `a -> Either Error a` and `a -> Maybe b` are
rejected at schema commit, because their failure channels can carry the value itself out into
an error payload and thence into the append-only log. See
[types.md](types.md#secret-types).

## Path Constraints and Their Two Varieties

Data constraints and access control are the same functor. Both assert something about what is
reachable from a row through the schema graph; both are written with `assert`; both compile to
the same `Row → Either Error ()` shape. The only difference is **whether the requesting token
is one of the terms**, and that difference is what produces the differing runtime behaviour:

| | Data constraint | Access constraint |
|---|---|---|
| Recognized by | body without `authed_user` | body mentioning `authed_user` |
| Evaluated | on commit | on read **and** write |
| On failure, write | reject the transaction | reject the transaction |
| On failure, read | n/a — not evaluated on read | row resolves to `Redacted` |
| Skipped by `bypass access` | no | yes |

```
table app.commerce.Order {
  customer  :> Customer,
  bill_addr :> Address,
  order_num : Int,

  unique orderRef { customer, order_num },

  -- Data constraint: two FK paths must reach the same address
  assert billingMatch { customer.billing_address == bill_addr },

  -- Access constraint: the requester must be reachable from this row
  assert ownerAccess { authed_user == customer.user }
}
```

**The classification is structural.** An earlier draft made the assert *name* `access` select
the variety; that made the set of rules an administrator bypasses depend on a naming
convention, and it burned an identifier that was not even reserved. Scanning the body for
`authed_user` is exact. See [constraints.md](constraints.md#the-variety-is-decided-by-the-body).

The signature widened from `(a, a) → Either Error ()` at the same time. Equality of two paths
is one shape an assert body can take; a query in assert position asserts its result is
non-empty, and `not` of one asserts it is empty. Those cover presence and absence, which the
equality-only shape could not express at all — every path in the schema graph is single-valued
by construction, so there was nothing to quantify over. Equality is now the case where the
body is an expression rather than a query.

Because both varieties are the same object, the analyses that apply to one apply to the
other: access rules can be checked statically for consistency and completeness the same way
data constraints can, and both render as edges in the IDE's ER diagram (see
[../ide.md](../ide.md)).

Redaction on read is where the two diverge operationally. A failed access assertion on a
read does not abort — the row resolves to `Redacted`, a built-in `Null`-derived absence type
(see [types.md](types.md)). Absence is typed, so the client can distinguish "you may not see
this" from "there is nothing here".

## Event Functor

An event functor is registered on the producing table with `on … emit`, and the queue that
receives the work item declares its own processor with `handler`:

```
on status is Shipped emit app.events.EmailQueue { recipient = customer.email, ... }
```

**The condition fires on a `False` → `True` transition, never on merely being true.** For a
condition over stored fields the transition is observed across the write. For a condition over
a closed-form [behavior](types.md#behaviors) there is no write to observe, so the scheduler
solves for the moment the condition becomes true and wakes then — which is why behaviors are
restricted to a closed-form-solvable class. See
[../events.md](../events.md#behavior-triggered-scheduling) for what remains open there.

`every` is the second trigger form and the same rule holds: it samples the condition at each
tick and fires only on a transition, observed between ticks rather than across a write. Its
interval is any `Read` expression of type `Duration`, so a literal, a field of the row, and a
`Configuration` path are one production — which is how a poll interval stays tunable without an
override mechanism. Sampling costs a stored last-tick bit per `(trigger, row)`, so schema commit
warns when the solver could have closed the condition instead.

Retry policy is deliberately not part of the registration: `max_attempts` and `backoff_base`
are rows in `system.events.QueuePolicy`, because retry is an operational property of the
destination rather than of the trigger, and tuning it should not require redeclaring a table.
This is the same separation used for enforcement modes.

An event functor, when attached to a table, does not execute the side effect itself — it
writes a work item into a designated DataCode queue table. This keeps the commit path fast
and ensures external side effects are:

- **Durable** — the queue row survives a server crash
- **Observable** — queue depth, failure rates, and retry counts are queryable
- **Retryable** — the scheduler owns the retry policy; the functor just writes the payload
- **Rate-limited** — the scheduler applies volume-based backoff before dispatching

The queue table is a normal DataCode table (`app.events.EmailQueue`,
`app.events.WebhookQueue`, etc.) — inspectable in the IDE, filterable, and audited in the
transaction log. See [../events.md](../events.md).

## Transparency

Because all functors are transparent (inspectable structure, not opaque compiled code), the
system can derive coercion paths between schema graph nodes, analyze access rules
statically for consistency, and render functors as edges in the IDE's ER diagram. See
[evolution.md](evolution.md) and [../ide.md](../ide.md).
