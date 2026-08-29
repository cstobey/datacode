# Nonconformance and Violations

Data that was valid when it was committed can stop being valid, because the rules moved.
A validation predicate is tightened, a foreign key target is pruned, a third-party system
writes something its own schema permits and ours does not. This document covers how DataCode
detects that, records it, and reports it, without violating the append-only guarantee and
without blocking the writes that keep the system running.

It also covers the two operations by which data leaves DataCode — `erase` and `scrub` — because
the second is triggered by the mechanism described here and recorded through it.

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

The distinction determines whether losing a record loses the finding.

| | **Derivable** | **Observational** |
|---|---|---|
| Definition | The functor is a pure function of stored data, so validity can be recomputed at any time, at any schema node | The functor needs an input that exists only transiently and is never stored |
| Examples | `minLen 12` on a username; an FK whose target was pruned; an `assert` broken by a third-party update; a hash written under a superseded policy | "this password is shorter than the policy now requires" — the plaintext exists only during a login attempt |
| Reconstructable? | Yes, always | **No.** If the record is lost, the finding is lost |
| Recorded by | the background scan, which re-appends what still holds | the code that saw the witness, once |
| Discardable? | Yes — [Retention](#retention) drops one after 90 days | Never |

**Derivable nonconformance needs no state to be true.** The authoritative definition is a query
over the transaction graph, evaluated at a chosen schema node. It stores nothing, so nothing can
drift out of agreement with the data, and running it at a *candidate* node is what answers "what
would this rule break?" before the rule is committed.

**`system.integrity.Violation` is a stored table even so.** A background scan evaluates the
derivable definition and **appends** a row for every finding it has not already recorded, matched
on `(subject_table, subject, functor, schema_node)` — which is why those four fields are the ones
the table carries. The scan is not a view refresh, and the difference decides what an operator
can rely on: a refresh recomputes and drops, and `Observed` and `Forced` rows cannot be
recomputed. This corrects an earlier reading that called the table a materialized view; the
materialization claim survives, one level up, for the per-functor
[report](#attachment-to-the-functor-is-logical-not-physical).

So the two classes decide not whether a row exists but whether losing one loses anything, which
is what [Retention](#retention) branches on.

**Observational nonconformance must be recorded when it is seen.** The transient witness is gone
by the time anyone could ask again. These rows carry `origin = Observed` and no scan re-derives
them. The only place this currently arises is the `Hashed` type — see
[schema/types.md](schema/types.md#hashed-types) and
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
"fix it" and "watch it" are one mechanism rather than two. `into` names an ordinary queue
table — the same binding `on … emit` makes, keeping a different spelling only because a
repair's payload is fixed (it is the violating row) where `emit`'s is a literal.

**A mode governs the write path only.** An access assert — one whose body mentions
`authed_user` ([schema/functors.md](schema/functors.md#path-constraints-and-their-two-varieties))
— is evaluated on read as well as on write, and it redacts on read under **every** mode. So
`monitor` on such an assert means "accept the write, record it"; it never means "stop checking
reads". `enforce forward` grandfathers values, not readers.

The alternative reading is worse than wrong, it is invisible: a mode that switched redaction off
would disable access control from a statement whose only documented effect is what happens to a
write, and the mode table above gives an operator nothing to see it by. The same rule stated from
the other side is [Not a blocker for reads](#what-this-is-not) — a mode neither hides a row nor
reveals one.

### Ingestion Must Not Enforce

**A rule applied over connector-sourced data must not default to `enforce`.** A MariaDB
binlog stream whose commit fails stops at that offset and never advances — one malformed row
halts replication for the whole connector. The same applies to webhook ingestion, where a
rejected commit becomes a delivery failure and a retry storm at the source. Bad external data
has to become a reportable violation instead of an outage.

> **A validation attached to a table under `connectors.*`, or to a binding whose sources are all
> such tables, defaults to `monitor`. Everywhere else the default is `enforce always`.**

Three things in that sentence are deliberate:

- **The default is read off the attachment, not off the data.** "Connector-sourced" is not a
  property a row carries, and no trait means it. What is checkable is where the shadow schema
  lands: a connector named `production` generates `connectors.mariadb.production.*`
  ([namespaces.md](namespaces.md#connector-namespaces)), the same namespace rule that already
  decides default visibility. So the default is derivable at schema commit.
- **It covers every layer, not only `app.*`-layer rules.** An earlier phrasing said `app.*`, which
  left the rules on the shadow table itself undecided. The binlog does not stop more politely
  because the predicate was declared one namespace up.
- **It is a default, not a ceiling.** A `ModeStmt` overrides it in either direction, and
  overriding it is the recorded, access-controlled act [Declaring a Mode](#declaring-a-mode)
  describes.

Writing `system.integrity.Mode` rows at connector setup would express the same thing, and it is
rejected for the reason [scrub rules](#scrub-rules-are-configuration) are never inserted
automatically: a commit that writes configuration rows leaves the table half-authored and
half-derived, and a diff can no longer say who decided what.

See [connectors.md](connectors.md#nonconforming-external-data).

### Connector Tables Without a Source Key

Enforcement mode covers what happens to *data* under a rule. It does not reach a rule that
must exist at declaration time, and the mandatory candidate key
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) is one of those: a shadow
table over a MariaDB table with no primary key cannot declare a key at all, and no mode fixes
that.

So the requirement applies to tables a schema author declares. A generated connector shadow
table carries [`Keyless`](schema/traits.md#keyless) automatically when the source has none —
and the connector writes a violation recording why:

```
system.integrity.Violation {
  subject_table = system.schema.Table,
  subject       = "05KG3N0000QF7T2B9M4H",   -- the row for connectors.mariadb.production.LegacyAudit
  functor       = CandidateKeyRequired,
  schema_node   = "05KG3N0000QF7T2B9K3P",
  origin        = Forced
}
```

The subject here is a **schema object**, not a user row, and no second mechanism is needed to say
so: the schema is data, so the shadow table has a row in `system.schema.Table` and the ordinary
`(subject_table, subject)` pair names it. `CandidateKeyRequired` is the one thing a violation can
name that is not a functor — see [the declaration below](#the-violations-table).

`Forced` is exactly right too: it is how something is marked suspect when the reason is not
expressible as a functor, and no scan ever closes it. The effect is that "this table has no
natural key" lands in the same review queue as everything else instead of being a waiver granted
silently at schema generation time. An operator can waive it with a reason, and the waiver is
itself in the audit trail.

A derived table an author binds over a keyless connector table is an authored table and is not
exempt. If the underlying rows cannot be identified, that is a fact worth being made to
confront at declaration time rather than discovering during a merge.

## Declaring a Mode

Mode is declared by a **statement addressed at the validation**, not by a clause inside the
`where` block:

```
enforce app.auth.User.username / minLen12  always
enforce app.auth.User.username / minLen12  forward
monitor app.auth.User.username / minLen12
repair  app.crm.Contact.postal_code / isDeliverable into app.events.RepairQueue
```

The address form is the one already established for validations
([schema/README.md](schema/README.md#addressing-validations)): a field path names the field's
computed type and the predicates on it, and `/ <predicate>` selects one predicate within a
block. An `assert` is addressed by its own name and needs no `/`:

```
monitor app.commerce.Order.billingMatch
repair  app.pm.Document.hasSettings into app.events.DefaultRowQueue
```

An `assert` under `repair` is what makes "an unsatisfiable path constraint hands the row to a
functor that inserts the missing row" need no new syntax.

Three reasons the mode is a separate statement rather than a clause on the predicate:

1. Enforcement mode is an **operational** decision that changes over time. It should not
   require redeclaring a type to change, and it should not make the type declaration read
   differently depending on how far along a migration is.
2. The mode is not the schema author's decision to make. Waiving a rule across a live data
   set is an administrative act, and separating it lets it carry its own access control.
3. `where` blocks stay pure predicate lists, which is the Haskell shape they are meant to
   have.

Mode statements are ordinary schema objects: rows in `system.integrity.Mode`, committed to
the schema graph, versioned, and queryable like anything else.

### Mode Is Mandatory on a Populated Field

> **Adding a predicate to a field of a table that already holds rows is a compile-time error
> unless a mode is stated in the same transaction.**

The antecedent is the **table's** population, not the field's. That is the number the diagnostic
below reports, and the two readings disagree exactly where it matters: a field added with a
`where` block in one commit has no rows of its own and every row of the table.

Because derivable nonconformance is a query, the system knows the blast radius before the
commit. The REPL and IDE report it and refuse to proceed without a decision:

```
datacode[app.auth]> table User { *, username : Username where minLen 12 }
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

The `*` in that declaration is load-bearing: a redeclaration carries existing fields forward only
if it says so, and without it the transcript deprecates every other column of `User`
([schema/evolution.md](schema/evolution.md#redeclare-a-table)).

An empty table needs no mode; the default `enforce always` applies, and there is nothing to
grandfather.

**A newly added field needs no mode either, and cannot usefully take one.** Every field added to
an existing table carries a default, and every admissible default is closed
([schema/evolution.md](schema/evolution.md#redeclare-a-table)) — so a predicate on it has a blast
radius of 0% or 100%, decided by evaluating one value once. Satisfied, there is nothing to
choose; failed, the commit is rejected outright rather than offered three modes, because a
default failing its own predicate marks every existing row in one commit. That is a schema error,
not a migration decision. Modes exist for rows the author did not write.

## The Violations Table

```
type SchemaRule = CandidateKeyRequired

table system.integrity.Violation : LogData {
  subject_table :> system.schema.Table,
  subject       : DataId,
  functor       : FunctorRef | SchemaRule,
  schema_node   : DataId,
  origin        : Derived | Observed | Forced,
  observed      : Bytes | Redacted | Erased | NotGiven = NotGiven
}

table system.integrity.Disposition : LogData {
  violation :> system.integrity.Violation,
  state     : Acknowledged | Waived Text | Repaired
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

**A bare `DataId` still resolves through a re-key.** Changing a row's shard root is a delete plus
an insert, so the subject of an old violation is a tombstone with a successor. A `DataId` follows
the re-key link forward wherever it is read
([transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node)) — one rule
serving `Violation.subject`, `TriggerState.subject` and a captured queue payload alike. The
violation itself is never rewritten: it is a historical fact about a transaction, so it stays in
the log segment it was written to and resolves forward on read.

`functor` names what was violated, and the field is named for the head of its alternation, as
every alternation is. Almost always the head is right — a violation names one of the four functor
kinds ([schema/functors.md](schema/functors.md)). One thing that can fail against data is not a
functor of any kind: the mandatory candidate key is a schema-commit check
([above](#connector-tables-without-a-source-key)). `SchemaRule` is the closed set of such checks,
with one member today, so a commit check can be named, grouped and reported exactly as a functor
is without being typed as one.

### The State of a Violation Is Appended, Not Written Onto It

A violation is `Open` from the moment it is recorded. Acknowledging, waiving and repairing one
each **append a `Disposition`**, and the current state of a violation is the state of the latest
disposition naming it — an ordinary query. `Open` is therefore the absence of a disposition and
needs no stored value.

This replaces a mutable `state : Open | Acknowledged | Waived Text | Repaired` column on the
violation itself, and it is what [traits.md](schema/traits.md#queue-and-queuestate) already
prescribes: anything needing a record *after the fact* goes in its own `LogData` table with a `:>`
back. Three things follow, and each is a defect closed rather than a preference:

- **`LogData` keeps its one append-only exemption.** That exemption is the `QueueState` field on
  a `Queue` table, written by that queue's handler. A second mutable column here would have made
  the claim false, and the design advertises it.
- **Every column of `Violation` is fixed at write**, which is what lets [Retention](#retention)
  branch on one and stay decidable when the row is written.
- **The waiver records who and when.** The disposition is its own row, so its `created_at` and
  the transaction that wrote it answer "who waived this, and when" without an authority column —
  the acting token is recoverable through `system.logs.HttpRequest.tx_id`, the same argument
  [storage.md](storage.md#views-are-proposed-not-created-silently) makes for accepting a
  proposal.

**Read access to a violation follows the subject table's own grants**, evaluated where every
other grant is ([auth.md](auth.md#schema-level-access-and-bypass)). An earlier declaration carried
an `assert readableAccess` applying a `canRead` function to `authed_user` and `subject_table`.
That is withdrawn: the function exists nowhere, and defining it would mean re-implementing the
recursive grant walk inside an assert body — one decision with two authorities, which is what
schema-level reach is kept out of asserts to prevent.

### Violations Are Written Where They Are Observed

A single global violations table would be a cluster-wide write hotspot and would break the
`UserData` shard-local invariant — a violation about a row in a user shard would force a
cross-shard write on every ingest. That alternative is rejected, and what replaces it is more
local still: `Violation` carries `LogData`, so a row is appended to **the log segment of the
server that observed it**, and no other server is written to at all.

Co-locating a violation with its subject was the earlier rule and it is not achievable. Placement
follows the key's foreign-key chain to a shard root — the key declaration is the sharding
declaration ([schema/tables.md](schema/tables.md#keys-must-be-rooted)) — and this table declares
no key and no chain: `subject` is deliberately not a foreign key, so there is no edge along which
co-location could even be computed. A `LogData` table roots at a `system.shards.LogSegment` row
instead ([transaction-graph.md](transaction-graph.md#logdata-shard-roots)).

Nothing about the audit trail is weakened by that, because what is server-local about `LogData`
is authorship, not replication: the segment shard has the ordinary three role holders under the
batched durability class, so losing the observing server does not lose the evidence
([distribution.md](distribution.md#two-durability-classes)).

The consequence is that the admin report is a distributed query rather than a table scan — and
that is now the *reason* for it rather than a side effect. This is already supported: a server
broadcasts the query fragment to its neighbours, each computes its local contribution, and the
requesting server merges them (see
[distribution.md](distribution.md#materialized-view-distribution)).

### Attachment to the Functor Is Logical, Not Physical

A violation belongs to the functor it violates: that is the axis an operator asks along, and
`functor` is the field the report groups by.

It cannot also be the *physical* clustering, and the reason is worth stating because it is
not obvious. Physical clustering would mean the `Component` trait — violations identified
relative to a parent and stored in its subtree — and that is unavailable here twice over:

- **The functor is the wrong parent.** A functor is a schema object, so it lives on the branch
  shard and reaches every server with the schema graph. Making violations components of one would
  replicate every violation everywhere, which is precisely the write amplification the placement
  rule above exists to prevent.
- **The subject is not a legal parent either.** A `Component` table has exactly one parent
  table, and a violation's subject may be a row in any table at all — the same polymorphism
  that forces `subject` to be a bare `DataId`.

So `system.integrity.Violation` is an ordinary `LogData` table rooted at the observing server's
log segment, and the functor attachment is a reference rather than a containment. The per-functor
report *is* a **materialized view grouped by `functor`** — computed in the background, pegged to
a commit node, and cheap to read repeatedly, which is what a dashboard actually needs. That is
the existing materialization machinery (see [storage.md](storage.md#materialization)), not a new
mechanism, and the grouping cost is paid once per refresh rather than once per read.

**A violation outlives the rule it refers to.** `prune` removes a schema object and never removes
log rows — those go only by a `retain` chain
([schema/aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence)) — so pruning a
functor cannot drop its violations, and it should not: a `Waived` finding is audit evidence, and
losing it to an unrelated schema tidy-up would reopen the hole [Retention](#retention) closes. The
report renders a pruned address as pruned. The predicate behind it is content-addressed and stays
in the transaction graph, so the finding remains legible; only the attachment is gone.

### Secrets Never Appear in `observed`

`observed` holds the offending value to make a report actionable. For a field whose type is
`Secret` — which every `Hashed` type is — it holds `Redacted` instead, and the report carries
only the functor address.

This is enforced by the type, not by reviewer discipline. A `Secret` type admits only
`a -> Bool` predicates, so a validation functor attached to one has no channel through which
to return a value at all; and the runtime erases error payloads at the boundary as a
backstop. See [schema/types.md](schema/types.md#secret-types).

`observed` also reads `Erased` where the subject row has been erased, for the same reason: the
report must stay useful without becoming the copy that survives the act.

The reason type enforcement matters more here than elsewhere: the transaction log is
append-only, so a plaintext credential that reaches it is there until someone destroys bytes on
purpose. That operation exists — see [below](#erasure-restricts-scrub-destroys) — but it is
administrative, it is the single exception to "nothing is destroyed", and needing it is already
a failure. Keeping the value out of the log remains the defence, which is why it is enforced by
the type rather than by review.

## Reporting and Administration

`show violations` exists as a CLI convenience for the degraded-server case, where the query
engine may be all that is working:

```
show violations
show violations for app.auth.User.username / minLen12 limit 50
show violations shard user.commerce
```

Everything else is an ordinary query or mutation, because
`system.integrity.Violation` is an ordinary table and the
[self-hosting principle](schema/README.md#self-hosting-principle) says system concerns that
can be expressed as tables should be:

```
type NoDisposition : Null

-- What nobody has acted on, worst first
system.integrity.Violation >< system.integrity.Disposition | NoDisposition as d
  where d is NoDisposition
  group { functor }
  { functor, count rows as affected }
  order by affected desc

-- Waive one, with a reason
system.integrity.Disposition {
  violation = "05KG3N0000ZQ8V4T1H7C",
  state     = Waived "legacy import, tracked in TICKET-4471"
}

-- Raise one by hand against a row that passes every automated rule
system.integrity.Violation {
  subject_table = app.auth.User,
  subject       = "05KG3N0001BB2M9X4E7D",
  functor       = app.auth.User.manualReview,
  schema_node   = "05KG3N0000QF7T2B9K3P",
  origin        = Forced
}
```

The first query is an outer join used as an anti-join: `NoDisposition` is `Null`-derived, so it
always matches, and the rows it matches are the violations with no disposition
([schema/queries.md](schema/queries.md#outer-joins)). "Open" is the absence of a disposition, so
there is no state column to filter on.

Waiving appends rather than overwriting, so the waiver and its reason are themselves part of the
audit trail, and so is the order the decisions were made in.

A `Forced` violation is how an operator marks data as suspect when the reason is not
expressible as a functor. No scan ever closes one — only an operator can — which is the same
rule that protects `Observed` violations.

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

**Not a blocker for reads.** No mode causes a read to fail, a field to disappear, or a redacted
field to become visible. Access control is the only thing that changes what a read returns.

## Erasure Restricts, Scrub Destroys

Two operations remove data. They are not variants of each other, and conflating them is the
mistake this section exists to prevent.

| | `erase` | `scrub` |
|---|---|---|
| Removes | access to a row's history | bytes from the log |
| Eligibility | tables carrying [`Personal`](schema/traits.md#personal) | any field, any table |
| Invoked by | an administrator, per row or shard root | an administrator, or a scrub rule |
| Recorded as | a graph node | a graph node |
| Reachable from the query language | no | no |

Neither is spelled as a `delete`. `delete` appends an ordinary tombstone and leaves history
readable ([schema/queries.md](schema/queries.md#delete-appends-a-version)) — which is what
`delete!` also did, and why that spelling was withdrawn rather than given these semantics.

### Erasure Is Restriction of Processing

`erase` appends an `Erased` tombstone. The row is absent from the current state like any deleted
row, and unlike a deleted row it reads `Erased` at every *earlier* sample moment as well, for
every token that does not hold `bypass erasure`.

Call this what it is. Naming it erasure invites someone to assume the bytes are gone, and they
are not: the row is retained and its **processing is restricted**, which is the shape GDPR Art. 18
gives that phrase and not the destruction Art. 17 describes.

Be exact about the basis, because an earlier reading of this section was not. Art. 18(2) governs
data whose processing has *already* been restricted on one of the four grounds in Art. 18(1). It
is a temporary measure tied to resolving that ground, not a basis a controller may elect for
indefinite retention — and storage is itself processing (Art. 4(2)), so "kept forever behind an
access check" needs a basis of its own. Where a subject exercises Art. 17 and the controller keeps
the record, that basis has to be an **Art. 17(3) exemption**, with a period established under
Art. 5(1)(e).

The division of labour follows. The exemption, and the retention period it justifies, are the
deployment's to establish. DataCode's guarantee is narrower and is the only one a database can
make: the retained copy stays inert — unreachable by ordinary query, absent from derived state,
and unused for any purpose beyond the obligation that justifies keeping it. Where no exemption
applies, or an authority orders actual destruction, the operation is `scrub`.

Three properties follow from rules already settled rather than being new:

- **Erasure is retroactive by construction.** A historical read is checked against HEAD's access
  rules, never the moment's (OQ-027), so an erasure decided today closes history today and needs
  no new evaluation path.
- **Erasing a shard root cascades**, along two edges rather than one. Every dependent row reaches
  the root through its foreign-key chain
  ([schema/tables.md](schema/tables.md#keys-must-be-rooted)), so "erase this customer" is one act
  rather than a traversal someone writes. But re-keying a row is a delete plus an insert
  ([transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node)), which copies
  every non-key field into another shard — so a row that left the subtree carries the erased
  subject's data and no foreign key reaches it. **The cascade therefore also follows re-key links
  forward, transitively**, from every row in the erased subtree, and the report carries an
  outbound-edge entry naming each hop, the shape a crossing FK edge already gets at schema commit
  ([schema/constraints.md](schema/constraints.md#anchoring)). The cheaper alternative — forbid a
  re-key on any table carrying `Personal` — is rejected: it removes a routine operation to avoid
  writing one traversal. Said plainly, the FK chain is no longer a complete account of
  reachability.
- **A prior `delete` is unnecessary.** Erasure implies deletion at HEAD.

What must survive the act is the record of it — which row, ordered by whom, under what
authority, and why — for the reason a `Waived` disposition carries its reason.

Two consequences of that survival, both about the re-key record:

- **The record outlives the subtree it left.** Transaction nodes are immutable, so a record
  saying a row was superseded remains after its predecessor's root is erased, disclosing that
  something moved out. The residue is real, and it gets the treatment a scrub node already gets:
  the record stays, and its counterpart identifiers render `Erased` to any token without
  `bypass erasure` — the same honest disclosure `observed` makes.
- **A version-chain walk stops at an erased predecessor.** Following a re-key link backwards
  reaches history that erasure closed, so the walk terminates there and the field reads its value
  as of the re-key and no earlier. Reconstructing what erasure closed is what the termination
  exists to prevent.

Derived state holding a copy is handled by what it is. Materialized views and shredded document
trees are recomputable, so a refresh drops the row. Two cases are not:

- **A rollup whose group key is a `Personal` field.** Its source is pruned by the time it
  exists, so it is the only record and may itself carry the data. Schema commit warns.
- **An interned document key.** `DocKeys` rows are schema, replicated everywhere and never
  pruned, so a payload keyed by an address puts that address on every server. This is the case
  scrub rules over document keys exist for; see
  [schema/documents.md](schema/documents.md#key-shape-rules).

The table-wide `unique` index is not on this list, because it never holds the value. See
[distribution.md](distribution.md#the-unique-index-holds-digests-not-values).

### Scrub Overwrites Payload Bytes

`scrub` is the one operation that mutates a written extent and the single exception to "nothing
is destroyed". It has one routine caller — a secret that reached the log — and one rare one, an
ordered destruction that restriction of processing does not satisfy.

A scrub node records:

| Field | Why |
|---|---|
| target locator and field | what was scrubbed |
| byte length | the gap is physically observable regardless; recording it is the honest form |
| checksum before, checksum after | tamper evidence |
| authority and reason | the act destroys evidence, so its own record must not be destructible |

**Tamper evidence survives the overwrite.** Verification is defined as "matches the recorded
checksum, or matches the `after` of a scrub node covering it", so divergence with no scrub node
is corruption and `verify shard` reports it as such. Without this, the append-only guarantee
would have been traded for nothing.

Physical mechanics — why length is preserved and what compaction has to do with it — are in
[storage.md](storage.md#scrubbing-overwrites-in-place).

### Scrub Rules Are Configuration

What must never reach the log is an operational list that moves as APIs move, so it is
`Configuration` rather than schema:

```
table system.crypto.ScrubRule : Configuration {
  pattern   : Text where isValidRegex,
  applies   : FieldName | DocKey | Both,
  rationale : Text,
  unique rulePattern { pattern, applies }
}
```

`rationale`, not `reason`: `reason` is reserved, deliberately and with the trade recorded
([schema/railroad.md](schema/railroad.md#reserved-words)), so a table declaring it as a field is
the defect rather than the reservation.

Rules match on field path and document key. A default set ships covering the obvious names —
`password`, `passphrase`, `secret`, `token`, `api_key`, `ssn`, `cvv`.

**Nothing is inserted automatically.** A schema commit that wrote configuration rows would make
the table half-authored and half-derived, so a diff could no longer say who decided what — and
one default pattern already covers every field named `password` that will ever exist, which is
what a row per field was for. The type is the guarantee; the rule is the net that catches what
no type covered. A rule never weakens a `Secret` type.

### Three Layers, in Order of Preference

1. **The type, at declaration.** A `Secret` type has no channel through which a value can
   escape.
2. **A static check, at schema commit.** Functors are transparent (OQ-001), so the walk that
   already performs static access analysis also answers "does this route's projection reach a
   `Secret` source?" — and such a route is rejected. The same walk warns where a field or
   document key matches a scrub rule and its type is *not* `Secret`, which is the diagnostic
   that gets the type declared before anything leaks.
3. **A runtime matcher, at ingest.** HTTP request logs and connector document payloads have no
   static shape, and they are where leaks actually happen. The matcher runs over document keys
   **before the frame is written**, so the plaintext never reaches the log. For those two paths
   this is the primary defence, not a backstop.

Scrub-then-violation is what remains for a rule taught too late: the bytes are scrubbed, a
violation is raised with `origin = Forced`, and every subsequent write of that field stores a
keyed deterministic digest in place of the value. The digest is what makes a brute-force attempt
distinguishable from a user retyping the same wrong password; on the login path it lands in
[`system.auth.AttemptDigest`](auth.md#failed-attempt-digests), whose key scope and retention
rules apply.

**Say what that costs, because it is not free and it is not typed.** The field's declared type is
unchanged while its stored contents stop being values of that type, so every reader of the field
breaks — silently, with no type change to warn it. That is the same substitution this document
[refuses](#what-this-is-not) for a `Nonconforming` absence type, and it is worse here, because
there the breakage would at least have been type-checked. It is admitted only as a stopgap
against an active leak.

The repair is a **new field** carrying the correct `Secret` type, with the old one deprecated. It
is not a redeclaration: a field path is bound to its declared type for the life of the table, so
retyping it in place is rejected with "choose a new name"
([schema/evolution.md](schema/evolution.md#redeclare-a-table)). The stopgap ends when that field
ships, and the `Forced` violation is what keeps it visible until it does.

### Replication and Restore

A scrub node replicates through the ordinary commit fan-out. Two cases sit outside it:

- **A tertiary holds current state only**, so scrubbing a superseded version reaches nothing
  there and needs no special handling. The same fact bounds what a tertiary can answer: a
  question about history — a per-field timestamp, a version chain, a re-key predecessor — routes
  to the primary or a secondary ([distribution.md](distribution.md#tertiary-servers-any-number)).
- **A restore replays scrubs.** `import shard` reinstates bytes as they were when the dump was
  taken, which would resurrect anything scrubbed since. A restore is not complete until every
  scrub node at or before the restore point has been re-applied, and the shard does not come
  online before that finishes.

Exports stay an operator obligation: `export shard … to` writes bytes outside the system and no
in-system mechanism reaches them. The restore rule above is what stops a re-imported dump from
becoming the path by which scrubbed data returns.

## Retention

`system.integrity.Violation` carries `LogData`, so it is prunable — but the two classes of
violation are not equally recoverable, and a single age-based policy would destroy the ones
that matter most. Retention is therefore declared **by predicate**, using the ordered branch
form in [schema/aggregates.md](schema/aggregates.md#branches):

```
retain system.integrity.Violation
  where origin is Derived
    for 90 day
    , drop
  otherwise
    forever
```

A `Derived` violation is a query over the transaction graph, recomputable at any time, so
discarding one loses nothing: the next scan re-appends it if it still holds, and if it no longer
holds there was nothing to keep. What is lost by the drop is the finding's recorded age, which is
the age of the *record* and never was the age of the nonconformance.

The predicate reads `origin` and nothing else, and that is deliberate. `origin` is fixed when the
row is written, so the branch is decidable at write, is recorded in the segment key, and the
segment stays prunable as a whole
([transaction-graph.md](transaction-graph.md#logdata-shard-roots)). An earlier chain also tested
`state is Repaired`, a column that changed after the row was written — which filed every row
under `otherwise forever` at write time and meant the 90-day branch could never fire on anything.
Moving the state to an appended [`Disposition`](#the-state-of-a-violation-is-appended-not-written-onto-it)
is what removes the mutable column rather than working around it.

Everything else falls to `otherwise forever`:

- **`Observed`** violations have no reconstructable witness. The plaintext that failed the
  policy existed only during a login attempt.
- **`Forced`** violations were raised by an operator for a reason not expressible as a functor,
  so nothing can re-derive them.

**A disposed violation is kept with its disposition.** `system.integrity.Disposition` declares no
`retain` chain, so it is never pruned — silence means keep — and it holds a live foreign key to
its violation, so the violation goes nowhere either. The `Derived` branch therefore drops exactly
the findings nobody acted on, which are exactly the ones a re-scan reproduces.
`Waived "legacy import, tracked in TICKET-4471"` is precisely the record someone wants two years
later, and nothing in the chain can reach it. The cost is stated rather than hidden: a segment
holding a disposed violation is no longer prunable as a unit and falls to the row scan
([schema/aggregates.md](schema/aggregates.md#retention-prunes-whole-segments)).

This satisfies the constraint that made retention an open question: pruning the log shard can
no longer silently destroy audit evidence, because it is not a manual operation at all. Log
data is discarded only by a declared chain, and a `LogData` table with no chain is never
pruned. See
[schema/aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence).

A useful consequence in the other direction: once a `Derived` violation is dropped, the
transaction records that only existed to carry it can be compacted too, by the ordinary
maintenance path rather than a special case.
