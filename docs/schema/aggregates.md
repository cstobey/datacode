# Aggregates and Retention

Log data is the highest-cardinality thing DataCode stores and the only thing it is permitted
to discard. Discarding it wholesale loses history that is still worth having at lower
resolution — a year of hourly request counts costs almost nothing next to a year of requests.

Two declarations cover this. An **aggregate** says what to compute; a **retain** chain says at
what resolutions and for how long. Together they make "summarize before pruning" a checked
property rather than an operational hope.

```
aggregate RequestRollup = system.logs.HttpRequest
  group status
  { status
  , id         count as requests
  , bytes_sent sum   as bytes
  , duration   max   as slowest
  }

retain system.logs.HttpRequest as RequestRollup
  for 1 day
  , by Hour  for 1 month
  , by Day   for 6 month
  , by Month forever
```

Full-resolution rows for a day, hourly summaries for a month, daily for six months, monthly
forever.

## `aggregate`

An aggregate declaration is an ordinary query — a source, an optional `group`, and a
projection whose items apply aggregate functions — bound to a name:

```
aggregate <Name> = <Source> [ group <field> ]* { <projection> }
```

It is **not** a view. A view has one extent; an aggregate is a template instantiated once per
resolution in the chain that names it. Because it is a query, `where`, `group`, and the
aggregate functions all mean exactly what they mean in [queries.md](queries.md) — there is no
second grouping mechanism.

### The Time Bucket Is Injected, Not Written

The aggregate never names the time bucket, because it does not know the grain — that is the
chain's business. Every table generated from an aggregate gets

```
bucket_start : Timestamp
```

prepended automatically, and `grain` as a virtual column (below). So the aggregate above
produces rows of `{ bucket_start, status, requests, bytes, slowest }` at each level.

This makes the grouping two-level, outermost first: **time is the outer group, the
aggregate's own `group` fields are inner.** A bucket row is one grain-interval of one status.

### `grain` Is a Virtual Column

Each level is a separate table at a fixed grain, so the grain is a property of the table, not
of the row, and costs no bytes — the same way `created_at` is derived from the `DataId` rather
than stored (see [tables.md](tables.md)). It is nonetheless queryable:

```
system.logs.RequestRollup where grain == Month
```

There is no `by` clause in query position. `by` declares a grain in a `retain` chain; `where`
selects one, using the query language that already exists. Because `grain` is constant per
table, that predicate is a table selection rather than a row filter, and the optimizer treats
it as one.

