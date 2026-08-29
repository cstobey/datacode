# Functor types

This is the operational reference. For why there are four kinds and why access control is a
variety of path constraint rather than a kind of its own, see
[../category-model.md](../category-model.md).

DataCode has four functor kinds. All four are first-class schema objects — nodes in the schema
transaction graph, addressable by `FunctorRef`, and encoded in the effect-indexed GADT DSL (all
four confirmed in `spikes/functor-dsl/output.txt`, which supersedes the earlier
`spikes/dynamic-loading` for every DSL claim). A DSL term is inspectable structure rather than
opaque compiled code, which is what lets the system derive coercion paths between schema nodes
(see [evolution.md](evolution.md#coercion-between-schema-nodes)) and answer the structural
questions below without running anything (see
[../category-model.md](../category-model.md#functor-composition-and-transparency)).

**No functor is mirrored into a system table of functors, and there is none to declare.** A
validation *is* a `where` predicate, a foreign key *is* a `:>` declaration, a path constraint
*is* an `assert` body, and an event *is* an `on` or `every` declaration — all four are already
schema-graph nodes. Restating a declaration as a `Reference` row is the anti-pattern that
removed `system.events.Queue`; see [../events.md](../events.md#system-tables).

| # | Kind | Signature | When it runs | Purpose |
|---|---|---|---|---|
| 1 | **Validation** | `a → Either Error a` | On commit | Rejects invalid field values (range checks, format checks, domain invariants) |
| 2 | **Foreign key** | `Ref t → Either Error Row` | On commit | Referential integrity — resolves a reference to a live row in the referenced table |
| 3 | **Path constraint** | `Row → Either Error ()` | See below | Asserts something about what is reachable from a row through the schema graph. Comes in two varieties: data constraint and access constraint |
| 4 | **Event** | `(a, a) → Maybe EventRef` | On commit, or on a tick | Schedules a deferred side effect — enqueues a work item in a DataCode queue table rather than executing immediately |

`FunctorRef` and `EventRef` are declared in [types.md](types.md). `Ref t` and `Row` are
signature notation rather than DataCode types: `Ref t` is the reference representation for
target `t`, and `Row` is the row of the table the functor is attached to.

Two of the four signatures need reading carefully.

**`Ref t` is not always a `DataId`.** It is a `DataId` where the target is an ordinary table,
and a **2-byte variant tag** where the target carries `Reference` — two domains, resolved
against two indices, under one arrow. See [traits.md](traits.md#reference-tables-are-code).
Where the target carries `Component` the field is table-valued, so the functor resolves a
parent-prefix range scan and its codomain is a table of rows rather than one row; see
[tables.md](tables.md#component-sub-tables). "Live row" is load-bearing too: it is why deleting
a row that has live inbound non-nullable references is rejected rather than cascaded. See
[tables.md](tables.md#foreign-keys).

**The event functor sees two values and may return none.** `Maybe` encodes "no transition, no
event", and the pre-image is what the transition is observed against. The `every` form has no
pre-image to pass, so it threads a `system.events.TriggerState` row in its place. This replaces
an earlier `a → EventRef`, which was total and unary: it always yielded an event and saw one
value, so it could express neither half of the false-to-true rule stated below. The spike prints
`Nothing` for a tick with no transition and `Just` for the tick that crosses.

Kinds 1–3 are synchronous and transactional: they run as part of the commit and can abort it.
**Kind 4 cannot abort a commit.** For `on` over stored fields the queue row is written as part
of the transaction that triggered it; for `every` and for a solved crossing there is no
triggering commit at all — the scheduler wakes between ticks and writes the queue row in its own
transaction. Either way the side effect runs later, under the event scheduler.

All four are `Read` or `Tx` — none of them may call out. See
[functions.md](functions.md#the-effect-ladder).

The **handler** a queue names is not a fifth kind and is not a functor at all: it runs in
`Effect`, outside the commit, and is compiled-in Haskell rather than a DSL term. That is why it
can be arbitrary Haskell when functors cannot — it needs none of transparency, static access
analysis, or replayability. See [functions.md](functions.md#the-effect-ladder) and
[../events.md](../events.md#handlers).

**A [behavior](types.md#behaviors) is not a fifth kind.** Each kind above enforces something —
validation rejects, foreign keys resolve, path constraints assert, events enqueue. A behavior
does none of them; it is a projection, and specifically the field-scoped computed type that
`:` already creates, whose inhabitants are functions of `Moment`. It becomes relevant to
functors only as the subject of an event condition.

## Surface syntax mapping

| Kind | Written as | Documented in |
|---|---|---|
| Validation | `where <predicate>` on a type or field | [types.md](types.md), [tables.md](tables.md) |
| Foreign key | `:>` field declaration | [tables.md](tables.md) |
| Path constraint — data | `assert <name> { … }`, body without `authed_user` | [constraints.md](constraints.md) |
| Path constraint — access | `assert <name> { … }`, body with `authed_user` | [constraints.md](constraints.md) |
| Event — transition | `on <condition> emit <queue> { <payload> }` | [../events.md](../events.md) |
| Event — sampled | `every <interval> emit <queue> { <payload> } where <condition>` | [../events.md](../events.md) |

## Order of operations for a field write

Functors are attached at different granularities and must run in a fixed order, because a
type may apply a storage transform that later stages must not see behind.

1. **Default** every field the write does not supply, in declaration order. A `SeqAlloc`
   (`= next orderRef`) allocates against the named constraint's counter; a `RecordLit` on a
   `:>` field whose target carries `Component` constructs the row. `authed_user` resolves
   here — at insert, and in no other default position (see
   [railroad.md](railroad.md#contextual-bindings)). A defaulted value then enters step 2 exactly
   as a supplied one does.
2. **Coerce** the supplied value to the field's declared type.
3. **Validate** — run the field's `where` predicates against the *input* value: inherited
   predicates first, in trait-list order as written, then the table's own, in declaration
   order. For a `Hashed` field this is the plaintext, and it is the only stage that sees it.
4. **Decide** — on failure, the enforcement mode of each failing predicate's own attachment
   decides whether the transaction is rejected or the value is accepted and recorded as a
   violation (below).
5. **Transform** — apply the type's storage transform: hash the value, canonicalize text under
   the type's policy, intern a document key, resolve a `Reference` name to its variant tag.
   Only now.
6. **Encode** into the transaction's mutation list. Nothing that the transform removed can
   reach the log, because the log is written from this point forward.
7. **Resolve foreign keys** and check `unique` constraints across the row.
8. **Evaluate path constraints** — `assert` blocks, both varieties, across the affected
   subgraph. Anchoring is what makes that subgraph findable, by traversing `:>` edges backwards
   from the written row. See [constraints.md](constraints.md#anchoring).
9. **Fire event functors** whose condition transitioned from `False` to `True` across this
   write, and re-solve any behavior-triggered condition on the row, since writing the row
   changes the function the crossing was solved from. Both insert queue rows and can abort
   nothing.

A row constructed by step 1 runs steps 2–6 of its own before the parent's step 2 continues.
Steps 7–9 are evaluated once across the whole transaction, over parent and child alike, so a
component's foreign keys, asserts and events are not a nested pass.

**Step 3 before step 5 is the substantive constraint.** Validating after the transform would
mean validating a digest, which is meaningless, and steps 5 and 6 in that order are what make
"the plaintext never enters the transaction log" a structural property rather than a
convention. See [types.md](types.md#hashed-types).

**Predicate order decides which failure is reported.** That is a diagnostic question everywhere
except on a `Secret` field, where the failing predicate's address is the *whole* report — the
value is never returned with it (see [types.md](types.md#secret-types)). Addresses themselves,
and how they survive trait inheritance, are in
[README.md](README.md#addressing-validations).

**A mode is declared per predicate**, not per field (`ValidationRef ::= QName ( '/' Ident )?`),
so one field can carry `enforce always` on one predicate and `monitor` on another. Step 4
resolves that: if any failing predicate's mode rejects, the transaction is rejected; otherwise
the value is accepted, every failing predicate records its own violation, and a `repair`
predicate also enqueues the row.

**A field added to a table that already has rows is not defaulted at step 1.** Its mandatory
default is a read-time fallback for rows older than the schema node that added the field, and it
stops applying to a row the moment that field is written on it. Nothing is backfilled. See
[evolution.md](evolution.md#redeclare-a-table).

## Order of operations for a read

An access assert runs on read as well as on write, so a read needs an order of its own. A data
constraint does not appear in it: nothing about a read can falsify one.

1. **Materialize** the row.
2. **Evaluate the access asserts** on it. On failure every field of the row, including the key,
   resolves to `Redacted` — see [constraints.md](constraints.md#redaction-scope).
3. **Apply the query** — `where`, joins, `group`, `order by`, `limit` — to what step 2
   produced.

**Redaction comes before any predicate that names a field of the row, and that ordering is
security, not performance.** Filtering first would let a requester binary-search a value they
may not read: `… where salary > 90000` reports the predicate's truth whether it returns a
redacted row or no row at all. Redacting first costs materializing rows the filter then
discards, and that cost is the price of the property.

Two consequences follow from the order rather than being separate rules:

- **`limit` counts redacted rows**, because they are present in the result. `limit 10` over a
  page where eight rows redact returns ten rows, eight of them opaque. Filtering them out would
  reintroduce the leak step 2 exists to close.
- **`count rows` counts them too, and is therefore cardinality-revealing**, while an aggregate
  other than `count` over a column resolving to `Redacted` is ill-typed — `Redacted` is
  `Null`-derived and `sum : Table Number -> Number` is not. See
  [queries.md](queries.md#aggregate-functions).

## Enforcement modes

An attachment to a field or table carries an enforcement mode, which is what step 4 of the
[field-write order](#order-of-operations-for-a-field-write) reads. `enforce always` and
`enforce forward` reject the violating write; `monitor` and `repair into <queue>` accept it.
All four record the violation. The mode is declared by a separate statement addressed at the
validation, never by a clause inside the `where` block.
Full treatment — the four modes in detail, the violations table, why the flag cannot live on
the row, and the rule that a mode is mandatory when a predicate is added to a populated field —
is in [../integrity.md](../integrity.md#enforcement-modes).

**Modes govern the write path only.** An access assert — one whose body mentions `authed_user`
— redacts on read under every mode, `monitor` included. A mode that switched redaction off
would disable access control from a statement whose only documented effect is to accept a
write, and an operator reading the mode table would have no way to see it.

## Signature restrictions on `Secret` types

A validation functor attached to a field whose type is `Secret` — which every `Hashed` type is
— admits only the `a -> Bool` signature. `a -> Either Error a` and `a -> Maybe b` are rejected
at schema commit, because each carries the value out of the predicate — one through the error
channel, one through the value channel — and thence into the append-only log. See
[types.md](types.md#secret-types).

## Path constraints and their two varieties

Data constraints and access control are the same functor. Both assert something about what is
reachable from a row through the schema graph; both are written with `assert`; both compile to
the same `Row → Either Error ()` shape. The only difference is **whether the requesting token
is one of the terms**, and that difference is read off the assert *body* rather than its name.
[constraints.md](constraints.md#the-variety-is-decided-by-the-body) owns the comparison of the
two varieties and the argument for classifying structurally.

The signature widened from `(a, a) → Either Error ()` at the same time. Equality of two paths
is one shape an assert body can take; a query in boolean position asserts its result is
non-empty, and `not` of one asserts it is empty. Those cover presence and absence, which the
equality-only shape could not express at all — every *forward* path in the schema graph is
single-valued by construction, so an equality had nothing to quantify over. Presence and
absence quantify over the reverse direction of a `:>` edge, which is a relation rather than a
function. Equality is now the case where the body is an expression rather than a query.

Because both varieties are the same object, one structural walk over the term answers the same
questions for both. It classifies the variety, computes the exact `bypass access` exemption
set, warns on a conjunct of an access assert that does not mention the token, checks anchoring,
derives the revalidation set, and checks filter placement — every one of them recorded in
`spikes/functor-dsl/output.txt`. Both varieties also render as edges in the IDE's ER diagram
(see [../ide.md](../ide.md)).

**Consistency and completeness are not among them**, and an earlier claim that they were is
withdrawn. Containment and overlap between two access rules is decidable for the positive
conjunctive fragment and is not attempted for a body containing `not`, `=~`, or a user-defined
predicate: `not` is the absence shape, `=~` may name a `Configuration` pattern resolved at
runtime, and an arbitrary `Read` application makes the question undecidable. Completeness is
worse than undecidable — "no gaps" is not a well-formed property without a specification to
compare the policy against, and there is none.

## Event functor

An event functor is registered on the producing table with `on … emit`, and the queue that
receives the work item declares its own processor with `handler`:

```
on status is Shipped emit app.events.EmailQueue { recipient = customer.email }
```

**The condition fires on a `False` → `True` transition, never on merely being true.** For a
condition over stored fields the transition is observed across the write. For a condition over
a closed-form [behavior](types.md#behaviors) there is no write to observe, so the scheduler
solves for the moment the condition becomes true and wakes then — which is why behaviors are
restricted to a closed-form-solvable class. `every` is the second trigger form and the same
rule holds: it samples the condition at each tick and fires only on a transition, observed
between ticks rather than across a write. Sampling costs a `system.events.TriggerState` row per
`(trigger, row)`, so schema commit warns when the solver could have closed the condition
instead. Both trigger forms, the interval's typing, and what remains open on the solver are in
[../events.md](../events.md#triggering-an-event) and
[../events.md](../events.md#behavior-triggered-scheduling).

Retry policy is deliberately not part of the registration: it is a `system.events.QueuePolicy`
row per queue, carrying `max_attempts` and `backoff_base`, because retry is an operational
property of the destination rather than of the trigger. This is the same separation used for
enforcement modes. See [../events.md](../events.md#system-tables).

An event functor does not execute the side effect itself — it writes a work item into an
ordinary DataCode queue table (`app.events.EmailQueue`, `app.events.WebhookQueue`), which is
what makes the effect durable, observable, retryable and rate-limited, and what keeps the
commit path fast. See [../events.md](../events.md#queue-tables).
