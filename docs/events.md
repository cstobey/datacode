# Event System

The event scheduler is DataCode's mechanism for all deferred and external side effects —
both system maintenance and user-triggered outbound calls. It is not a separate message
broker; the queues are DataCode tables.

## Design Principle

**No external call may be made from within a commit transaction.** Any operation that
touches an external system (send an email, call a webhook, bind an LDAP directory, poll a
third-party API) must go through a queue table. A transaction that needs to trigger an
external effect inserts a row into a queue table; the commit completes; the scheduler picks
it up later and executes the side effect. This means:

- Commits are never blocked by external latency
- Side effects are durable — a crash between commit and execution loses nothing
- The queue is inspectable and auditable with standard DataCode tools
- Retry logic and backoff are centralized in the scheduler, not scattered across application code

This is not enforced by inspecting signatures for `IO`. It is enforced by a **missing lift**:
`commit :: Tx a -> Effect a` exists and nothing takes an `Effect a` to a `Tx a`. A handler may
therefore write freely, and a commit has no way to reach an external call — including through
the compositions a signature check misses, like `traverse` over an effectful function inside a
validation. See [schema/functions.md](schema/functions.md#the-effect-ladder).

## The Event System Is Outbound

The scheduler handles **deferred effects**, which are always outbound or internal. Inbound
arrival — a webhook POST, a connector row, an operator API call — is **not an event**. It is
a write, and it belongs to the API surface:

| Direction | Mechanism | Documented in |
|---|---|---|
| Inbound | a route whose functor inserts into a landing table | [api.md](api.md) |
| Outbound / deferred | a queue table with a `handler` | this document |

An inbound webhook is a `system.api.CustomRoute` row whose functor verifies the signature and
inserts into a `LogData` landing table. Nothing is enqueued, because the row *is* the durable
record — there is no side effect to defer and no external call to keep out of the commit.
Whatever should happen next is an ordinary `on … emit` on the landing table, and the insert
case of the false-to-true rule below already covers it.

Modelling arrival as an event kind was considered and rejected: it would have added a trigger
form providing neither of the two properties the event system exists to provide. The security
question is consequently a route concern — see
[OQ-020](open-questions.md#oq-020-webhook-endpoint-security).

## Triggering an Event

There are exactly **two** trigger forms, and both are declared on the producing table:

```ebnf
EventDecl ::= 'on' Expr 'emit' QName RecordLit
            | 'every' Expr 'emit' QName RecordLit WhereClause?
```

`on` observes a transition. `every` samples for one. Which of the six event cases you are
looking at is read off the trigger form and the table it sits on, not off a keyword per case:

| Case | Form | Fires |
|---|---|---|
| Transition over stored fields | `on <cond> emit` | at commit, on `False` → `True` |
| Insert (degenerate transition) | `on <cond> emit` | at insert |
| Crossing of a closed-form `Behavior` | `on <cond> emit` | at the solved moment |
| Open-form behavior, or state DataCode cannot observe | `every <D> emit … where <cond>` | at the first tick where the condition holds |
| Timer ingest — poll an external source | `every <D> emit …` | every tick, per row |
| Repair | `repair <ref> into <queue>` | on a recorded violation |

### `on` — Firing Is a False-to-True Transition

> **An event fires when its condition transitions from `False` to `True`. Never when the
> condition is merely true.**

```
table app.commerce.Order : UserData {
  customer  :> Customer,
  order_num : Int = next orderRef,
  status    : Pending | Shipped | Cancelled = Pending,
  total     : Amount,

  unique orderRef { customer, order_num },

  on status is Shipped emit app.events.EmailQueue {
    recipient = customer.email,
    template  = ShipmentNotice,
    payload   = { order = id }
  }
}
```

`on <condition> emit <queue> { <payload> }`. The payload is an ordinary row construction
against the queue table, so it is typed by the queue's own field declarations — nothing new.

This one rule covers three of the six cases above, which is why there is no separate keyword
for "on change":

- A condition over **stored fields** is evaluated before and after the write. An order
  committed twice while already `Shipped` enqueues one email, not two.
- **An insert is the degenerate case of the same rule.** Before the write the row did not
  exist, so the condition was not true; after it, it may be. `on state is Issued emit …` on a
  table whose rows are created with `state = Issued` therefore fires once per row, at creation,
  with no "on insert" keyword. `system.auth.Challenge` ([auth.md](auth.md#challenge-methods))
  is the case this was noticed on: issuing a one-time code *is* inserting the row, and the send
  is the event.
- A condition over a closed-form [behavior](schema/types.md#behaviors) has no write to
  observe, so the scheduler **solves for the moment the condition becomes true** and wakes up
  then:

```
table app.billing.CreditLine : Accruing, UserData {
  customer     :> Customer,
  credit_limit : Amount,

  unique lineRef { customer, opened_at },

  on balance >= credit_limit emit app.events.OverlimitQueue {
    account = id,
    at_risk = credit_limit
  }
}
```

Nothing is polled and no row records "check this later". The trigger is a property of the
table, and `scheduled_at` on the resulting queue row is the solved crossing moment rather than
something the author computed by hand. See
[Behavior-Triggered Scheduling](#behavior-triggered-scheduling) for what remains open.

### `every` — Sampling for a Transition

Some conditions cannot be solved. An open-form behavior is not in the closed-form-solvable
class; external state is not observable at all until something asks. For those, `every`
declares the sampling interval:

```
table app.ingest.Feed : UserData {
  vendor        :> Vendor,
  url           : URL,
  poll_interval : Duration = 15 minutes,
  active        : Bool = True,

  unique feedOf { vendor, url },

  every poll_interval emit app.ingest.PriceRefresh { source = self } where active
}
```

Five properties, none of which needed a new construct:

**The interval is an expression, not a literal.** Any `Read` expression of type `Duration`
serves: a `DurationLit` (`every 15 minutes`), a field of the row (`every poll_interval`), or a
`Configuration` path (`every system.config.Ingest.interval`). This is what makes an interval
tunable without an override mechanism — point the expression at wherever the tuning should
live. It is re-read each tick, so a `Configuration` write takes effect on the next one.

The scheduler clamps below a floor held in `system.events.SchedulerLimit`, so `every 1
millisecond` cannot be introduced by a data edit. A literal below the floor is rejected at
schema commit instead of clamped, since the author can see it.

**It fires per row of the table it is declared on.** Fan-out is not a feature of `every`; it is
what "declared on a table" already means, exactly as `on` fires per row. One `Feed` row per
vendor endpoint gives one work item per endpoint per tick.

**`where` is the ordinary meaning of `where`** — restrict to the subset satisfying a
predicate. A deactivated feed is not sampled. This is the same clause that carries the
condition in the open-form behavior case:

```
every 30 seconds emit app.events.OverlimitQueue { account = id } where balance >= credit_limit
```

**There is no standalone or top-level cron form, and none is needed.** A timer job always has
rows that parameterize it — which feed, which directory, which account — and that row's table
is the producing table. A job with genuinely no parameterizing row is server maintenance, which
is `system.events.MaintenanceQueue` and not user syntax. Making `every` a `BodyItem` rather
than a `Statement` is what keeps the payload typed against a row it can name.

**False-to-true still holds.** `every` samples the condition at each tick and fires only on a
transition — observed between ticks instead of across a write. A credit line that stays over
limit enqueues once, not once every 30 seconds. This costs a stored last-tick bit per
`(trigger, row)`:

```
table system.events.TriggerState : LogData {
  trigger    : FunctorRef,
  subject    : DataId,
  held       : Bool,
  sampled_at : Timestamp
}
```

That cost is the argument for preferring a solved crossing wherever one exists, so **schema
commit warns when `every` carries a condition the solver could have closed**, and names it:

```
datacode[app.billing]> :commit
  app.billing.CreditLine: `every 30 seconds … where balance >= credit_limit` samples a
  condition the solver can close (balance is linear in Moment). Drop `every` to solve it.
```

### One Scheduler

The connector daemon's polling loop is a scheduled event under this scheduler, not an
independent scheduler with its own interval, backoff, and priority notions. A connector's two
loops are two `every` statements on the connector row:

```
table system.connectors.Connector : Configuration {
  name           : Text unique,
  kind           :> ConnectorKind,
  poll_interval  : Duration = 10 seconds,
  latency_window : Duration,
  enabled        : Bool = True,

  every poll_interval  emit system.connectors.SyncQueue   { connector = self } where enabled,
  every latency_window emit system.connectors.VerifyQueue { connector = self } where enabled
}
```

Because `system.connectors.Connector` carries `Configuration`, retuning either interval is a
data write with no schema commit — which is what
[connectors.md](connectors.md#dynamic-configuration) already promised, now with no second
mechanism behind it. Two schedulers would have meant two retry policies, two backoff states,
and no way to reason about total outbound load. This narrows OQ-019 to worker-pool topology.

## Queue Tables

A queue table carries the `Queue` trait, which extends `LogData`:

```
trait Queue : LogData {
  scheduled_at : Timestamp = created_at
}
```

Beyond that field, what makes a queue a queue is four structural rules, checked at schema
commit rather than written in the trait body — two of them are about field *types*, and the
grammar has no way to say "a foreign key to any table carrying trait X":

1. Exactly **one** `handler`.
2. Exactly **one** `:>` field to a table carrying [`QueueState`](#queue-state).
3. At most **one** field whose type is `Priority`.
4. Every field other than the `QueueState` field is append-only, as `LogData` requires.

```
table app.auth.LdapSync : Queue {
  subject :> User,
  scope   : SingleUser | FullRefresh,
  urgency : Priority = urgent,
  state   :> LdapSyncState = Requested,

  handler system.connectors.ldap.sync
}
```

`handler` was previously valid on any table carrying `LogData`. It is now valid only on a
`Queue`, which is tighter and says what was meant: a log is not a work list.

**Queue tables carry `LogData`, and they carry it for a structural reason.** A queue item is
an *occurrence*: two identical enqueues are two distinct work items, and collapsing them
would be a bug. That is the same property that exempts logs from the candidate-key
requirement — occurrences have no identity beyond their occurrence. See
[schema/tables.md](schema/tables.md#candidate-keys-are-mandatory).

### Queue State

The `QueueState` field is the **one exemption from append-only in the whole system**, and it is
narrow: one field, on a `Queue` table, written only by the handler bound to that queue.
Anything else that needs recording after the fact goes in its own `LogData` table with a `:>`
back to the queue row — an ordinary foreign key, no new mechanism. The attempt history below is
that rule applied to the scheduler's own bookkeeping.

The state enum is declared per queue, because `Bound`, `Applied`, and `PartiallyApplied` are
domain facts a polling client needs to read. The scheduler needs something narrower, so each
state declares its **disposition**:

```
trait QueueState : Reference {
  name        : Text unique,
  disposition : Pending | InFlight | Done | Failed
}

table app.auth.LdapSyncState : QueueState {
  retryable : Bool = True
}
```

The client reads `state.name`; the scheduler reads `state.disposition`. `QueueState` extends
`Reference`, so adding a state is a schema commit and `state is Bound` is checked at
schema-commit time ([schema/traits.md](schema/traits.md#reference-tables-are-code)).

This is what makes a request/response event expressible with no second mechanism. The LDAP
on-demand lookup inserts an `LdapSync` row, the client polls that row, and the handler advances
the state as it goes. Waiting on the transition rather than re-polling is an API concern — see
[api.md](api.md) — not schema syntax.

### Attempt History

Retries are occurrences, so they are rows rather than counters. One table is generated per
queue table, sharded with the queue rows it describes:

```
table app.auth.LdapSync.Attempt : LogData {
  subject    :> app.auth.LdapSync,
  started_at : Timestamp,
  outcome    : Succeeded | Failed,
  error      : Text | NotFound
}
```

`attempt_count` is a count over it, the next `scheduled_at` is derived from backoff over it, and
a flapping destination is visible per item instead of collapsed into an integer. This replaces
`system.events.Item`, which no longer exists — see
[System Tables](#system-tables).

### Priority

Priority is **per item**, defaulted per field, and recognized **structurally**: the scheduler
dispatches in order of the field whose *type* is `Priority`, not the field whose *name* is
`priority`. Two `Priority` fields on one queue is a compile-time error.

```
type Priority : Int where inRange -20 19

urgent, normal, background :: Priority   -- -10, 0, 10; stdlib constants
```

Nice semantics: lower is more urgent, and the range is `nice`'s. Arithmetic matters because the
scheduler **ages** waiting items toward urgency; without aging, a background item behind a
saturated urgent queue starves. The aging rate is a `system.events.QueuePolicy` field.

Per-*queue* priority was rejected. The deciding case is a queue needing two priorities for the
same work — an on-demand single-user LDAP lookup and a nightly full refresh share a handler, a
payload shape, and a destination, and differ only in urgency. Per-queue priority would force
that into two tables, duplicating the schema and splitting the rows an operator wants to see in
one list.

## Handlers

A handler is the one place in DataCode where **arbitrary Haskell is admissible**, and it is
admissible for a reason rather than as an exception: a handler runs outside the commit, so it
needs none of the three properties the GADT DSL exists to provide. It is not inspected by the
query optimizer, it is not part of static access analysis, and it is never replayed. See
[dynamic-loading.md](dynamic-loading.md) and OQ-001.

The consequence is that handlers are **compiled in**, not dynamically loaded:

```haskell
-- a handler module compiled into the server
ldapSync :: Handler App.Auth.LdapSync
ldapSync = handler "system.connectors.ldap.sync" $ \row cfg -> do
  conn <- bind (cfgHost cfg) (cfgCredential cfg)
  commit $ row { state = Bound }
  case scope row of
    SingleUser  -> syncOne conn (subject row)
    FullRefresh -> syncAll conn          -- commits in batches
  commit $ row { state = Applied }
```

The author writes `Row -> Config -> Effect Outcome`. The `Handler` newtype supplies everything
else — retry, backoff, timeout, concurrency limiting, priority dispatch, and capability
injection. A handler never writes retry logic and never sees `IO`.

**A handler's writes are ordinary transactions.** `commit :: Tx a -> Effect a` is available, so
a handler writes as much and as often as it likes, and every write is subject to the full set of
validations, asserts, and access rules. A handler is not privileged; its one privilege is the
`QueueState` field of its own queue's row.

**`commit` is where retry granularity lives.** Everything before the first `commit` is redone on
retry; everything after it is not. That puts idempotency under the author's control by
placement, rather than making it a global property they have to reason about. A full refresh
that commits per batch resumes at the last committed batch.

**Capabilities come from the config row, never from the code.** `cfg` is the only source of a
host, a credential, or a timeout, so a handler cannot reach a destination the operator has not
granted and never holds a credential in a compiled constant.

### Registration Is Two Rows

Handler **existence** is code, so it is `Reference` and compile-checked. Handler **tuning** is
operations, so it is `Configuration` and hot.

```
table system.events.Handler : Reference {
  name       : Text unique,
  queue_type : TypeRef,
  effect_sig : TypeRef
}

table system.events.HandlerConfig : Configuration {
  handler       :> Handler unique,
  timeout       : Duration,
  concurrency   : Int,
  allowed_hosts : Doc,
  credential    :> Credential | NoCredential
}
```

`handler system.connectors.ldap.sync` on a queue table names the `Reference` row, so a mistyped
handler name is a schema-commit error rather than a runtime dispatch failure — the same check
`status is Shipped` gets.

Adding a *new* handler requires a build and a schema-daemon restart (OQ-001's multi-daemon
layer). That is acceptable because handlers arrive at the rate of new **integrations**, not new
business rules: SMTP, HTTP POST, LDAP bind, S3 put. Business rules are functors, they go through
the DSL, and they need no restart. Retuning an existing handler is a `Configuration` write with
no restart at all.

## Repair Queues

The `repair` enforcement mode binds a validation to a queue table, so that a row which
violates it is not merely recorded but handed to an automated remediation functor:

```
repair app.crm.Contact.postal_code / isDeliverable into app.events.RepairQueue
```

This is what makes "fix the data problems, or at least monitor them" one mechanism rather than
two: `repair` is `monitor` plus an enqueue, and the scheduler's existing retry policy, backoff,
and observability apply unchanged. A repair functor that cannot fix a row leaves the violation
open, which is the correct outcome — it becomes an operator's problem rather than disappearing.

`repair` keeps `into` rather than `emit` because the two statements have different shapes:
`emit` takes a payload literal, while a repair's payload is fixed — it is the violating row.
The binding is otherwise identical, and both name an ordinary queue table.

### Why Repair Is Deferred

Not because of shards. Because of **when the violation exists**. `repair` is `monitor` plus an
enqueue, and `monitor` means the write was *accepted* — by the time there is a violation to fix,
the commit is over and there is no in-commit moment left to fix anything in. The retroactive
case settles it independently: adding a predicate to a table that already has rows can enqueue
millions of repairs, which is not one transaction.

**The in-commit way to fix a value is a type transform, not a repair.** Steps 1 and 4 of the
[order of operations](schema/functors.md#order-of-operations-for-a-field-write) already coerce
and transform. A value that should be rounded to cents should be normalized by `Amount`, not
validated by `isRoundedToCents` with a repair queue behind it — which is why the example above
is a postal code, something you can only fix by consulting an address service outside the row.
That is the shape `repair` is for.

**A `ValidationRef` may name an `assert`.** So "a path constraint that cannot be satisfied hands
the row to a functor that inserts the missing row" needs no new syntax. The remediation runs
after the commit, so the row is briefly companionless — if that is unacceptable, the requirement
is in-commit and belongs to [internal derivation](#internal-effects-are-derived-not-triggered)
instead.

See [integrity.md](integrity.md) for the other three modes.

## Internal Effects Are Derived, Not Triggered

A row that must exist whenever its parent exists is a **total function of the parent**, not an
event. `Component` already owns lifetime and `DefaultClause` already takes a row construction,
so the default-table case is existing syntax composed:

```
table app.crm.Account : UserData {
  name     : Text unique,
  settings :> Settings : Component = { theme = Dark, digest = Weekly }
}
```

**The default constructs the row**, in the same commit, and that is what distinguishes the two
default shapes on a `:>` field:

```
created_by :> User = authed_user                      -- references an existing row
settings   :> Settings : Component = { theme = Dark } -- constructs one
```

The `Component` sub-table body is what makes it a construction. No shard question arises: a
component is owned, so it lives in its parent's row-rooted shard by definition. Nothing fires
and nothing is enqueued.

**Deleting a parent deletes its components, in the same transaction.** Component lifetime is
owned, so a tombstone on the parent tombstones the component rows beneath it — mechanically,
over `Component` edges, with no cascade declaration and no depth limit to configure, because the
edges are the ownership. This is not a trigger; it is the same statement about lifetime read in
the other direction. Non-`Component` FKs never cascade.

**A cross-table in-commit trigger to a non-`Component` table is refused.** If a row must exist
atomically with another and it has independent identity and lifetime, that is a modelling error:
make it a component, or make it a view. Admitting the general case would put arbitrary
user-authored mutation inside the commit path with unbounded cascade depth, order-dependence,
and a commit whose cost is not readable from the schema.

Several classic trigger use-cases do not survive contact with the rest of the design, and are
listed so they are not reinvented:

| Classic trigger | What DataCode does instead |
|---|---|
| Audit / history rows | Nothing. The transaction graph **is** the audit log. |
| Denormalized counters, derived status | A view field or a `Behavior`. |
| `created_by = current_user` | A field default: `created_by :> User = authed_user`. |
| Sequence allocation | A field default: `order_num : Int = next orderRef`. See [tables.md](schema/tables.md#sequences). |
| Materialized view refresh, index maintenance | In-commit per OQ-027, or `system.events.MaintenanceQueue`. |
| `Reference` variant tag allocation | Internal and mechanical. |
| Cascade delete of owned rows | Mechanical over `Component` edges, above. |

## System Tables

Two tables that were specified here no longer exist, and both were removed by deletion rather
than replaced.

**`system.events.Item` is gone.** It carried `payload : Bytes`, which duplicated the queue row —
the payload existed in two places, could diverge, and "the queue is inspectable with standard
DataCode tools" is false of a blob. Its other three fields decomposed: `scheduled_at` is a field
of the `Queue` trait, `status` was a second authority for a fact the `QueueState` field already
holds, and `attempt_count`/`last_error` became the
[per-queue attempt history](#attempt-history), which is a better record than a counter.

**`system.events.Queue` is gone.** A queue's existence and its handler binding are *already*
schema facts — `table … : Queue { … handler … }` is the declaration — and a `Reference` table
restating that would duplicate the schema graph into a table, when the schema graph is already
queryable. The general rule:

> **A `Reference` table is needed exactly where a fact originates outside the schema graph.**

`system.events.Handler` qualifies: it is the bridge that makes `handler system.connectors.ldap.sync`
resolve against compiled-in Haskell, which is not a schema object. Queues do not.

What remains is operational, and therefore `Configuration`:

```
table system.events.QueuePolicy : Configuration {
  queue            : TypeRef unique,
  max_attempts     : Int,
  backoff_base     : Duration,
  aging_rate       : Duration,
  concurrency      : Int,
  default_priority : Priority
}

table system.events.BackoffState : Configuration {
  destination   : Text unique,
  failure_rate  : Decimal,
  volume_count  : Int,
  backoff_until : Timestamp
}

table system.events.SchedulerLimit : Configuration {
  min_interval  : Duration,
  max_in_flight : Int
}
```

`system.events.MaintenanceQueue` is unchanged — log compaction, shard splits, materialized view
refreshes, retention rollups and the prunes that follow them, LMDB vacuum, index rebuilds,
orphaned branch cleanup. Populated by the server itself; not user-accessible. Maintenance
scheduling is consequently observable through DataCode like everything else.

## Volume-Based Backoff

The scheduler uses **volume-based backoff**, not just time-based backoff. This matters
because:

- A destination may be healthy but rate-limited — backing off by time alone starves other destinations sharing the same worker pool
- A destination may have started failing due to volume (the caller is overwhelming it) — the correct response is to reduce volume, not just delay

Backoff logic:

1. **Per-destination failure tracking**: rolling failure rate over a recent window. If the rate exceeds a threshold, enter backoff.
2. **Volume throttling**: if the queue depth for a destination exceeds a configured limit, throttle new dispatches to that destination regardless of failure rate.
3. **Exponential delay**: `backoff_duration = backoff_base × 2^(failure_count)`, capped at a maximum.
4. **Jitter**: randomized ±20% on the delay to prevent thundering-herd recovery.

Backoff state lives in `system.events.BackoffState` — observable and adjustable by
operators without a server restart.

## Scheduler Architecture

The event scheduler is a dedicated DataCode process. It:

1. Selects queue rows whose `state.disposition is Pending` and whose `scheduled_at ≤ now`, in aged-priority order
2. Advances the row to a state whose disposition is `InFlight`, atomically (prevents double-dispatch)
3. Calls the queue's handler with the row and the handler's `Configuration`
4. On success: appends a `Succeeded` attempt row, updates `BackoffState` (reset failure count). The handler has normally already advanced the state; if it has not, the scheduler advances it to the queue's terminal `Done` state
5. On failure: appends a `Failed` attempt row with the error, computes the next `scheduled_at` from backoff over the attempt history, returns the row to a `Pending`-disposition state — or a `Failed` one once the attempt count reaches `max_attempts`

The poll interval is adaptive — shorter when the queue is non-empty, longer when idle.

## Behavior-Triggered Scheduling

A condition over stored fields is decided at commit, so it costs the scheduler nothing. A
condition over a behavior is different: the scheduler must compute *when* the condition will
first hold and arrange to wake at that moment. Three things follow, and none of them is
settled — see OQ-034 in [open-questions.md](open-questions.md).

**Solving.** The crossing moment must be derived in closed form, which is what restricts
behaviors to an analyzable class. The class, the solver per class, and the encoding of both
in the GADT DSL are open. This is also the one functor kind the dynamic-loading spike never
validated (OQ-001), so nothing here rests on evidence yet.

**Re-solving on write.** A behavior closes over stored fields, so writing the row changes the
function and moves the crossing. Every pending wake-up derived from a behavior on that row
has to be recomputed at commit, and an item already enqueued may have been enqueued for a
crossing that no longer happens. Whether such an item is withdrawn, or dispatched with the
condition re-checked at fire time, is open.

**Missed crossings.** If the server is down across a crossing moment, the event can fire late
or not at all. "The trial expired" wants to fire late; "the rate-limit window opened" may not.
The policy — and whether it is per queue or per trigger — is open.

**`every` is the escape hatch, not the answer.** A condition the solver cannot close is
expressible today by sampling it, at the cost of `TriggerState` rows and a bounded lateness of
one interval. That makes behaviors *usable* before OQ-034 is answered; it does not answer it,
because sampling reintroduces exactly the polling that solving exists to eliminate. The solver's
job is to shrink the set of conditions for which `every` is the only option.
