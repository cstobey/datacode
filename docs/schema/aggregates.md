# Aggregate functions and retention

Log data is the highest-cardinality thing DataCode stores and the only thing it is permitted to
discard. Discarding it wholesale loses history that is still worth having at lower resolution —
a year of hourly request counts costs almost nothing next to a year of requests.

Two declarations cover this. A **binding** parameterized by a grain says what to compute; a
**`retain` chain** says at what resolutions and for how long. Together they make "summarize
before pruning" a checked property rather than an operational hope.

```
RequestRollup g = system.logs.HttpRequest
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

## Aggregate functions

An aggregate function takes a table and returns a scalar. `count`, `sum`, `min`, `max`, and
`avg` are ordinary library functions with no reserved status, applied like any other function.
For how to write them and how `rows` comes to exist, see [queries.md](queries.md#grouping).

This document covers the one extra requirement a retention chain imposes on them.

### Aggregates in a chain must merge

Each step's source is the step before it, not the raw table. A function is therefore admissible
in a chain of more than one step only if it declares an **associative merge with an identity** —
daily values have to be computable from hourly ones.

| Function | In a multi-step chain |
|---|---|
| `count`, `sum` | Yes. The sum of counts is a count. |
| `min`, `max` | Yes |
| `avg` | Yes, stored as `(sum, count)` and divided on read. The transformation is silent; `avg` is never rejected. |
| `percentile` | **No.** A daily 95th percentile cannot be recovered from twenty-four hourly ones. |

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

With no chain naming it, the binding denotes nothing queryable, because the grain is unbound.
That is the ordinary reading of an unapplied function.

There is no `by` clause in query position. `by` declares a grain in a chain; `where` selects
one, using the query language that already exists.

### `grain` is a virtual column

Each level is a separate table at a fixed grain, so on a level the grain is a property of the
table rather than of the row and costs no bytes — the same way `created_at` is derived from the
`DataId` (see [tables.md](tables.md)). Because the predicate is constant per table, the
optimizer treats `where grain == Month` as a table selection rather than a row filter.

On the union `grain` is not constant, so it is materialized. Rows stay comparable but not
interchangeable: summing `requests` across the union gives a correct total, while plotting
`requests` per bucket must account for buckets of different widths. `grain` is the column that
lets a consumer do that.

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

```
retain <Table> [ as <Binding> ] [ using <field> ]
  <branch>*
```

Retention is a separate statement from the table declaration for the reason enforcement modes
are ([../integrity.md](../integrity.md#declaring-a-mode)): it is operational policy that changes
over time, it is not the schema author's decision to make, and keeping it out leaves
declarations pure. It is an ordinary schema object — versioned in the graph, queryable,
separately access-controlled.

A table with no rollup needs no binding:

```
retain system.logs.Debug
  for 7 day
  , drop
```

### Chain steps and terminals

A chain is a comma-separated list. The first step is the raw table's own retention; each
subsequent step declares a grain and a retention. Every chain ends in one of two terminals:

| Terminal | Meaning |
|---|---|
| `forever` | Keep at this resolution indefinitely |
| `drop` | Discard when the retention expires; nothing succeeds it |

`drop` rather than `never`, which in a document full of durations reads as "never delete" — the
opposite of what it means.

### Branches

Write several retentions on one table as ordered branches in a single block, with `otherwise`
taking the remainder. First match wins, as in a Haskell guard:

```
retain system.logs.HttpRequest as RequestRollup
  where status >= 500
    for 30 day
    , by Hour for 1 year
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

Each branch declares its **whole** chain. Branches share the binding but not the ladder.

> **A branch predicate may reference only the binding's group keys and the time source.**

Otherwise a single bucket could contain rows from two branches with different lifetimes, and the
bucket would have no well-defined retention. Referencing a non-grouped field is rejected with
that reason. In the example, `status` is a group key, so every bucket row is wholly 5xx or
wholly not.

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

`using` already means "supply a parameter to this construct" on `Hashed`; `on` and `by` are both
taken.

## What gets generated

For each chain step past the first, one table at that grain, keyed by

```
unique { bucket_start, <the binding's other group keys> }
```

