# Event System

The event scheduler is DataCode's mechanism for all deferred and external side effects —
both system maintenance and user-triggered outbound calls. It is not a separate message
broker; the queues are DataCode tables.

## Design principle

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

## The event system is outbound

The scheduler handles **deferred effects**, which are always outbound or internal. Inbound
arrival — a webhook POST, a connector row, an operator API call — is **not an event**. It is
a write, and it belongs to the API surface:

| Direction | Mechanism | Documented in |
|---|---|---|
| Inbound | a route whose functor inserts into a landing table | [api.md](api.md) |
| Outbound / deferred | a queue table with a `handler` | this document |

An inbound webhook is a `system.api.CustomRoute` row. Its **dispatch** verifies the signature
before the functor runs, and the functor inserts into a `LogData` landing table. Verification
is not the functor's own work: a Stripe- or GitHub-style signature is an HMAC over the raw
request body keyed by a stored shared secret, reaching that secret needs `reveal`, and `reveal`
runs in `Effect` — out of reach of a route functor running at `Tx`. Whether that check instead
becomes a `Pure` primitive whose secret access is privileged inside the primitive is recorded
under [OQ-020](open-questions.md#oq-020-webhook-endpoint-security).

Nothing is enqueued, because the row *is* the durable record — there is no side effect to defer
and no external call to keep out of the commit. Whatever should happen next is an ordinary
`on … emit` on the landing table, and the insert case of the false-to-true rule below already
covers it.

Modelling arrival as an event kind was considered and rejected: it would have added a trigger
form providing neither of the two properties the event system exists to provide.

## Triggering an event

There are exactly **two** trigger forms, and both are declared on the producing table:
`on <cond> emit <queue> { … }` and `every <interval> emit <queue> { … } where <cond>`. The
grammar is [`EventDecl`](schema/railroad.md#tables-bindings-traits), which is where any change
to it lands.

`on` observes a transition. `every` samples for one. Which of the six event cases you are
looking at is read off the trigger form and the table it sits on, not off a keyword per case:

| Case | Form | Fires |
|---|---|---|
| Transition over stored fields | `on <cond> emit` | at commit, on `False` → `True` |
| Insert (degenerate transition) | `on <cond> emit` | at insert |
| Crossing of a closed-form `Behavior` | `on <cond> emit` | at the solved moment |
| Open-form behavior, or state DataCode cannot observe | `every <D> emit … where <cond>` | at the first tick where the condition holds |
| Timer ingest — poll an external source | `every <D> emit … where <filter>` | every tick, per matching row |
| Repair | `repair <ref> into <queue>` | on a recorded violation |

The last two rows share one clause and are told apart by its type. See
[`every`](#every--sampling-for-a-transition).

### `on` — firing is a false-to-true transition

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
    order     = self
  }
}
```

`on <condition> emit <queue> { <payload> }`. The payload is an ordinary row construction
against the queue table, so it is typed by the queue's own field declarations — nothing new.
`self` names the producing row, and a `:>` field in the payload stores its `id`. The payload
carries **columns of the queue table and nothing else**: an earlier draft wrote
`payload = { order = id }`, a nested anonymous record, which is both untypable — DataCode has
no anonymous nested table — and the exact shape `system.events.Item` was deleted for.

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
    account = self,
    at_risk = credit_limit
  }
}
```

`balance` is a `Behavior Amount`, and comparison lifts pointwise over a behavior, so the
condition is a `Behavior Bool` — see [types.md](schema/types.md#behaviors).

Nothing samples the row and no last-tick bit is kept. The trigger is a property of the table,
and `fire_at` on the resulting queue row is the solved crossing moment rather than something
the author computed by hand. What solving removes is the **per-row condition sampling**, not
the scheduler's `fire_at` sweep: a dated queue row is still found by the ordinary dispatch
loop. Earlier text claimed "nothing is polled", which the sweep contradicts; the real
comparison is one wake-up per crossing against O(rows × ticks) evaluations plus a write per
edge. See [Behavior-triggered scheduling](#behavior-triggered-scheduling) for what remains
open.

A solved crossing is a `Moment` and `fire_at` is a `Timestamp`. Reifying the first into the
second is admissible here because the scheduler is committing an **intent** rather than
recording an observation, which is the one direction the split permits — see
[types.md](schema/types.md#moment-is-not-timestamp).

**A condition that dereferences a foreign key is re-evaluated when the referenced row
changes.** `on customer.status is Suspended` has the evaluation set an `assert` over the same
paths would have: the FK chain traversed backwards. A write to any row in that set
re-evaluates the trigger. Without the rule the transition is silently missed, because nothing
writes the subject row and so nothing looks. A condition whose evaluation set crosses a shard
boundary is rejected, matching the restriction on `enforce always` — see
[distribution.md](distribution.md#constraints-that-cross-shards-cannot-promise-enforce-always).

**A re-key is one transition, not two.** A write that changes a row's shard root is a delete
plus an insert ([tables.md](schema/tables.md#changing-a-placement-key)), and the predecessor's
post-state is the successor's pre-state. So `on status is Shipped` stays silent across a move
that shipped nothing, and `on customer == vip` fires if the move is what made it true. Read
the insert half in isolation and every true condition re-fires — a second shipment email for a
shipment that already happened.

### `every` — sampling for a transition

Some conditions cannot be solved. An open-form behavior is not in the closed-form-solvable
class; external state is not observable at all until something asks. For those, `every`
declares the sampling interval:

```
table app.ingest.Feed : UserData {
  vendor        :> Vendor,
  url           : URL,
  poll_interval : Duration = 15 minute,
  active        : Bool = True,

  unique feedOf { vendor, url },

  every poll_interval emit app.ingest.PriceRefresh { source = self } where active
}
```

Five properties, none of which needed a new construct:

**The interval is an expression, not a literal.** Any `Read` expression of type `Duration`
serves: a `LengthLit` (`every 15 minute`), a field of the row (`every poll_interval`), or a
field reached through a foreign key (`every vendor.ingest_policy.interval`). This is what makes
an interval tunable without an override mechanism — point the expression at wherever the tuning
should live. It is re-read each tick, so a `Configuration` write takes effect on the next one.

Reach a shared `Configuration` value **by foreign key**, not by bare path. A path like
`system.config.Ingest.interval` names a table and a column but no row, so it does not resolve
to a value; earlier drafts used that spelling and the table it named was never declared.

The scheduler clamps below a floor held in `system.events.SchedulerLimit`, so `every 1
millisecond` cannot be introduced by a data edit. A literal below the floor is rejected at
schema commit instead of clamped, since the author can see it.

**It fires per row of the table it is declared on.** Fan-out is not a feature of `every`; it is
what "declared on a table" already means, exactly as `on` fires per row. One `Feed` row per
vendor endpoint gives one work item per endpoint per tick.

**`where` both restricts rows and carries the sampled condition, and its type says which.**

> A conjunct of type `Bool` — decided by the row's stored fields — **restricts which rows are
> sampled**. A conjunct of type `Behavior Bool`, or one reading state DataCode cannot observe
> at a write, **is the sampled condition**.

The rule derives rather than being chosen. `on` already observes every transition a write can
produce, so a condition over stored fields never needs sampling; if a trigger needs `every` at
all, the part that needs it is exactly the part a write cannot decide. This is the same
structural reading that recognizes a `Priority` field by its type and an assert's variety by
its body, rather than by a keyword the author has to remember.

Two consequences, and they are the two rows of the case table:

- `where active` and `where enabled` are pure row filters, so a feed poll and a connector poll
  fire **every tick, per matching row** — which is what timer ingest means. Deactivating a feed
  stops it; reactivating it starts it again.
- `where balance >= credit_limit` is `Behavior Bool`, so it is the sampled condition and fires
  on a crossing. A credit line that stays over limit enqueues once, not once every 30 second.

A clause may carry both. `every 1 hour emit … where active && balance >= credit_limit` samples
the crossing only for rows the filter admits.

```
every 30 second emit app.events.OverlimitQueue { account = self } where balance >= credit_limit
```

**There is no standalone or top-level cron form, and none is needed.** A timer job always has
rows that parameterize it — which feed, which directory, which account — and that row's table
is the producing table. A job with genuinely no parameterizing row is server maintenance, which
is `system.events.MaintenanceQueue` and not user syntax. Making `every` a `BodyItem` rather
than a `Statement` is what keeps the payload typed against a row it can name.

**False-to-true still holds for the sampled half.** `every` samples that conjunct at each tick
and fires only on a transition — observed between ticks instead of across a write. That costs
a last-tick bit per `(trigger, row)`, recorded as an appended edge rather than as a field
rewritten in place. A trigger with no sampled conjunct costs nothing at all, which is most
timer ingest:

```
table system.events.TriggerState : LogData {
  trigger : FunctorRef,
  subject : DataId,
  held    : Bool
}
```

**The table records edges, not samples.** A row is appended when `held` changes, and the
current value for a `(trigger, subject)` pair is the `held` of its latest row. That keeps the
table append-only, as `LogData` requires, with no exemption asked for. A per-tick rewrite would
need one, and it would grow with ticks rather than with events: `every 30 second` on a single
row is 2,880 rows a day, forever. The row's own `created_at` is the sample moment, so no
`sampled_at` field is declared.

Edges also bound the cost against something an operator already watches. A `True` edge
accompanies every firing and a `False` edge every reset, so `TriggerState` grows at most **two
rows per queue row** the trigger produces. A flapping condition then shows as edge volume
instead of disappearing into a counter.

There is deliberately **no `retain` chain** on it. The head edge of each pair is live state
rather than history — pruning it re-fires the trigger — and silence means keep. The tail is
prunable by the maintenance pass that prunes the queue it feeds, which skips the head edge for
each pair.

`subject` is a bare `DataId`, and it resolves through the re-key chain, so a row that moves
shards keeps its held bit instead of arriving at its new key with none. See
[transaction-graph.md](transaction-graph.md).

That cost is the argument for preferring a solved crossing wherever one exists, so **schema
commit warns when `every` carries a sampled conjunct the solver could have closed**, and names
it:

```
datacode[app.billing]> :commit
  app.billing.CreditLine: `every 30 second … where balance >= credit_limit` samples a
  condition the solver can close (balance is linear in Moment). Drop `every` to solve it.
```

### One scheduler

Connector polling is a scheduled event under this scheduler, not an independent loop with its
own interval, backoff, and priority notions. A connector's two loops are two `every`
declarations on the connector row:

```
every poll_interval  emit system.connectors.SyncQueue   { connector = self } where enabled,
every latency_window emit system.connectors.VerifyQueue { connector = self } where enabled
```

Both `where` clauses are row filters over a stored `Bool`, so each fires every tick for every
enabled connector. `system.connectors.Connector` is declared once, in
[connectors.md](connectors.md#polling-is-a-scheduled-event).

Because that table carries `Configuration`, retuning either interval is a data write with no
schema commit — which is what [connectors.md](connectors.md#dynamic-configuration) already
promised, now with no second mechanism behind it. Two schedulers would have meant two retry
policies, two backoff states, and no way to reason about total outbound load.

## Queue tables

A queue table carries the `Queue` trait, which extends `LogData` and supplies `fire_at` — the
moment an item becomes eligible, fixed at enqueue or at a solved crossing and never rewritten.
Four structural rules make a queue a queue, checked at schema commit rather than written in the
trait body: exactly one `handler`, exactly one `:>` field to a table carrying `QueueState`, at
most one field whose type is `Priority`, and append-only everywhere but that `QueueState`
field. The trait bodies and the rules are stated in
[schema/traits.md](schema/traits.md#queue-and-queuestate).

```
table app.auth.LdapSync : Queue {
  subject :> User,
  scope   : SingleUser | FullRefresh,
  urgency : Priority = urgent,
  state   :> LdapSyncState = Requested,

  handler system.connectors.ldap.syncUser
}
```

**A queue's `:>` never blocks a delete.** Non-`Component` foreign keys restrict rather than
cascade, but the restriction counts references from current-state tables only — a queue with no
`retain` chain is never pruned, so counting it would make deleting that user permanently
impossible ([tables.md](schema/tables.md#deleting-a-referenced-row)). Where the subject may
plausibly vanish before the item runs, declare the field with a `Null`-derived variant
(`subject :> User | NotFound`) so the handler sees it rather than the resolution failing.

`handler` was previously valid on any table carrying `LogData`. It is now valid only on a
`Queue`, which is tighter and says what was meant: a log is not a work list. The handler name
is a `QName` whose last segment must not be a reserved word — this one was
`system.connectors.ldap.sync` until `sync` was reserved by `force sync`.

**Queue tables carry `LogData`, and they carry it for a structural reason.** A queue item is
an *occurrence*: two identical enqueues are two distinct work items, and collapsing them
would be a bug. That is the same property that exempts logs from the candidate-key
requirement — occurrences have no identity beyond their occurrence. See
[schema/tables.md](schema/tables.md#candidate-keys-are-mandatory).

**A queue row is written to the producing row's shard**, exactly as its attempt rows are.
`LogData` on a `Queue` governs retention and durability class, not placement — so `emit` adds
no second participant and a commit that enqueues is not a cross-shard transaction
([distribution.md](distribution.md#cross-shard-transactions)). The rule holds for a
`Configuration` or `Reference` producer too, because a row's `every` declarations tick on that
row's shard primary and nowhere else
([dynamic-loading.md](dynamic-loading.md#the-scheduler-ticks-on-the-primary)).

### Queue state

The `QueueState` field is one of the narrow exemptions from `LogData` append-only: one field,
on a `Queue` table, with named writers. It is not the *only* one in the system —
`system.integrity.Violation.state` is the other, waived and acknowledged by ordinary mutation —
and the enumerated list lives with the trait in
[schema/traits.md](schema/traits.md#queue-and-queuestate). Anything else that needs recording
after the fact goes in its own `LogData` table with a `:>` back to the queue row, an ordinary
foreign key and no new mechanism. The attempt history below is that rule applied to the
scheduler's own bookkeeping.

The state enum is declared per queue, because `Bound`, `Applied`, and `PartiallyApplied` are
domain facts a polling client needs to read. The scheduler needs something narrower, so each
state declares its **disposition**, and one state per disposition is marked **selectable**:

```
table app.auth.LdapSyncState : QueueState {
  retryable  : Bool = True,
  selectable : Bool = False
}
```

`disposition` is many-to-one over states — `Bound` and `Applied` are both `InFlight` here — so
a disposition alone does not name a row, and "advance the row to a `Done` state" would be
ambiguous the moment a queue declares two. `selectable` resolves it: the scheduler only ever
writes the one selectable state per disposition, and the handler owns the rest.

The client reads `state.name`; the scheduler reads `state.disposition`. `QueueState` extends
`Reference`, so adding a state is a schema commit and `state is Bound` is checked at
schema-commit time ([schema/traits.md](schema/traits.md#reference-tables-are-code)).

This is what makes a request/response event expressible with no second mechanism. The LDAP
on-demand lookup inserts an `LdapSync` row, the client polls that row, and the handler advances
the state as it goes. Waiting on the transition rather than re-polling is an API concern — see
[api.md](api.md) — not schema syntax.

### Attempt history

Retries are occurrences, so they are rows rather than counters. One table is generated per
queue table and sharded with the queue rows it describes:

```
table app.auth.LdapSyncAttempt : LogData {
  subject     :> app.auth.LdapSync,
  started_at  : Timestamp,
  destination : Text,
  outcome     : Succeeded | FailedRetryable | FailedTerminal,
  error       : Text | NotGiven
}
```

A generated table is a **sibling** named after its parent, not a child path: an
`UpperCamelCase` segment in path position would break the lowercase-namespace rule, and
siblings are already what an inline sub-table produces
([tables.md](schema/tables.md#inline-sub-tables)).

`attempt_count` is a count over this table, the next dispatch moment is computed from backoff
over it, and a flapping destination is visible per item instead of collapsed into an integer.
`destination` is written by the handler, which is the only thing that knows where the work
went, and it is what makes per-destination backoff computable at all. This replaces
`system.events.Item`, which no longer exists — see [System tables](#system-tables).

### Priority

Priority is **per item**, defaulted per field, and recognized **structurally**: the scheduler
dispatches in order of the field whose *type* is `Priority`, not the field whose *name* is
`priority`. Two `Priority` fields on one queue is a compile-time error.

```
type Priority : Int where inRange (-20) 19

urgent : Priority
urgent = -10

normal : Priority
normal = 0

background : Priority
background = 10
```

Nice semantics: lower is more urgent, and the range is `nice`'s. Arithmetic matters because the
scheduler **ages** waiting items toward urgency; without aging, a background item behind a
saturated urgent queue starves. The aged value is computed at dispatch and never stored:

```
effective = clamp (-20) 19 (declared - waiting / aging_rate)
```

`declared` is the item's `Priority`-typed field and `waiting` is the elapsed time since
`fire_at`. That is what makes `aging_rate : Duration` in `system.events.QueuePolicy` well
formed — it reads as "one point of urgency per `aging_rate` waited". The clamp keeps the
result inside `Priority`'s own `where`, which an unclamped subtraction would leave.

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

The consequence is that handlers are **compiled in**, not dynamically loaded.

### The handler ABI

Two types and two functions, plus `Row q`, `State q` and `Config`, which are generated. The
author writes only the lambda:

```haskell
newtype Handler q                    -- one per queue table, registered by name

handler  :: Text -> (Row q -> Config -> Effect Outcome) -> Handler q
setState :: Row q -> State q -> Tx ()

data Outcome
  = Succeeded
  | FailedRetryable Text
  | FailedTerminal  Text
```

- `Row q` and `State q` are generated from the queue table and its `QueueState` table. A
  DataCode `QName` maps to a Haskell module path segment by segment — `app.auth.LdapSync` to
  `App.Auth.LdapSync` — and each `Reference` row of the state table becomes a nullary
  constructor of `State q`, so `Bound` is a value. A sum-type variant becomes a constructor the
  same way, so `SingleUser` is a pattern.
- `Config` is the queue's `system.events.HandlerConfig` row.
- An escaping exception is `FailedTerminal` carrying the rendered exception. Nothing is retried
  on a promise the code did not make.
- `HandlerConfig.timeout` bounds the whole invocation. A `commit` already in flight settles by
  its own rules and the cancellation lands after it, so a timed-out handler never leaves a
  partial transaction.

```haskell
-- a handler module compiled into the server
ldapSync :: Handler App.Auth.LdapSync
ldapSync = handler "system.connectors.ldap.syncUser" $ \row cfg -> do
  conn <- bind (cfgHost cfg) (cfgCredential cfg)
  commit $ setState row Bound
  case scope row of
    SingleUser  -> syncOne conn (subject row)
    FullRefresh -> syncAll conn          -- commits in batches
  commit $ setState row Applied
  pure Succeeded
```

`setState` exists because `row { state = Bound }` is a Haskell record update producing a value,
not a `Tx a`, so it cannot be an argument to `commit`. The state write is the one privilege a
handler has, so it gets the one combinator.

The `Handler` newtype supplies everything else — retry, backoff, timeout, concurrency limiting,
priority dispatch, and capability injection. A handler never writes retry logic.

**Arbitrary Haskell means `Effect` reaches `IO`, and nothing else does.** An LDAP bind, an SMTP
send, or an S3 put comes from a library typed in `IO`, so "arbitrary" would be false without a
way in. `Effect` wraps `IO` and is constructed only through capability-granting primitives, so
a handler reaches exactly the hosts, credentials and timeouts its `HandlerConfig` row grants.
There is no lift from `IO` into `Pure`, `Read`, or `Tx` — the ladder below `Effect` never sees
it. See [schema/functions.md](schema/functions.md#the-effect-ladder).

**A handler's writes are ordinary transactions.** `commit :: Tx a -> Effect a` is available, so
a handler writes as much and as often as it likes, and every write is subject to the full set of
validations, asserts, and access rules. A handler is not privileged; its one privilege is the
`QueueState` field of its own queue's row.

**`commit` fixes what survives a retry, not what is skipped.** A retry re-enters the handler at
its first statement — the scheduler calls `Row -> Config -> Effect Outcome` again, and there is
no continuation to resume from. What a `commit` buys is that its writes are durable, so the
retry can *observe* them and skip work already done. That is why a full refresh committing per
batch resumes at the last committed batch: it reads the cursor it committed. Every external
call must therefore be idempotent or guarded by state the handler committed, and the queue
row's `QueueState` field is the intended cursor. An earlier phrasing — "everything after the
first `commit` is not redone" — promised a resumption the runtime does not provide.

**Capabilities come from the config row, never from the code.** `cfg` is the only source of a
host, a credential, or a timeout, so a handler cannot reach a destination the operator has not
granted and never holds a credential in a compiled constant. Two mechanisms enforce that, and
they move at different speeds:

- **Coarse capability is fixed per generation** — the network namespace, service account and
  credential mount the handler pool starts with. Changing one recycles the pool, exactly as a
  new build does. This is the OS enforcing the `Effect` boundary, which is why the pool is a
  separate process ([dynamic-loading.md](dynamic-loading.md#handler-workers-are-a-separate-pool)).
- **`allowed_hosts` is fine-grained and hot.** The handler runtime checks it on each outbound
  call, so an operator narrows a destination with a `Configuration` write and no restart.

Neither half is convention: the first is the kernel, the second is the runtime that owns the
socket.

### Registration is two rows

Handler **existence** is code, so it is `Reference` and compile-checked. Handler **tuning** is
operations, so it is `Configuration` and hot.

```
table system.events.Handler : Reference {
  name       : Text unique,
  queue_type :> system.schema.Table
}

table system.events.HandlerConfig : Configuration {
  target        :> Handler unique,
  timeout       : Duration,
  concurrency   : Int,
  allowed_hosts : Doc,
  credential    :> Credential | NoCredential
}
```

Two corrections carried by that pair. The config row's field is `target`, not `handler`:
`handler` is a reserved word that starts a `HandlerDecl` inside a table body, so
`handler :> Handler unique` does not parse. And a table is named with `:>` to
`system.schema.Table`, the idiom [integrity.md](integrity.md) already uses, rather than with an
undefined `TypeRef`. `effect_sig` is gone with it — every handler has the same signature,
`Row q -> Config -> Effect Outcome`, so the only varying part is `q`, which `queue_type`
already names.

`handler system.connectors.ldap.syncUser` on a queue table names the `Reference` row, so a
mistyped handler name is a schema-commit error rather than a runtime dispatch failure — the
same check `status is Shipped` gets.

Adding a *new* handler requires a build and a **generation swap on the handler pool**: the
router, the data workers, and every live schema ref are untouched, and there is no downtime.
See [dynamic-loading.md](dynamic-loading.md#generation-swap) and
[Build-then-merge](dynamic-loading.md#build-then-merge). Earlier text called this a
schema-daemon restart under "OQ-001's multi-daemon layer" — the layer OQ-001 replaced with the
generation pool. The build itself is acceptable because handlers arrive at the rate of new
**integrations**, not new business rules: SMTP, HTTP POST, LDAP bind, S3 put. Business rules
are functors, they go through the DSL, and they need no swap. Retuning an existing handler is a
`Configuration` write with no swap at all.

## Repair queues

The `repair` enforcement mode binds a validation to a queue table, so that a row which
violates it is not merely recorded but handed to an automated remediation functor:

```
repair app.crm.Contact.postal_code / isDeliverable into app.events.RepairQueue
```

This is what makes "fix the data problems, or at least monitor them" one mechanism rather than
two: `repair` is `monitor` plus an enqueue, and the scheduler's existing retry policy, backoff,
and observability apply unchanged. A repair functor that cannot fix a row leaves the violation
open, which is the correct outcome — it becomes an operator's problem rather than disappearing.

`into` names an ordinary queue table, the same binding `emit` makes; why the two statements
keep different spellings is in [integrity.md](integrity.md#enforcement-modes).

### Why repair is deferred

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

## Internal effects are derived, not triggered

A row that must exist whenever its parent exists is a **total function of the parent**, not an
event. `Component` already owns lifetime and a `DefaultClause` on a component field already
constructs the row inside the parent's own transaction, so the default-table case is existing
syntax composed: nothing fires and nothing is enqueued. The mechanism, both default shapes on a
`:>` field, and the worked example are in
[tables.md](schema/tables.md#a-component-default-constructs-the-row).

**Deleting a parent deletes its components, in the same transaction.** That is not a trigger
either; it is the same statement about lifetime read in the other direction, mechanical over
`Component` edges with no cascade declaration and no depth limit to configure, because the
edges *are* the ownership. Non-`Component` foreign keys never cascade.

**A cross-table in-commit trigger to a non-`Component` table is refused.** If a row must exist
atomically with another and it has independent identity and lifetime, that is a modelling error:
make it a component, or derive it. Admitting the general case would put arbitrary
user-authored mutation inside the commit path with unbounded cascade depth, order-dependence,
and a commit whose cost is not readable from the schema.

Several classic trigger use-cases do not survive contact with the rest of the design, and are
listed so they are not reinvented:

| Classic trigger | What DataCode does instead |
|---|---|
| Audit / history rows | Nothing. The transaction graph **is** the audit log. |
| Denormalized counters, derived status | A projected field or a `Behavior`. |
| `created_by = current_user` | A field default: `created_by :> User = authed_user`. |
| Sequence allocation | A field default: `order_num : Int = next orderRef`. See [tables.md](schema/tables.md#sequences). |
| Materialized view refresh, index maintenance | In-commit per OQ-027, or `system.events.MaintenanceQueue`. |
| `Reference` variant tag allocation | Internal and mechanical. |
| Cascade delete of owned rows | Mechanical over `Component` edges, above. |

The two field defaults in that table work on a **new** table and on new rows. Neither may be
added to a table that already has rows: an added field's default must be `Pure` and stable for
the life of the row, and `authed_user` is transaction-ambient input while `next` allocates.
Adding either to a populated table is a bulk mutation, not a schema edit — see
[evolution.md](schema/evolution.md#every-added-field-declares-a-default).

## System tables

Two tables that were specified here no longer exist, and both were removed by deletion rather
than replaced.

**`system.events.Item` is gone.** It carried `payload : Bytes`, which duplicated the queue row —
the payload existed in two places, could diverge, and "the queue is inspectable with standard
DataCode tools" is false of a blob. Its other three fields decomposed: the eligible moment is a
field of the `Queue` trait, `status` was a second authority for a fact the `QueueState` field
already holds, and `attempt_count`/`last_error` became the
[per-queue attempt history](#attempt-history), which is a better record than a counter.

**`system.events.Queue` is gone.** A queue's existence and its handler binding are *already*
schema facts — `table … : Queue { … handler … }` is the declaration — and a `Reference` table
restating that would duplicate the schema graph into a table, when the schema graph is already
queryable. `system.events.Handler` earns its place for the other reason a `Reference` table is
warranted: it is the bridge that makes `handler system.connectors.ldap.syncUser` resolve
against compiled-in Haskell, which originates outside the schema graph. Queues do not. Both
warrants are stated in
[schema/traits.md](schema/traits.md#when-a-reference-table-is-warranted).

What remains is operational, and therefore `Configuration`:

```
table system.events.QueuePolicy : Configuration {
  queue                  :> system.schema.Table unique,
  max_attempts           : Int,
  backoff_base           : Duration,
  backoff_max            : Duration,
  aging_rate             : Duration,
  failure_window         : Duration,
  failure_rate_threshold : Decimal,
  volume_limit           : Int
}

table system.events.BackoffState : Configuration {
  destination : Text unique,
  hold_until  : Timestamp | NotHeld
}

table system.events.SchedulerLimit : Configuration {
  server        :> system.shards.Node | AllServers unique,
  min_interval  : Duration,
  max_in_flight : Int
}
```

Three decisions are visible in those declarations.

**`QueuePolicy` holds thresholds only.** `concurrency` was declared here *and* on
`HandlerConfig` with no precedence rule, and a handler may serve several queues — which is the
deciding case for per-item priority two sections above — so it belongs to the destination the
handler talks to and stays on `HandlerConfig` alone. `default_priority` was a second authority
for a value the field's own `DefaultClause` already supplies, and a queue with no `Priority`
field had nowhere to put it. Priority is per item, defaulted per field.

**`BackoffState` holds one operator-set value.** It previously carried `failure_rate` and
`volume_count` — measurements, on a trait whose test is "an operator's judgement", written on
every success and failure, replicated to every server. Those are the collapsed counters the
attempt history exists to replace; see [Volume-based backoff](#volume-based-backoff). What is
left is a forced hold, which is a judgement and nothing else.

**`SchedulerLimit` has a key.** `Configuration` is not among the exemptions from the
candidate-key rule ([tables.md](schema/tables.md#candidate-keys-are-mandatory)) and this table
declared none. Keying it by server supplies one and makes `max_in_flight` mean what it reads
as, a per-host ceiling. Resolution is most-specific-first — the ticking server's row, else the
`AllServers` row — the same shape `system.shards.DurabilityPolicy` uses. Schema commit has no
server in hand, so the rejected-literal check reads the `AllServers` row.

Server maintenance has a queue of its own:

```
table system.events.MaintenanceQueue : Queue {
  kind    :> MaintenanceKind,
  subject : DataId | NotApplicable,
  urgency : Priority = background,
  state   :> MaintenanceState = Requested,

  handler system.events.runMaintenance
}
```

It carries log compaction, shard splits, materialized view refreshes, retention rollups and the
prunes that follow them, LMDB vacuum, index rebuilds, and orphaned branch cleanup.
`system.events.MaintenanceKind` is a `Reference` table holding one row per kind of work, and
the one handler branches on it — a `Queue` declares exactly one handler, so seven unrelated
kinds cannot each bring their own. `system.events.MaintenanceState` carries `QueueState` and
adds nothing to it; the trait already supplies `name` and `disposition`.

Rows are enqueued by the server itself, from a producer deliberately outside `EventDecl`: a
maintenance job has no parameterizing row, which is the one case `every` refuses to cover.
Operators **read** the queue like any other table and never write it, so maintenance scheduling
is observable through DataCode like everything else.

## Volume-based backoff

The scheduler backs off by **volume**, not by time alone. Two reasons:

- A destination may be healthy but rate-limited. Backing off by time alone starves other
  destinations sharing the same worker pool.
- A destination may have started failing *because* of volume — the caller is overwhelming it —
  and the correct response is to reduce volume, not to delay.

Every input is derived from the attempt history, which is where the occurrences already are:

1. **Failure count** is the run of consecutive failed attempts for one item. The delay is
   `backoff_base × 2^failure_count`, capped at `backoff_max`.
2. **Failure rate** is failed over total attempts against one `destination` within
   `failure_window`. Above `failure_rate_threshold`, that destination enters backoff.
3. **Volume** is the attempt count against that destination in the same window. Above
   `volume_limit`, dispatches to it are throttled regardless of failure rate.
4. **Jitter** randomizes the delay by ±20%, so a recovered destination is not hit by a
   thundering herd.

Two properties follow from where the destination lives. It is known only *after* dispatch,
because the handler chooses it inside compiled Haskell the scheduler cannot inspect — so
throttling reads the destination mix of the recent attempt history rather than of the pending
queue, and "queue depth per destination" is not a quantity that exists before dispatch. And the
thresholds are operator judgement, so they are `QueuePolicy` fields, while the measurements are
not, so no table stores them.

An operator who wants a destination stopped outright sets `hold_until` on
`system.events.BackoffState`. That is adjustable without a server restart in the way the
measured values never were.

## Scheduler architecture

The scheduler is its own process, one per host, generation-tagged with the handler pool, and a
row's `every` declarations tick on that row's shard primary and nowhere else. Both facts belong
to the process topology — see
[dynamic-loading.md](dynamic-loading.md#the-scheduler-ticks-on-the-primary). What follows is
the loop:

1. Select queue rows whose `state.disposition is Pending` and whose next dispatch moment has
   arrived, in aged-priority order. That moment is `fire_at` for a first attempt, and the last
   attempt's `started_at` plus the backoff derived from the attempt history afterwards.
2. Advance the row to the queue's selectable `InFlight` state. The shard primary linearizes
   that write, which is what excludes double-dispatch across hosts.
3. Call the queue's handler with the row and the handler's `Configuration` row.
4. On `Succeeded`, append a `Succeeded` attempt row. The handler has normally advanced the
   state already; if it has not, the scheduler advances it to the queue's selectable `Done`
   state.
5. On a failure, append the attempt row with its error and return the row to the selectable
   `Pending` state — or to the selectable `Failed` state on `FailedTerminal`, or once
   `max_attempts` is reached. The attempt row is what moves the next dispatch moment, so
   **no field on the queue row is rewritten**. That is what keeps the queue append-only apart
   from its one exempt field; an earlier design rewrote `scheduled_at` on every retry, against
   the queue's own fourth structural rule.

**The scheduler and the handler write the same field and own different halves of it.** Step 2
has to run before step 3 or nothing prevents double-dispatch, so the scheduler necessarily
writes the `QueueState` field of a row whose handler has not run yet. The split: the scheduler
owns the `Pending` → `InFlight` → terminal transitions and writes only selectable states; the
handler owns the domain-meaningful states in between. Both are named writers of the one exempt
field.

The poll interval is adaptive — shorter when the queue is non-empty, longer when idle.

## Behavior-triggered scheduling

A condition over stored fields is decided at commit, so it costs the scheduler nothing. A
condition over a behavior is different: the scheduler must compute *when* the condition will
first hold and arrange to wake at that moment. Three things follow, and none of them is
settled — see OQ-034 in [open-questions.md](open-questions.md).

**Solving.** The crossing moment must be derived in closed form, which is what restricts
behaviors to an analyzable class. The class, the solver per class, and the encoding of both
in the GADT DSL are open. The event functor itself is no longer the unvalidated kind it was
— `spikes/functor-dsl` encodes both trigger forms, producing an `EventRef` rather than an
`Either`, and implements the classifier that decides whether a sampled condition is one the
solver *could* have closed, since the `every`-was-unnecessary warning needs it. What has no
evidence behind it yet is the solver, not the kind.

**Re-solving on write.** A behavior closes over stored fields, so writing the row changes the
function and moves the crossing. Every pending wake-up derived from a behavior on that row
has to be recomputed at commit, and an item already enqueued may have been enqueued for a
crossing that no longer happens. Whether such an item is withdrawn, or dispatched with the
condition re-checked at fire time, is open.

**Missed crossings.** If the server is down across a crossing moment, the event can fire late
or not at all. "The trial expired" wants to fire late; "the rate-limit window opened" may not.
The policy — and whether it is per queue or per trigger — is open.

**`every` is the escape hatch, not the answer.** A condition the solver cannot close is
expressible today by sampling it, at the cost of `TriggerState` edges and a bounded lateness of
one interval. That makes behaviors *usable* before OQ-034 is answered; it does not answer it,
because sampling reintroduces exactly the per-row condition evaluation that solving exists to
eliminate. The solver's job is to shrink the set of conditions for which `every` is the only
option.
