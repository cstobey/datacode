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

Applications define their own queue tables for outbound side effects:

```
table app.events.email_queue {
  recipient : Email,
  template  : EmailTemplate,
  payload   : Doc,
  assert event { system.connectors.email.SendFunctor }
}

table app.events.webhook_queue {
  destination : URL,
  body        : Doc,
  assert event { system.connectors.http.PostFunctor }
}
```

The `assert event` attribute links the queue table to the connector functor that knows how
to process it. When the scheduler dequeues a row, it calls that functor with the row as
input.

**The `assert event` syntax is a placeholder.** An event registration is not an assertion,
and this form expresses no trigger condition, queue binding, or retry policy. The semantics
described in this document are settled; the surface syntax is outstanding work. See
[schema/functors.md](schema/functors.md#event-functor).

## Repair Queues

The `repair` enforcement mode binds a validation to a queue table, so that a row which
violates it is not merely recorded but handed to an automated remediation functor:

```
repair app.commerce.Order.total / isRoundedToCents into app.events.repair_queue
```

This is what makes "fix the data problems, or at least monitor them" one mechanism rather
than two: `repair` is `monitor` plus an enqueue, and the scheduler's existing retry policy,
backoff, and observability apply unchanged. A repair functor that cannot fix a row leaves the
violation open, which is the correct outcome — it becomes an operator's problem rather than
disappearing.

The `into <queue>` binding shares the open surface-syntax question as the rest of the event
functor (OQ-030); the semantics are the same as any other queue.

See [integrity.md](integrity.md) for the other three modes.

## System Queue Tables

The scheduler also drives internal DataCode maintenance through system-managed queues:

```
system.events.maintenance_queue
  -- log compaction, shard splits, materialized view refreshes,
  -- LMDB vacuum, index rebuilds, orphaned branch cleanup
  -- Populated by the server itself; not user-accessible
```

This means maintenance scheduling is itself observable through DataCode — operators can
query `system.events.maintenance_queue` to see what maintenance is pending and when.

## System Tables

```
table system.events.queues {
  name         : Text unique,
  handler_ref  : FunctorRef,
  max_attempts : Int,
  backoff_base : Duration
}

table system.events.items {
  queue_name    : Text,
  payload       : Bytes,
  scheduled_at  : Timestamp,
  attempt_count : Int,
  last_error    : Text | NotFound,
  status        : Pending | InFlight | Failed | Done
}

table system.events.backoff_state {
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

Backoff state lives in `system.events.backoff_state` — observable and adjustable by
operators without a server restart.

## Scheduler Architecture

The event scheduler is a dedicated DataCode process (similar to the connector daemon — see
OQ-019 in [open-questions.md](open-questions.md)). It:

1. Polls `system.events.items` for rows with `status is Pending` and `scheduled_at ≤ now`
2. Marks each item `InFlight` atomically (prevents double-dispatch)
3. Calls the queue's `handler_ref` functor with the payload
4. On success: marks `Done`, updates `system.events.backoff_state` (reset failure count)
5. On failure: increments `attempt_count`, logs `last_error`, computes next `scheduled_at` from backoff, marks `Pending` again (or `Failed` if `attempt_count ≥ max_attempts`)

The poll interval is adaptive — shorter when the queue is non-empty, longer when idle.