`LogData` exempts a table from *needing* a candidate key; it does not forbid one, and a rollup
row is an entity rather than an occurrence
([tables.md](tables.md#candidate-keys-are-mandatory)). The key is what makes catch-up
**idempotent** — recomputing a bucket upserts the same row rather than duplicating it, which is
exactly what a process that plays catch-up after an outage or a policy change needs.

## Changing a policy

Data cannot be invented, so the four edits are not symmetric:

| Change | Effect |
|---|---|
| **Lengthen** a retention | No backfill. The window it now covers was already rolled up and dropped, so it catches up going forward and leaves a gap until it fills. |
| **Shorten** a retention | Prunes back to the new bound. Destructive and irreversible. |
| **Add a coarser level** | **Backfills**, from the finer level, as far as the finer level still reaches |
| **Add a finer level** | No backfill. Forward only. |
| **Add a field to the binding** | No backfill. Existing buckets lack the input. |

Coarsening is reconstructible; refining is not. The system knows which case an edit is and says
so at commit.

A **shortening** edit reports its blast radius before it runs, on the principle that adding a
predicate to a populated field must state a mode
([../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)):

```
datacode[system.logs]> :commit
error: retain system.logs.HttpRequest shortens raw retention from 7 day to 1 day.
       2 140 883 rows (6.2 GB) become immediately prunable.
       Re-issue with `confirm` to proceed.
```

### The gap is typed

Lengthening leaves a real hole until it fills, and a hole that reads as zero is a lie a dashboard
will act on — a request-rate chart would show a cliff that looks like an outage.

A bucket absent because policy did not cover it resolves to `NotRetained`, a `Null`-derived
absence type (see [types.md](types.md#absence-types)). The type forces consumers to distinguish
"no traffic" from "we did not keep it."

## Pruning is only ever a consequence

> **`LogData` is prunable, not pruned. A row is discarded only when a `retain` chain says its
> retention has expired.**

There is no manual prune of log data. `prune` remains an evolution statement for schema objects
and orphaned branches ([evolution.md](evolution.md)), but a `LogData` table under a retention
policy is pruned by that policy and by nothing else, and a `LogData` table with no `retain`
statement is **never pruned at all**.

That default is deliberate. `prune the log shard` is the operation most likely to be run under
pressure, and it must not be able to silently destroy evidence that cannot be reconstructed.
Silence means keep.

### Retention prunes whole segments

A `LogData` shard is rooted at a `system.shards.LogSegment` row keyed by
`{ origin_server, period_start, branch }`
([../transaction-graph.md](../transaction-graph.md#logdata-shard-roots)), where `branch` is the
index of the matching `retain` branch. A branch predicate may reference only group keys and the
time source, so the branch is decidable when the row is written, and no segment holds rows with
two different expiries.

An expiring step therefore usually covers a **whole sealed segment**, and pruning it is an unlink
of that segment's extents plus one prune node, not a row scan. Row-level pruning remains the
fallback for segments written before a branch was added or the period changed: routing is decided
at write time and never revised, the same forward-only rule that governs every other retention
edit above.

**None of this is syntax.** There is no partition clause on `retain`. A `shard by <grain>` header
clause was considered and rejected: the segment key already supplies the alignment it would have
declared. The period and the size thresholds are `Configuration` rows, and a table with no
`retain` statement is still partitioned — it is simply never pruned. *Silence means keep* must
not be allowed to become *silence means one unbounded shard*.

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
source is pruned, that definition no longer holds. This is the one place in the design where
something view-shaped cannot be materialization
([../storage.md](../storage.md#materialization)).

The event scheduler executes rollups through `system.events.MaintenanceQueue`, alongside
compaction and view refresh ([../events.md](../events.md)).

## Interactions

**Components.** A `LogData` parent with a `Component` subtree prunes the subtree with it —
already an invariant of `Component`, not a new rule
([traits.md](traits.md#component)). A rollup of the parent discards the components; if their
content matters at lower resolution it belongs in the binding's projection.

**Violations.** `system.integrity.Violation` carries `LogData` and is retained by predicate
rather than purely by age, because its rows are not equally reconstructible:

```
retain system.integrity.Violation
  where origin is Derived && state is Repaired
    for 90 day
    , drop
  otherwise
    forever
```

A `Derived` violation is recomputable and its repair is visible in the subject row's own history,
so discarding a closed one loses nothing. `Observed` and `Forced` violations cannot be
reconstructed, and a `Waived` one carries the waiver and its reason, which
[../integrity.md](../integrity.md) makes part of the audit trail. `otherwise forever` keeps all
three.
