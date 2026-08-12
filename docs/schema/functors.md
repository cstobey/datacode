# Functor Types

This is the operational reference. For why there are four kinds and why access control is a
variety of path equivalence rather than a kind of its own, see
[../category-model.md](../category-model.md).

DataCode has four functor kinds. All four are first-class schema objects — defined as rows
in system tables, referenced by `FunctorRef`, and encoded in the GADT DSL (confirmed in
`spikes/dynamic-loading/output.txt`).

| # | Kind | Signature | When it runs | Purpose |
|---|---|---|---|---|
| 1 | **Validation** | `a → Either Error a` | On commit | Rejects invalid field values (range checks, format checks, domain invariants) |
| 2 | **Foreign key** | `DataId → Either Error Row` | On commit | Referential integrity — resolves a DataId to a live row in the referenced table |
| 3 | **Path equivalence** | `(a, a) → Either Error ()` | See below | Asserts that two schema-graph paths reach the same value. Comes in two varieties: data constraint and access control |
| 4 | **Event** | `a → EventRef` | On commit | Schedules a deferred side effect — enqueues a work item in a DataCode queue table rather than executing immediately |

Kinds 1–3 are synchronous and transactional: they run as part of the commit and can abort
it. Kind 4 is asynchronous and decoupled: the commit always succeeds (inserting the queue
row is the commit), and the side effect runs later under the event scheduler.

**A [behavior](types.md#behaviors) is not a fifth kind.** Each kind above enforces something —
validation rejects, foreign keys resolve, path equivalence asserts, events enqueue. A behavior
does none of them; it is a projection, and specifically the field-scoped computed type that
`:` already creates, whose inhabitants are functions of `Moment`. It becomes relevant to
functors only as the subject of an event condition.

## Surface Syntax Mapping

| Kind | Written as | Documented in |
|---|---|---|
| Validation | `where <predicate>` on a type or field | [types.md](types.md), [tables.md](tables.md) |
| Foreign key | `:>` field declaration | [tables.md](tables.md) |
| Path equivalence — data constraint | `assert <name> { <path> == <path> }` | [constraints.md](constraints.md) |
| Path equivalence — access control | `assert access { user.<path> == <path> }` | [constraints.md](constraints.md) |
| Event | `on <condition> emit <queue> { <payload> }` | [../events.md](../events.md) |

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
7. **Evaluate path equivalences** — `assert` blocks, both varieties, across the affected
   subgraph.
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

## Path Equivalence and Its Two Varieties

Data constraints and access control are the same functor. Both assert that two paths through
the schema graph resolve to the same value; both are written with `assert`; both compile to
the same `(a, a) → Either Error ()` shape. The only difference is **what the two path terms
refer to**, and that difference is what produces the differing runtime behaviour:

| | Data constraint | Access control |
|---|---|---|
| Written | `assert <name> { p == q }` | `assert access { user.x == q }` |
| Left term | a data path from the row | the requesting user token |
| Right term | a data path from the row | a data path from the row |
| Evaluated | on commit | on read **and** write |
| On failure, write | reject the transaction | reject the transaction |
| On failure, read | n/a — not evaluated on read | field resolves to `Redacted` |

```
table Order {
  customer  :> Customer,
  bill_addr :> Address,
  order_num : Int,

  unique orderRef { customer, order_num },

  -- Data constraint: two FK paths must reach the same address
  assert billingMatch { customer.billing_address == bill_addr },

  -- Access control: the requesting user must be reachable from this row
  assert access { user.id == customer.user_id }
}
```

Because both varieties are the same object, the analyses that apply to one apply to the
other: access rules can be checked statically for consistency and completeness the same way
data constraints can, and both render as edges in the IDE's ER diagram (see
[../ide.md](../ide.md)).

Redaction on read is where the two diverge operationally. A failed access assertion on a
read does not abort — it resolves the field to `Redacted`, a built-in `Null`-derived absence
type (see [types.md](types.md)). Absence is typed, so the client can distinguish "you may
not see this" from "there is nothing here".

The name `access` is what marks an assertion as the access-control variety. Any other name
is a data constraint.

## Event Functor

An event functor is registered on the producing table with `on … emit`, and the queue that
receives the work item declares its own processor with `handler`:

```
on status is Shipped emit app.events.EmailQueue { recipient = customer.email, ... }
```

**The condition fires on a `False` → `True` transition, never on merely being true.** For a
condition over stored fields the transition is observed across the write. For a condition over
a [behavior](types.md#behaviors) there is no write to observe, so the scheduler solves for the
moment the condition becomes true and wakes then — which is why behaviors are restricted to a
closed-form-solvable class. See
[../events.md](../events.md#behavior-triggered-scheduling) for what remains open there.

Retry policy is deliberately not part of the registration: `max_attempts` and `backoff_base`
are rows in `system.events.Queue`, because retry is an operational property of the
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
