# Nonconformance and Violations

Data that was valid when it was committed can stop being valid, because the rules moved.
A validation predicate is tightened, a foreign key target is pruned, a third-party system
writes something its own schema permits and ours does not. This document covers how DataCode
detects that, records it, and reports it, without violating the append-only guarantee and
without blocking the writes that keep the system running.

The term for such a row is **nonconforming**. ("Dirty" is avoided: in database vocabulary it
already means *modified but not yet written* — dirty page, dirty read — which is close enough
to be confusing and far enough to be wrong.)

## Validity Is a Relation, Not a Property

Every row records the schema graph node it was committed under, and under *that* node it
satisfied every rule that applied to it. That fact is permanent and cannot be revised;
revising it would mean mutating history.

So "this row is invalid" is never a complete statement. The complete statement is a triple:

```
(subject row, violated functor address, schema node under which it violates)
```

Nonconformance is a **relation between a row and a schema node**, normally `main` HEAD but
meaningful at any node. Three consequences follow, and all three are load-bearing:

1. **The same row is conforming at one node and nonconforming at another**, with no
   contradiction and no data change. That is what makes the question "what would this rule
   break?" answerable before committing the rule.
2. **A violation can be resolved by branching**, not only by repairing data. Reverting or
   relaxing the rule on a branch clears the violation at that node. Sometimes the data is
   right and the rule is wrong.