`grain`'s type is `Grain` and `Month` is one of its variants, so this is an ordinary comparison
between a column and a variant — the capitalization is the ordinary variant-naming rule, not a
signal to the parser. `Hour` the grain and `hour` the `Duration` are different types and the
case is what tells them apart. See [types.md](types.md#three-kinds-of-time-quantity).

### Grain Order

A chain coarsens along declared **alignment** edges, not by comparing bucket widths. Every
grain names the grain whose buckets its own tile exactly:

```
Minute → Hour → Day → Month → Quarter → Year
                Day → IsoWeek → IsoYear
```

Two roots, and the second one is the reason alignment is the rule rather than coarsening. ISO
weeks tile ISO years exactly by construction, and tile nothing on the calendar side: the week
of January 29 straddles two months, so `by IsoWeek , by Month` would merge a bucket into a
month it is only partly inside. That step is **rejected** — not because the grain fails to
coarsen, but because it fails to align. An ISO chain runs to `IsoYear` or stops.

Alignment also decides what a width comparison could not. `IsoWeek` is coarser than `Day` and
finer than `Month` while dividing neither evenly, so its position in the order is declared
rather than computed.

Two further consequences:

- **Retention is compared against the successor grain's maximum span.** A step must cover at
  least one complete bucket of the step after it, and `Month` spans 28–31 days, so
  `for 30 day , by Month` is rejected while `for 31 day , by Month` is accepted. Conservative
  by construction, which is what keeps the check decidable.
- **An `IsoWeek` level is labelled by ISO year.** December 29–31 can belong to week 1 of the
  following ISO year and January 1–3 to week 52 or 53 of the previous one, so a calendar-year
  label would collide two distinct weeks in one bucket. `bucket_start` is the Monday, which is
  unambiguous on its own; the label an operator reads is the `(isoYear, week)` pair that
  `isoWeekOf` returns.

### Aggregates in a Chain Must Merge

Each step's source is the step before it, not the raw table. An aggregate is therefore
admissible in a chain of more than one step only if it declares an **associative merge with an
identity** — daily values have to be computable from hourly ones.

| Aggregate | In a multi-step chain |
|---|---|
| `count`, `sum` | Yes — the sum of counts is a count |
| `min`, `max` | Yes |
| `avg` | Yes, but stored as `(sum, count)` and divided on read. The transformation is silent; `avg` is never rejected. |
| `percentile` | **No.** A daily 95th percentile cannot be recovered from twenty-four hourly ones. |

The rule is stated as "must declare a merge" rather than as a list of permitted functions,
so a mergeable sketch type — a t-digest for percentiles, a HyperLogLog for distinct counts —
becomes admissible by declaring its merge, with no change to this rule. Until such a type
exists, `percentile` is valid in a single-step chain (raw → one level) and rejected beyond it,
with an error naming the missing merge.

**A chain does not reshape.** Every level of a chain has the identical structure; only the
resolution changes. This is why the aggregate is named once on the `retain` header rather than
per step — a chain whose steps computed different things would not be a chain, and there is no
slot in which to write one.

## `retain`

```
retain <Table> [ as <Aggregate> ] [ using <field> ]
  <branch>*
```

Retention is a separate statement from the table declaration for the same three reasons
enforcement modes are ([../integrity.md](../integrity.md#declaring-a-mode)): it is operational
policy that changes over time, it is not the schema author's decision to make, and keeping it
out leaves declarations pure. It is an ordinary schema object — versioned in the graph,
queryable, separately access-controlled.

A table with no rollup needs no aggregate:

```
retain system.logs.Debug
  for 7 day
  , drop
```

### Chain Steps and Terminals

A chain is a comma-separated list. The first step is the raw table's own retention; each
subsequent step declares a grain and a retention. Every chain ends in one of two terminals:

| Terminal | Meaning |
|---|---|
| `forever` | Keep at this resolution indefinitely |
| `drop` | Discard when the retention expires; nothing succeeds it |

`drop` rather than `never`, which in a document full of durations reads as "never delete" —
the opposite of what it means.

### Branches

Several retentions on one table are written as ordered branches in a single block, with
`otherwise` taking the remainder. First match wins, as in a Haskell guard:

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

One block rather than several statements, because order is load-bearing and separate
statements have no reliable order — you could never insert a specific rule ahead of an
existing catch-all. `otherwise` makes the fall-through explicit rather than implicit in
position. Nesting is the existing offside rule; no new layout machinery.

Each branch declares its **whole** chain. Branches share the aggregate but not the ladder.

> **A branch predicate may reference only the aggregate's group fields and the time source.**

Otherwise a single bucket could contain rows from two branches with different lifetimes, and
the bucket would have no well-defined retention. Referencing a non-grouped field is rejected
with that reason. In the example, `status` is a group field, so every bucket row is wholly
5xx or wholly not.

### Time Source

The bucket is cut on `created_at`, which for a native table is derived from the row's
`DataId`. A connector-sourced table whose meaningful time is a column of its own overrides it:

```
retain connectors.mariadb.production.Order as OrderRollup using order_date
  for 90 day
  , by Day forever
```

`using` already means "supply a parameter to this construct" on `Hashed`; `on` and `by` are
both taken.

## What Gets Generated

For each chain step past the first, one table at that grain, keyed by

```
unique { bucket_start, <the aggregate's group fields> }
```

`LogData` exempts a table from *needing* a candidate key; it does not forbid one, and a
rollup row is an entity rather than an occurrence
([tables.md](tables.md#candidate-keys-are-mandatory)). The key is what makes catch-up
**idempotent** — recomputing a bucket upserts the same row rather than duplicating it, which
is exactly what a process that plays catch-up after an outage or a policy change needs.

### The Union View

The aggregate's plain name is a view unioning every level:

```
system.logs.RequestRollup                      -- all levels, transparently
system.logs.RequestRollup where grain == Hour  -- one level
```

The transparent case is the default name and reaching into a level is the marked one. Because
a chain never reshapes, the union is homogeneous — every level has identical columns and only
`grain` differs, so no sum type is needed and no quantity silently changes meaning across the
boundary.

`grain` is materialized as a real column on the union, where it is not constant. Rows remain
comparable but not interchangeable: summing `requests` across the union gives a correct total,
while plotting `requests` per bucket must account for buckets of different widths. `grain` is
the column that lets a consumer do that.

## Changing a Policy

Data cannot be invented, so the four edits are not symmetric:

| Change | Effect |
|---|---|
| **Lengthen** a retention | No backfill — the window it now covers was already rolled up and dropped. Catches up going forward, leaving a gap until it fills. |
| **Shorten** a retention | Prunes back to the new bound. Destructive and irreversible. |
| **Add a coarser level** | **Backfills**, from the finer level, as far as the finer level still reaches |
| **Add a finer level** | No backfill. Forward only. |
| **Add a field to the aggregate** | No backfill. Existing buckets lack the input. |

Coarsening is reconstructible; refining is not. The system knows which case an edit is and
says so at commit.

A **shortening** edit reports its blast radius before it runs, on the same principle that
adding a predicate to a populated field must state a mode
([../integrity.md](../integrity.md#mode-is-mandatory-on-a-populated-field)):

```
datacode[system.logs]> :commit
error: retain system.logs.HttpRequest shortens raw retention from 7 day to 1 day.
       2 140 883 rows (6.2 GB) become immediately prunable.
       Re-issue with `confirm` to proceed.
```

### The Gap Is Typed

Lengthening leaves a real hole until it fills, and a hole that reads as zero is a lie a
dashboard will act on — a request-rate chart would show a cliff that looks like an outage.

A bucket absent because policy did not cover it resolves to `NotRetained`, a `Null`-derived
absence type (see [types.md](types.md#absence-types)). Consumers are forced by the type to
distinguish "no traffic" from "we did not keep it."

## Pruning Is Only Ever a Consequence

> **`LogData` is prunable, not pruned. A row is discarded only when a `retain` chain says its
> retention has expired.**

There is no manual prune of log data. `prune` remains an evolution statement for schema
objects and orphaned branches ([evolution.md](evolution.md)), but a `LogData` table under a
retention policy is pruned by that policy and by nothing else, and a `LogData` table with no
`retain` statement is **never pruned at all**.

That default is deliberate. `prune the log shard` is the operation most likely to be run
under pressure, and it must not be able to silently destroy evidence that cannot be
reconstructed. Silence means keep.

### Retention Prunes Whole Segments

A `LogData` shard is rooted at a `system.shards.LogSegment` row keyed by
`{ origin_server, period_start, branch }`
([../transaction-graph.md](../transaction-graph.md#logdata-shard-roots)), where `branch` is the
index of the matching `retain` branch. A branch predicate may reference only the aggregate's
group fields and the time source, so the branch is decidable when the row is written, and no
segment ever holds rows with two different expiries.

An expiring step therefore usually covers a **whole sealed segment**, and pruning it is an
unlink of that segment's extents plus one prune node — not a row scan. Row-level pruning
remains the fallback for segments written before a branch was added or the period changed:
routing is decided at write time and never revised, the same forward-only rule that governs
every other retention edit above.

**None of this is syntax.** There is no partition clause on `retain`. A `shard by <grain>`
header clause was considered and rejected: the segment key already supplies the alignment it
would have declared. The period and the size thresholds are `Configuration` rows, and a table
with no `retain` statement is still partitioned — it is simply never pruned. *Silence means
keep* must not be allowed to become *silence means one unbounded shard*.

### A Rollup Is Two Appends, Not a Rewrite

Rolling up writes aggregate rows in a new transaction, then records a prune node covering the
source range. Both are ordinary appends. The transaction being replaced is **not** rewritten
to hold the summaries — transaction nodes are immutable, and editing one would be exactly the
history mutation the graph forbids
([../transaction-graph.md](../transaction-graph.md)).

The consequence is that the history stays readable: it says these rows existed, then were
summarized, then were discarded, and when.

Rollup levels are therefore **real tables with their own transaction log entries**, not
materialized views. A materialized view is by definition recomputable from its source; once
the source is pruned, that definition no longer holds. This is the one place in the design
where something view-shaped cannot be a view.

Rollups are executed by the event scheduler through
`system.events.MaintenanceQueue`, alongside compaction and view refresh
([../events.md](../events.md)).

## Interactions

**Components.** A `LogData` parent with a `Component` subtree prunes the subtree with it —
already an invariant of `Component`, not a new rule
([traits.md](traits.md#component)). A rollup of the parent discards the components; if their
content matters at lower resolution it belongs in the aggregate's projection.

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

A `Derived` violation is recomputable and its repair is visible in the subject row's own
history, so discarding a closed one loses nothing. `Observed` and `Forced` violations cannot
be reconstructed, and a `Waived` one carries the waiver and its reason, which
[../integrity.md](../integrity.md) makes part of the audit trail. `otherwise forever` keeps
all three.
