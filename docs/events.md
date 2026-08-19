# Event System

The event scheduler is DataCode's mechanism for all deferred and external side effects —
both system maintenance and user-triggered outbound calls. It is not a separate message
broker; the queues are DataCode tables.

## Design Principle

**No external call may be made from within a commit transaction.** Any operation that
touches an external system (send an email, call a webhook, update a third-party API
endpoint) must go through a queue table. A transaction that needs to trigger an external
effect inserts a row into a queue table; the commit completes; the scheduler picks it up
later and executes the side effect. This means:

- Commits are never blocked by external latency
- Side effects are durable — a crash between commit and execution loses nothing
- The queue is inspectable and auditable with standard DataCode tools
- Retry logic and backoff are centralized in the scheduler, not scattered across application code

This is enforced at schema commit: a functor with an `a -> IO b` signature is rejected. See
[schema/functions.md](schema/functions.md).

## User-Defined Queue Tables

Applications define their own queue tables for outbound side effects. A queue table declares
the functor that processes it with `handler`:

```
table app.events.EmailQueue : LogData {
  recipient : Email,
  template  : EmailTemplate,
  payload   : Doc,

  handler system.connectors.email.sendFunctor
}

table app.events.WebhookQueue : LogData {
  destination : URL,
  body        : Doc,

  handler system.connectors.http.postFunctor
}
```

When the scheduler dequeues a row it calls that functor with the row as input.

**Queue tables carry `LogData`, and they carry it for a structural reason.** A queue item is
an *occurrence*: two identical enqueues are two distinct work items, and collapsing them
would be a bug. That is the same property that exempts logs from the candidate-key
requirement — occurrences have no identity beyond their occurrence. See
[schema/tables.md](schema/tables.md#candidate-keys-are-mandatory).

**Retry policy is not declared here.** `max_attempts` and `backoff_base` are rows in
`system.events.Queue`, because retry is an operational property of the destination that
changes over time and should not require redeclaring a table to tune. This is the same
separation enforcement modes use — see [integrity.md](integrity.md#declaring-a-mode).

## Triggering an Event

A producing table declares when to enqueue with `on … emit`:

```
table app.commerce.Order : UserData {
  customer  :> Customer,
  order_num : Int,
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

### Firing Is a False-to-True Transition

> **An event fires when its condition transitions from `False` to `True`. Never when the
> condition is merely true.**

This one rule covers both kinds of trigger, which is why there is no separate keyword for
"on change":

- A condition over **stored fields** is evaluated before and after the write. An order
  committed twice while already `Shipped` enqueues one email, not two.
- **An insert is the degenerate case of the same rule.** Before the write the row did not
  exist, so the condition was not true; after it, it may be. `on state is Issued emit …` on a
  table whose rows are created with `state = Issued` therefore fires once per row, at creation,
  with no "on insert" keyword. `system.auth.Challenge` ([auth.md](auth.md#challenge-methods))
  is the case this was noticed on: issuing a one-time code *is* inserting the row, and the send
  is the event.
- A condition over a [behavior](schema/types.md#behaviors) has no write to observe, so the
  scheduler **solves for the moment the condition becomes true** and wakes up then:

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
table, and `scheduled_at` on the resulting queue item is the solved crossing moment rather
than something the author computed by hand.

This is why behaviors are restricted to a closed-form-solvable class. Sampling an arbitrary
`Moment -> a` tells you whether a condition holds *now*; it does not tell you when it will
start holding, and without that the scheduler is back to polling.

### `on` Replaces `assert event`

The earlier placeholder was `assert event { <FunctorRef> }`. It was wrong on three counts and
each is addressed above: an event registration is not an assertion (`on … emit`), it carried
no trigger condition (the `on` expression), and it carried no queue binding or retry policy
(`emit` names the queue; retry stays operational in `system.events.Queue`). It also
conflated the producer with the consumer — `handler` is the queue's business, `on … emit` is
the producing table's.

## Repair Queues

The `repair` enforcement mode binds a validation to a queue table, so that a row which
violates it is not merely recorded but handed to an automated remediation functor:

```
repair app.commerce.Order.total / isRoundedToCents into app.events.RepairQueue
```

This is what makes "fix the data problems, or at least monitor them" one mechanism rather
than two: `repair` is `monitor` plus an enqueue, and the scheduler's existing retry policy,
backoff, and observability apply unchanged. A repair functor that cannot fix a row leaves the
violation open, which is the correct outcome — it becomes an operator's problem rather than
disappearing.

`repair` keeps `into` rather than `emit` because the two statements have different shapes:
`emit` takes a payload literal, while a repair's payload is fixed — it is the violating row.
The binding is otherwise identical, and both name an ordinary queue table.

See [integrity.md](integrity.md) for the other three modes.

## System Queue Tables

The scheduler also drives internal DataCode maintenance through system-managed queues:

```
system.events.MaintenanceQueue
  -- log compaction, shard splits, materialized view refreshes,
  -- retention rollups and the prunes that follow them,
  -- LMDB vacuum, index rebuilds, orphaned branch cleanup
  -- Populated by the server itself; not user-accessible
```

This means maintenance scheduling is itself observable through DataCode — operators can
query `system.events.MaintenanceQueue` to see what maintenance is pending and when.

## System Tables

```
table system.events.Queue : Configuration {
  name         : Text unique,
  handler_ref  : FunctorRef,
  max_attempts : Int,
  backoff_base : Duration
}

table system.events.Item : LogData {
  queue_name    : Text,
  payload       : Bytes,
  scheduled_at  : Timestamp,
  attempt_count : Int,
  last_error    : Text | NotFound,
  status        : Pending | InFlight | Failed | Done
}

table system.events.BackoffState : Configuration {
  destination   : Text unique,
  failure_rate  : Decimal,
  volume_count  : Int,
  backoff_until : Timestamp
}
```

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

The event scheduler is a dedicated DataCode process (similar to the connector daemon — see
OQ-019 in [open-questions.md](open-questions.md)). It:

1. Polls `system.events.Item` for rows with `status is Pending` and `scheduled_at ≤ now`
2. Marks each item `InFlight` atomically (prevents double-dispatch)
3. Calls the queue's `handler_ref` functor with the payload
4. On success: marks `Done`, updates `system.events.BackoffState` (reset failure count)
5. On failure: increments `attempt_count`, logs `last_error`, computes next `scheduled_at` from backoff, marks `Pending` again (or `Failed` if `attempt_count ≥ max_attempts`)

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

Until these are answered, `on` conditions over stored fields are implementable as specified
and conditions over behaviors are not.