3. **The flag cannot live on the row.** Writing a marker onto the subject would mint a new
   version, advance `updated_at`, re-run every functor attached to the row, and change what
   the history says. Violations are separate rows that point *at* the subject. See
   [transaction-graph.md](transaction-graph.md#virtual-columns).

## Two Classes of Nonconformance

The distinction determines whether any state has to be stored at all.

| | **Derivable** | **Observational** |
|---|---|---|
| Definition | The functor is a pure function of stored data, so validity can be recomputed at any time, at any schema node | The functor needs an input that exists only transiently and is never stored |
| Examples | `minLen 12` on a username; an FK whose target was pruned; an `assert` broken by a third-party update; a hash written under a superseded policy | "this password is shorter than the policy now requires" — the plaintext exists only during a login attempt |
| Reconstructable? | Yes, always | **No.** If the record is lost, the finding is lost |
| Storage | None required — it is a query | Must be written when observed |

**Derivable nonconformance needs no state.** The authoritative definition is a query over the
transaction graph, evaluated at a chosen schema node. `system.integrity.violations` is a
**materialized view** over that query — pegged to a commit node, computed in the background,
refreshable, and droppable without losing anything. This is the existing materialization
machinery (see [storage.md](storage.md#materialized-views)), not a new mechanism, and it
means there is no derived state that can drift out of agreement with the data.

**Observational nonconformance must be recorded.** The transient witness is gone by the time
anyone could ask again. These rows are appended to the same table with `origin = Observed`
and are *not* recomputed by a view refresh. The only place this currently arises is the
`Hashed` type — see [schema/types.md](schema/types.md#hashed-types) and
[auth.md](auth.md#password-policy-rotation).

## Enforcement Modes

The four functor kinds are unchanged. What is new is that an **attachment** of a functor to a
field or table carries an enforcement mode, which decides what happens on a violating write
and what happens to rows that already violate.

| Mode | New or changed value | Rows that already violate |
|---|---|---|
| `enforce always` | reject the transaction | recorded |
| `enforce forward` | reject the transaction | recorded, otherwise left alone — reads and unrelated writes are unaffected |
| `monitor` | accept | recorded |
| `repair into <queue>` | accept | recorded **and** enqueued for automated remediation |

`forward` rather than the more readable `on write`, which would require reserving `write` — a
likely field name in any permissions table, including DataCode's own.

`enforce always` is the default and is today's behaviour. `enforce forward` is
grandfathering: the rule binds new and changed values while existing ones keep working. This
is the correct mode for anything a user cannot be expected to know has changed — a username
rule cannot retroactively rename people who are already logging in with the old name.

`monitor` never rejects. `repair` is `monitor` plus an event-functor enqueue, so
"fix it" and "watch it" are one mechanism rather than two. The queue binding is written in
the provisional form below and will change with the event functor syntax (OQ-030).

### Ingestion Must Not Enforce

**A rule applied over connector-sourced data must not default to `enforce`.** A MariaDB
binlog stream whose commit fails stops at that offset and never advances — one malformed row
halts replication for the whole connector. The same applies to webhook ingestion, where a
rejected commit becomes a delivery failure and a retry storm at the source.

Connector-sourced tables therefore default every `app.*`-layer rule to `monitor`. Bad
external data becomes a reportable violation instead of an outage. See
[connectors.md](connectors.md#nonconforming-external-data).

## Declaring a Mode

Mode is declared by a **statement addressed at the validation**, not by a clause inside the
`where` block:

```
enforce app.auth.User.username / minLen12  always
enforce app.auth.User.username / minLen12  forward
monitor app.auth.User.username / minLen12
repair  app.commerce.Order.total / isRoundedToCents into app.events.repair_queue
```

The address form is the one already established for validations
([schema/README.md](schema/README.md#addressing-validations)): a field path names the field's
computed type and the predicates on it, and `/ <predicate>` selects one predicate within a
block. An `assert` is addressed by its own name and needs no `/`:

```
monitor app.commerce.Order.billingMatch
```

Three reasons the mode is a separate statement rather than a clause on the predicate:

1. Enforcement mode is an **operational** decision that changes over time. It should not
   require redeclaring a type to change, and it should not make the type declaration read
   differently depending on how far along a migration is.
2. The mode is not the schema author's decision to make. Waiving a rule across a live data
   set is an administrative act, and separating it lets it carry its own access control.
3. `where` blocks stay pure predicate lists, which is the Haskell shape they are meant to
   have.

Mode statements are ordinary schema objects: rows in `system.integrity.modes`, committed to
the schema graph, versioned, and queryable like anything else.

### Mode Is Mandatory on a Populated Field

> **Adding a predicate to a field that already has rows is a compile-time error unless a mode
> is stated in the same transaction.**

Because derivable nonconformance is a query, the system knows the blast radius before the
commit. The REPL and IDE report it and refuse to proceed without a decision:

```
datacode[app.auth]> table User { username : Username where minLen 12 }
datacode[app.auth]> :commit
error: app.auth.User.username / minLen12 is new and app.auth.User has 41 208 rows.
       1 284 rows (3.1%) do not satisfy it.
       State a mode in this transaction:
         enforce app.auth.User.username / minLen12 always    -- reject those rows' next write
         enforce app.auth.User.username / minLen12 forward   -- grandfather them
         monitor app.auth.User.username / minLen12           -- record only
```

This is the point of the whole mechanism. A rule change that silently locks out three percent
of a user base is a decision someone should make deliberately, at the moment they have the
number in front of them.

An empty table needs no mode; the default `enforce always` applies, and there is nothing to
grandfather.

## The Violations Table

```
table system.integrity.violations : LogData {
  subject_table :> system.schema.tables,
  subject       : DataId,
  functor       : FunctorRef,
  schema_node   : DataId,
  origin        : Derived | Observed | Forced,
  observed      : Bytes | Redacted | NotGiven,
  state         : Open | Acknowledged | Waived Text | Repaired,

  assert access { user.id `canRead` subject_table }
}
```

`subject` is a bare `DataId` rather than a `:>` reference. This is deliberate and it is a
real cost: an FK functor resolves a `DataId` against **one** named table, and a violation may
point at a row in any table at all. The alternatives were considered and rejected:

- **A generated violations table per subject table.** Types cleanly and joins naturally, but
  turns "show me everything nonconforming" into a union across every table in the schema, and
  multiplies the schema by a constant factor for a system concern.
- **An existential `:> Any`.** Requires a new concept in the type system, because the FK
  functor signature `DataId → Either Error Row` cannot resolve without knowing the target
  table.

The pair `(subject_table, subject)` *is* the existential, written out by hand. It is also how
the graph is physically keyed, so nothing is being faked.

### Violations Live in the Subject's Shard

A single global violations table would be a cluster-wide write hotspot and would break the
`UserData` shard-local invariant — a violation about a row in a user shard would force a
cross-shard write on every ingest. Violations are written to **the shard that holds the
subject row**.

The consequence is that the admin report is a distributed query rather than a table scan.
This is already supported: a server broadcasts the query fragment to its neighbours, each
computes its local contribution, and the requesting server merges them (see
[distribution.md](distribution.md#materialized-view-distribution)).

### Attachment to the Functor Is Logical, Not Physical

A violation belongs to the functor it violates: that is the axis an operator asks along, and
`functor` is the field the report groups by.

It cannot also be the *physical* clustering, and the reason is worth stating because it is
not obvious. Physical clustering would mean the `Component` trait — violations identified
relative to a parent and stored in its subtree — and that is unavailable here twice over:

- **The functor is the wrong parent.** Functors are schema objects in the `system` shard,
  replicated to every server. Making violations components of them would replicate every
  violation everywhere, which is precisely the write amplification the shard-local rule above
  exists to prevent.
- **The subject is not a legal parent either.** A `Component` table has exactly one parent
  table, and a violation's subject may be a row in any table at all — the same polymorphism
  that forces `subject` to be a bare `DataId`.

So `system.integrity.violations` is an ordinary `LogData` table sharded with its subject, and
the functor attachment is an FK. The per-functor report is a **materialized view grouped by
`functor`** — computed in the background, pegged to a commit node, and cheap to read
repeatedly, which is what a dashboard actually needs. The grouping cost is paid once per
refresh rather than once per view.

Violations do not outlive the rule they refer to: `prune`ing a functor drops its violations,
because the finding has no meaning once the rule is gone.

### Secrets Never Appear in `observed`

`observed` holds the offending value to make a report actionable. For a field whose type is
`Secret` — which every `Hashed` type is — it holds `Redacted` instead, and the report carries
only the functor address.

This is enforced by the type, not by reviewer discipline. A `Secret` type admits only
`a -> Bool` predicates, so a validation functor attached to one has no channel through which
to return a value at all; and the runtime erases error payloads at the boundary as a
backstop. See [schema/types.md](schema/types.md#secret-types).

The reason this matters more here than elsewhere: the transaction log is append-only. A
plaintext credential that reaches it is there permanently, and no subsequent operation can
remove it.

## Reporting and Administration

`show violations` exists as a CLI convenience for the degraded-server case, where the query
engine may be all that is working:

```
show violations
show violations for app.auth.User.username / minLen12 limit 50
show violations shard user.commerce
```

Everything else is an ordinary query or mutation, because
`system.integrity.violations` is an ordinary table and the
[self-hosting principle](schema/README.md#self-hosting-principle) says system concerns that
can be expressed as tables should be:

```
-- What is open, worst first
system.integrity.violations
  where state is Open
  group functor
  { functor, violations.subject count as affected }
  order by affected desc

-- Waive one, with a reason
system.integrity.violations where id == "05KG3N0000ZQ8V4T1H7C"
  { state = Waived "legacy import, tracked in TICKET-4471" }

-- Raise one by hand against a row that passes every automated rule
system.integrity.violations {
  subject_table = app.auth.User,
  subject       = "05KG3N0001BB2M9X4E",
  functor       = app.auth.User.manualReview,
  origin        = Forced,
  state         = Open
}
```

Waiving appends a new state rather than deleting the row, so the waiver and its reason are
themselves part of the audit trail.

A `Forced` violation is how an operator marks data as suspect when the reason is not
expressible as a functor. It is never closed by a view refresh — only an operator can resolve
it — which is the same rule that protects `Observed` violations.

The IDE surfaces the same data as a review queue, unified with the connector conflict queue —
they are the same workflow, and an operator should not have to check two places to find out
what needs attention. See [ide.md](ide.md#integrity-panel).

## What This Is Not

**Not a flag on the row.** Covered above; the reason is `updated_at` and history integrity.

**Not a `Null`-derived absence type.** It is tempting to make a nonconforming field read as
`Nonconforming`, by analogy with `Redacted`, so that consumers are forced by the type system
to handle it. This is wrong. It would break every existing consumer of the field the instant
a rule was tightened, and it would destroy the entire point of `enforce forward`, which is
that grandfathered values keep working exactly as before. Nonconformance is a fact *about* a
row, reported out of band; it is not a change to the row's value or its type.

**Not a blocker for reads.** No mode causes a read to fail or a field to disappear. Access
control is the only thing that changes what a read returns.

## Open Points

- Retention: violations carry the `LogData` trait and are prunable, but an `Observed`
  violation cannot be reconstructed after pruning. See OQ-032.
- The `repair into <queue>` binding is provisional pending the event functor syntax
  (OQ-030).
