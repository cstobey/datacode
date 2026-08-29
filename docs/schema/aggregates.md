# Aggregate functions and retention

Log data is the highest-cardinality thing DataCode stores and the case routine retention is
written for. Discarding it wholesale loses history that is still worth having at lower
resolution — a year of hourly request counts costs almost nothing next to a year of requests.

`retain` is not confined to it. The same chain collapses a `UserData` version chain
([below](#retain-on-userdata-is-admissible-and-rare)), and `erase` and `scrub` are the separate
administrative acts that destroy bytes on purpose
([../integrity.md](../integrity.md#erasure-restricts-scrub-destroys)).

Two declarations cover retention. A **binding** parameterized by a grain says what to compute; a
**`retain` chain** says at what resolutions and for how long. Together they make "summarize
before pruning" a checked property rather than an operational hope.

```
system.logs.RequestRollup g = system.logs.HttpRequest
  group { truncateTo g created_at as bucket_start, status }
        { bucket_start
        , status
        , count rows            as requests
        , sum   rows.bytes_sent as bytes
        , max   rows.duration   as slowest }

retain system.logs.HttpRequest as RequestRollup
  for 1 day
  , by Hour  for 1 month
  , by Day   for 6 month
  , by Month forever
```

Full-resolution rows for a day, hourly summaries for a month, daily for six months, monthly
forever.

`system.logs.HttpRequest` is declared in [../api.md](../api.md#http-request-logging); this
document cites that declaration rather than restating it. `truncateTo` truncates a `Timestamp`
to a grain boundary in UTC — signature and zone rule in
[types.md](types.md#three-kinds-of-time-quantity).

## Aggregate functions

An aggregate function takes a table and returns a scalar. `count`, `sum`, `min`, `max`, and
`avg` are ordinary library functions with no reserved status, applied like any other function.
For how to write them and how `rows` comes to exist, see [queries.md](queries.md#grouping).

This document covers the one extra requirement a retention chain imposes on them.

### Aggregates in a chain must merge

Each step's source is the step before it, not the raw table. A function is therefore admissible
in a chain of more than one step only if it declares a **commutative associative merge with an
identity** — daily values have to be computable from hourly ones, in any order.

Commutativity is load-bearing, not decoration. Buckets merge across origin servers as well as
across time, and the order two servers' buckets arrive in is not determined, so a merge that is
associative but not commutative — concatenation, first, last — would satisfy the weaker rule and
still give two answers for one day.

| Function | In a multi-step chain |
|---|---|
| `count`, `sum` | Yes. The sum of counts is a count. |
| `min`, `max` | Yes, with the identity adjoined. There is no least `Amount` and no least `Timestamp`, so the identity is `Empty` and the result type is `a \| Empty`. |
| `avg` | Yes, stored as `(sum, count)` and divided on read. The transformation is silent; `avg` is never rejected. Its result type is `Decimal \| Empty` for the same reason. |
| `percentile` | **No.** A daily 95th percentile cannot be recovered from twenty-four hourly ones. |

`Empty` is a `Null`-derived absence type ([types.md](types.md#absence-types)) meaning "the
aggregate had no input rows". Adjoining it is what turns `min` and `max` from semigroups into
monoids, and it is the same value they return over an empty bucket — reachable whenever a bucket
is opened before a row lands in it, or every row in a group is deleted. Reporting `0` there would
be the same lie as reporting `0` for a bucket policy did not keep
([the gap is typed](#the-gap-is-typed)).

The rule is stated as "must declare a merge" rather than as a list of permitted functions, so a
mergeable sketch type — a t-digest for percentiles, a HyperLogLog for distinct counts — becomes
admissible by declaring its merge, with no change to this rule and no change to the grammar.
That is what made the closed `sum | count | min | max | avg` production worth deleting: it
contradicted this rule in the one place a reader would check.

Until such a type exists, `percentile` is valid in a single-step chain (raw to one level) and
rejected beyond it, with an error naming the missing merge.

## A rollup is a parameterized binding

`retain ... as <Name>` names a binding that takes exactly one parameter, of type `Grain`. The
chain applies it once per level, so `RequestRollup Hour` and `RequestRollup Day` are ordinary
applications of one definition.

**The grain is an argument, not an injected column.** An earlier design generated
`bucket_start` automatically and forbade the binding to mention time at all. That put the
observation grain into scope without anything naming it, which is the ambient-time reading the
language rejects everywhere else — nothing may read the clock or the grain inside a functor. As
a parameter it is visible, and the bucketing is an ordinary group key.

Because it is a binding, `where`, `group`, and every function mean what
[queries.md](queries.md) says they mean. There is no second grouping mechanism and no second
declaration form.

### The union

A binding named by a chain denotes the **union of the levels the chain instantiated**, with
`grain` as an ordinary column:

```
system.logs.RequestRollup                      -- all levels
system.logs.RequestRollup where grain == Hour  -- one level
```

The transparent case is the default name and reaching into a level is the marked one. Because a
chain never reshapes, the union is homogeneous: every level has identical columns and only
`grain` differs, so no sum type is needed and no quantity silently changes meaning across the
boundary.

The union covers the **levels**, not the raw rows. A chain's first step instantiates no level, so
the most recent raw window — a day, in the running example — is outside the union, and so is any
bucket whose window has closed but which the maintenance queue has not rolled up yet. A dashboard
summing the union alone under-reports by up to one raw retention period. A complete total is two
queries: the sum over the union, plus an aggregate over the source table restricted to the window
after the newest bucket. Nothing adds them for you, and the second query is the one an author
forgets.

With no chain naming it, the binding denotes nothing queryable, because the grain is unbound.
That is the ordinary reading of an unapplied function.

There is no `by` clause in query position. `by` declares a grain in a chain; `where` selects
one, using the query language that already exists.

### `grain` is a virtual column

Each level is a separate table at a fixed grain, so on a level the grain is a property of the
table rather than of the row and costs no stored bytes
([../transaction-graph.md](../transaction-graph.md#virtual-columns)). Because the predicate is
constant per table, the optimizer treats `where grain == Month` as a table selection rather than
a row filter.

On the union `grain` is not constant, so it is materialized. Rows stay comparable but not
interchangeable: summing `requests` across the union gives a correct total for the levels it
covers, while plotting `requests` per bucket must account for buckets of different widths.
`grain` is the column that lets a consumer do that.

`grain`'s type is `Grain` and `Month` is one of its variants, so this is an ordinary comparison
between a column and a variant. `Hour` the grain and `hour` the `Duration` are different types,
and the case is what tells them apart. See
[types.md](types.md#three-kinds-of-time-quantity).

### Grain order

A chain coarsens along declared **alignment** edges, not by comparing bucket widths. Every grain
names the grain whose buckets its own tile exactly:

```
Minute → Hour → Day → Month → Quarter → Year
                Day → IsoWeek → IsoYear
```

Two roots, and the second is the reason alignment is the rule rather than coarsening. ISO weeks
tile ISO years exactly by construction and tile nothing on the calendar side: the week of
January 29 straddles two months, so `by IsoWeek , by Month` would merge a bucket into a month it
is only partly inside. That step is **rejected** — not because the grain fails to coarsen, but
because it fails to align. An ISO chain runs to `IsoYear` or stops.

Alignment also decides what a width comparison could not. `IsoWeek` is coarser than `Day` and
finer than `Month` while dividing neither evenly, so its position in the order is declared rather
than computed.

Two further consequences:

- **Retention is compared against the successor grain's maximum span.** A step must cover at
  least one complete bucket of the step after it, and `Month` spans 28–31 days, so
  `for 30 day , by Month` is rejected while `for 31 day , by Month` is accepted. Conservative by
  construction, which is what keeps the check decidable.
- **A `Period` retention length is measured at its minimum span**: `month` at 28 days, `quarter`
  at 90, `year` at 365. Both operands then err the same way — minimum on the left, maximum on the
  right — so the check never accepts a chain that could truncate a bucket. Both quantities are
  checker-internal; neither is a `Period`-to-`Duration` conversion a user expression can write
  ([types.md](types.md#three-kinds-of-time-quantity)).
- **An `IsoWeek` level is labelled by ISO year.** December 29–31 can belong to week 1 of the
  following ISO year and January 1–3 to week 52 or 53 of the previous one, so a calendar-year
  label would collide two distinct weeks in one bucket. `bucket_start` is the Monday, which is
  unambiguous on its own; the label an operator reads is the `(isoYear, week)` pair that
  `isoWeekOf` returns.

**A chain does not reshape.** Every level has the identical structure; only the resolution
changes. This is why the binding is named once on the `retain` header rather than per step — a
chain whose steps computed different things would not be a chain, and there is no slot in which
to write one.

## `retain`

Retention is a separate statement from the table declaration for the reason enforcement modes
are ([../integrity.md](../integrity.md#declaring-a-mode)): it is operational policy that changes
over time, it is not the schema author's decision to make, and keeping it out leaves
declarations pure. It is an ordinary schema object — versioned in the graph, queryable,
separately access-controlled.

The grammar is [railroad.md](railroad.md#retention), which also carries the constraints an EBNF
cannot state. A table with no rollup needs no binding:

```
retain system.logs.Debug
  for 7 day
  , drop
```

### Chain steps and terminals

A chain is a comma-separated list of steps closed by a terminal. The first step is the raw
table's own retention; each later step declares a grain and a retention. Every chain ends in one
of two terminals:

| Terminal | Meaning |
|---|---|
| `forever` | Keep at this resolution indefinitely. It takes a grain, so `by Month forever` is a level. |
| `drop` | Discard when the preceding step expires; nothing succeeds it |

`drop` is a **terminal, not a step**: it carries no grain and does not count toward the step
count that decides whether `as` is required. `forever` is a retention length, which is why it
does take one ([railroad.md](railroad.md#retention)).

`drop` rather than `never`, which in a document full of durations reads as "never delete" — the
opposite of what it means.

### Branches

Write several retentions on one table as ordered branches in a single block, with `otherwise`
taking the remainder. First match wins, as in a Haskell guard:

```
retain system.logs.HttpRequest as RequestRollup
  where status >= 500
    for 30 day
    , by Hour forever
  otherwise
    for 1 day
    , by Hour  for 1 month
    , by Day   for 6 month
    , by Month forever
```

One block rather than several statements, because order is load-bearing and separate statements
have no reliable order — you could never insert a specific rule ahead of an existing catch-all.
`otherwise` makes the fall-through explicit rather than implicit in position. Nesting uses the
existing offside rule.

Each branch declares its **whole** chain, and the first-step and terminal rules apply per branch.
Branches share the binding but not the ladder. Here the 5xx branch keeps raw rows four weeks
instead of one and hourly summaries indefinitely, while everything else coarsens to monthly.

> **With a binding, a branch predicate may reference only the binding's group keys and the time
> source. With no binding, it may reference any column of the source.**

The first half keeps buckets whole: otherwise a single bucket could contain rows from two
branches with different lifetimes, and it would have no well-defined retention. Referencing a
non-grouped field is rejected with that reason. In the example, `status` is a group key, so every
bucket row is wholly 5xx or wholly not.

The second half is the unrolled-up case. There are no buckets to straddle, so the only thing the
restriction bought is gone and the predicate may reach any column — which is the shape
`system.integrity.Violation` uses, retaining by predicate with no rollup
([../integrity.md](../integrity.md#retention)). What it costs is stated rather than assumed:

- Where every column the predicate reads is **immutable for the row's lifetime**, the branch is
  decidable when the row is written, is recorded in its segment key, and the segment stays
  prunable as a unit ([../transaction-graph.md](../transaction-graph.md#logdata-shard-roots)).
- Where any of them is **not** — `Violation` branches on `state`, which an operator sets to
  `Repaired` later — the branch is re-read per row at prune time and pruning is a row scan. The
  segment key records the branch as of the write, so it stays a routing hint rather than the
  answer.

The commit diagnostic names which of the two a chain gets, because the difference between them is
a table scan.

### Time source

The chain cuts buckets on `created_at`, which for a native table is derived from the row's
`DataId`. A connector-sourced table whose meaningful time is a column of its own overrides it:

```
retain connectors.mariadb.production.Order as OrderRollup using order_date
  for 90 day
  , by Day forever
```

`using` governs the raw step's expiry and the branch predicates. The binding names its own time
column in its group key, and the two must agree: `OrderRollup g` must group on
`truncateTo g order_date`. A mismatch is a compile-time error, because a chain that expires rows
on one clock and buckets them on another loses data it reports as summarized.

**`using` forfeits segment-unit pruning.** A segment is cut on write time, so under a stored time
column a backfilled row lands in today's segment already expired while a future-dated one never
expires, and a segment holds rows with many different expiries — the condition that makes it
unprunable as a unit ([below](#retention-prunes-whole-segments)). The raw step is pruned by row
scan instead. That is the price of a meaningful clock on connector-sourced data, and it is
permanent rather than a transitional fallback.

The column `using` names must be present at insert and immutable afterwards, for the reason a
branch predicate's columns are ([above](#branches)): expiry that moves after the write cannot be
pinned to anything.

`using` is also the escape when a row's `created_at` is not the time you meant. A re-key mints a
new `DataId`, which resets `created_at` and restarts the raw window
([../transaction-graph.md](../transaction-graph.md#virtual-columns)); a declared `Timestamp`
column named by `using` survives it.

`using` already means "supply a parameter to this construct" on `Hashed`; `on` and `by` are both
taken.

## What gets generated

Each level in a chain — every step carrying a `by`, and a `by` terminal — generates one table at
that grain. The generated table is addressable, so nothing about a level is anonymous:

| Property | Value |
|---|---|
| Name | `<binding>.<Grain>` — `system.logs.RequestRollup.Hour`, `system.logs.RequestRollup.Day` |
| Traits | The source table's, the same inheritance any binding has. A rollup of a `LogData` table is `LogData`. |
| Placement | Where its key puts it. A `LogData` level is rooted at a `system.shards.LogSegment` on the server that summarized the rows; a `UserData` level is placed by `bucketRef` like any other `UserData` table ([tables.md](tables.md#keys-must-be-rooted)). |
| Key | `unique bucketRef { bucket_start, <the binding's other group keys> }`, headed by `origin_server` on a `LogData` level |

The name is what `:describe`, `grant`, and `set visibility` address. A level is not a private
artifact of the chain — it holds most of the retained history, and an access rule that reached
the source and not its summaries would leak by omission.

**On `LogData`, buckets are per origin server.** Each server rolls up its own segments, so a
rollup is server-local work with no coordinator, `bucketRef` is checked against one server's own
levels rather than by a cluster-wide index at rollup cardinality, and reading across servers is
the merge the [chain rule](#aggregates-in-a-chain-must-merge) already requires. That is why
`origin_server` heads the key there: two servers' rows for one bucket are two rows, and summing
them is the merge. `origin_server` is a virtual column, so heading the key with it costs no
stored bytes ([../transaction-graph.md](../transaction-graph.md#virtual-columns)).

`LogData` exempts a table from *needing* a candidate key; it does not forbid one, and a rollup
row is an entity rather than an occurrence
([tables.md](tables.md#candidate-keys-are-mandatory)). The key is what makes catch-up
**idempotent** — recomputing a bucket upserts the same row rather than duplicating it, which is
exactly what a process that plays catch-up after an outage or a policy change needs. The
constraint carries a name because every `unique` does; `bucketRef` is generated, and a schema
object of the same name on the source is a commit-time collision, not a silent shadow.

## Changing a policy

Data cannot be invented, so the five edits are not symmetric:

| Change | Effect |
|---|---|
| **Lengthen** a retention | No backfill. The window it now covers was already rolled up and dropped, so it catches up going forward and leaves a gap until it fills. |
| **Shorten** a retention | Prunes back to the new bound. Destructive and irreversible. |
| **Add a coarser level** | **Backfills**, from the finer level, as far as the finer level still reaches |
| **Add a finer level** | No backfill. Forward only. |
| **Add a column to the binding** | No backfill. Existing buckets lack the input, so they read `NotRetained` — see below. |

Coarsening is reconstructible; refining is not. The system knows which case an edit is and says
so at commit.

An added column is where the generated tables meet the rule that **every field added to an
existing table declares a default** ([evolution.md](evolution.md#redeclare-a-table)). A
projection item has no slot for a type or a default, and it needs neither: the generator widens
the level's column to `T | NotRetained` and defaults it to `NotRetained`. `NotRetained` is a
nullary variant, so it satisfies the rule with no author input, and it already means exactly what
an older bucket holds — the policy did not cover it. Every level in the chain is widened
together, or the union would stop being homogeneous.

A **shortening** edit is rejected at commit and reports its blast radius, on the principle that
adding a predicate to a populated field must state a mode
([../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)):

```
datacode[system.logs]> :commit
error: retain system.logs.HttpRequest shortens raw retention from 7 day to 1 day.
       2 140 883 rows (6.2 GB) become immediately prunable.
       Commit rejected.
```

The rejection is absolute today, and deliberately so: shortening destroys more than `erase` or
`scrub` do, and both of those carry a mandatory `reason` naming the authority in a position the
grammar guarantees ([railroad.md](railroad.md#administration)). Whatever overrides this rejection
must carry one too, and nothing spells it yet. Lengthening, adding a level, and adding a column
all commit without ceremony, because none of them destroys anything.

### The gap is typed

Lengthening leaves a real hole until it fills, and a hole that reads as zero is a lie a dashboard
will act on — a request-rate chart would show a cliff that looks like an outage.

A bucket absent because policy did not cover it resolves to `NotRetained`, a `Null`-derived
absence type (see [types.md](types.md#absence-types)). The type forces consumers to distinguish
"no traffic" from "not kept."

Two absences, not one, because collapsing them puts the dashboard back where it started:

| Reading | Means |
|---|---|
| `0` | The bucket exists and nothing happened in it |
| `NotRetained` | Policy did not cover the bucket, or the chain gained this column after the bucket was written |
| `NotYetRolled` | The bucket's window is still raw, or the maintenance queue has not reached it |

`NotYetRolled` is the commoner of the two and the one a chart hits every time it plots up to the
present. It resolves to a real value once the rollup runs; `NotRetained` never does.

## Pruning is only ever a consequence

> **`LogData` is prunable, not pruned. A row is discarded only when a `retain` chain says its
> retention has expired.**

There is no manual prune of log data — and no row-level `prune` anywhere in the language, for any
trait. `prune` remains an evolution statement for schema objects and orphaned branches
([evolution.md](evolution.md#deprecate-and-prune)), but a `LogData` table under a retention
policy is pruned by that policy and by nothing else, and a `LogData` table with no `retain`
statement is **never pruned at all**. A declared chain is the only path by which a row is
discarded; `erase` and `scrub` destroy bytes on an administrator's authority and are a different
operation with a different audit trail
([../integrity.md](../integrity.md#erasure-restricts-scrub-destroys)).

That default is deliberate. `prune the log shard` is the operation most likely to be run under
pressure, and it must not be able to silently destroy evidence that cannot be reconstructed.
Silence means keep.

The rule is about the chain rather than about the trait, which is why it extends unchanged to
[`UserData`](#retain-on-userdata-is-admissible-and-rare).

### Retention prunes whole segments

A `LogData` shard is rooted at a `system.shards.LogSegment` row keyed by
`{ origin_server, period_start, branch }`
([../transaction-graph.md](../transaction-graph.md#logdata-shard-roots)), where `branch` is the
index of the matching `retain` branch. Where the branch is decidable when the row is written, no
segment holds rows with two different expiries.

An expiring step then covers a **whole sealed segment**, and pruning it is an unlink of that
segment's extents plus one prune node, not a row scan.

Three cases fall back to a row scan, and each is stated where it arises rather than assumed away:

- Segments written before a branch was added or the period changed. Routing is decided at write
  time and never revised, the same forward-only rule that governs every other retention edit
  above.
- A chain declaring [`using`](#time-source), whose expiry runs on a stored column rather than on
  write time. Permanent, not transitional.
- A branch predicate over a column that changes after the write, such as
  `system.integrity.Violation.state` ([above](#branches)).

**None of this is syntax.** There is no partition clause on `retain`. A `shard by <grain>` header
clause was considered and rejected: the segment key already supplies the alignment it would have
declared. The period and the size thresholds are `Configuration` rows, and a table with no
`retain` statement is still partitioned — it is never pruned. *Silence means keep* must
not be allowed to become *silence means one unbounded shard*.

### `retain` on `UserData` is admissible and rare

`retain` names a table, and nothing in it requires that table to carry `LogData`. A long-lived
`UserData` row can accumulate a version chain nobody needs at full resolution, and collapsing
part of one is a legitimate, occasional act.

It stays inside the rule above rather than becoming an exception to it. A `UserData` chain is
declared like any other, and the ordered branch form is what makes "these specific rows"
expressible without a manual prune:

```
retain app.crm.Contact as ContactRollup
  where status is Closed
    by Month for 7 year
    , drop
  otherwise
    forever
```

`ContactRollup` groups on `status` and on `truncateTo g created_at`, which is what makes `status`
legal in the branch predicate ([Branches](#branches)). The closed branch opens with a `by` step
and so keeps no full-resolution versions at all: a contact that reaches `Closed` is collapsed to
monthly as it is written, kept seven years, and dropped. `otherwise forever` is the ordinary
"keep everything", and it is why almost every row here is untouched.

An earlier draft wrote `closed_at < cutoff` in the predicate. `cutoff` was bound nowhere, and a
moving cutoff is ambient time — the thing the language refuses everywhere else. A window that
must move belongs in the chain, where `for 7 year` already expresses it.

Two differences from the `LogData` case, both consequences of shard shape rather than new rules:

- **Pruning is row-level, never segment-level.** A `UserData` shard is rooted at an entity, not
  at a time-keyed segment, so there is no sealed segment to unlink.
- **The version chain over the pruned range is gone**, and anything derived from it goes with
  it. Per-field timestamps are the case that matters, since they are a cache over the chain
  rather than a stored column
  ([../transaction-graph.md](../transaction-graph.md#per-field-timestamps)). They read
  `NotRetained` for a pruned range — a typed gap, not a wrong answer.

Expect this to be rare. It trades the graph's account of how a row reached its value for space,
which is the trade compaction refuses to make automatically, and declaring it as a chain is what
keeps the decision visible in the schema rather than in someone's shell history.

### A rollup is two appends, not a rewrite

Rolling up writes aggregate rows in a new transaction, then records a prune node covering the
source range. Both are ordinary appends. The transaction being replaced is **not** rewritten to
hold the summaries — transaction nodes are immutable, and editing one would be the history
mutation the graph exists to prevent
([../transaction-graph.md](../transaction-graph.md)).

The consequence is that the history stays readable: it says these rows existed, then were
summarized, then were discarded, and when.

Rollup levels are therefore **real tables with their own transaction log entries**, not
materialized views. A materialized view is by definition recomputable from its source; once the
source is pruned, that definition no longer holds. This is one of two places in the design where
something view-shaped cannot be materialization
([../storage.md](../storage.md#materialization)). The other is a binding whose source is
superseded in the same commit, which is frozen into storage for the same reason — the definition
it was written against is no longer current
([evolution.md](evolution.md#how-a-commit-resolves-names)).

The event scheduler executes rollups through `system.events.MaintenanceQueue`, alongside
compaction and view refresh ([../events.md](../events.md)).

## Interactions

**Components.** A `LogData` parent with a `Component` subtree prunes the subtree with it —
already an invariant of `Component`, not a new rule
([traits.md](traits.md#component)). A rollup of the parent discards the components; if their
content matters at lower resolution it belongs in the binding's projection.

**Violations.** `system.integrity.Violation` carries `LogData` and is retained by predicate
rather than by age, because its rows are not equally reconstructible. The chain and the argument
for it are in [../integrity.md](../integrity.md#retention), which owns that table; it is the
worked example of a branched chain with no binding.
