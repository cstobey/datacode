# Distribution Architecture

## Server Roles

DataCode uses a three-tier server model per shard. Roles are not fixed to machines — they are assignable and transferable.

### Primary Server
- **Authoritative serialization point** for all mutations to its shard
- All writes go through the primary; it determines commit order
- **The data path uses no consensus** (not Raft/Paxos) — the primary decides and secondaries
  acknowledge. The *configuration* path does need one, and this document adopts the
  well-understood shape: a consensus-free data path over a configuration master, as in Chain
  Replication and Vertical Paxos. See
  [Elevation Is Automatic; Failback Is Not](#elevation-is-automatic-failback-is-not).
- Should be geographically close to the heaviest write workload, ideally close to the primary user population
- If the primary goes down, a secondary is elevated automatically

### Secondary Servers (exactly 2 per shard)
- Maintain a **complete copy of the full transaction graph** including all history
- **Acknowledge durability** — the frame appended and fsynced, not merely received — before the
  primary considers a transaction committed, in the synchronous durability class below
- Can serve read queries directly
- Eligible for elevation to primary
- Goal: **geodiverse placement** for disaster recovery — ideally on different continents or at minimum different availability zones

### Tertiary Servers (any number)
- Do **not** need the full transaction history — only the current state plus recent transactions
- Primary use cases:
  - Points of presence (PoP) for latency-sensitive reads
  - Dedicated analytical workload servers
  - Edge nodes close to specific user populations
- To be elevated to secondary, must first receive the full transaction history
- Elevation of a tertiary to secondary requires one of the existing secondaries to downgrade to tertiary (only 3 servers may hold primary+secondary roles at any time)

Two consequences of holding current state only:

- **A tertiary cannot answer a history question.** Per-field timestamps, a version-chain walk,
  and a re-key predecessor all need nodes a tertiary does not keep, so such a query routes to
  the primary or a secondary. The routing is not a fallback: a tertiary that answered from
  current state would answer wrongly rather than slowly.
- **A tertiary can authenticate.** Credential validation is a read, so a point-of-presence
  tertiary resolves the user's shard through the shard directory and authenticates locally with
  no hop to the primary. That holds because issuing a session is not a row write — a session is
  a self-describing bearer value whose validity is a `Behavior` of its embedded issue moment.
  See [auth.md](auth.md#token-expiry-and-revocation).

### Host Rotation and Upgrade Cycles
The tertiary-to-secondary elevation mechanism is explicitly designed to support **rolling hardware upgrades**:
1. Bring up a new tertiary, sync full history
2. Elevate new server to secondary; old secondary becomes tertiary
3. Drain and take old server offline for maintenance
4. Repeat for primary as needed

## Role Assignment Is a Coarsening of the Partition Function

Two maps are defined over a shard family's placement key space, and they are deliberately not
the same structure:

| | Partition function | Range tree |
|---|---|---|
| Maps | placement key → shard | key range → `(primary, secondary, secondary)` |
| Granularity | exact, total, row-level | coarse; a range covers a whole number of shards |
| Changes when | a shard splits | a role is elevated, demoted, or moved |
| Recorded as | a split node in the graph | `Configuration` rows |

**Every range boundary is a partition boundary.** The range tree is a coarsening of the
partition function — it never cuts through a shard, so a shard's roles are always resolved by
exactly one range. The partition function is authoritative about *where a row lives*; the range
tree is authoritative about *who serves it*.

Keeping them separate is what keeps each one's audit trail clean. Role assignment changes for
reasons that have nothing to do with key space — a rolling upgrade, a region outage, a
workload that moved — and if role triples lived on the interior nodes of the placement
structure, every `elevate secondary … to primary` would edit the structure that decides where
rows are stored.

The coarsening also removes a failure mode rather than merely detecting it:

| Operation | Partition function | Range tree |
|---|---|---|
| `split shard … at key` | refined | **untouched** — the children resolve through the unchanged covering range |
| `elevate` / `demote` | untouched | edited |
| Move authority for a key region | untouched | edited, usually after a split |

Because a split needs no assignment write at all, there is no window in which a new child
shard has no roles or inherits stale ones. A per-shard assignment table would have required
that write and would therefore have had that window.

### Layering

Ranges nest, and resolution is **most-specific-match wins** — the rule already used for
`system.shards.ExtentPolicy` / `ExtentOverride` and for namespace access inheritance (OQ-024).
A family-wide default sits at the root, coarse regions below it, and a single shard may be
pinned by a maximally-specific range whose bounds are that shard's own partition interval.

Ranges at one level must be **non-overlapping, and each must be wholly contained in its
parent**. Overlap with a priority tie-break was rejected: two rows could then claim one shard,
which is split-brain arriving by configuration rather than by failure, and OQ-006's constraint
forbids it. Nested intervals make "most specific" a total function, so a shard's primary is a
deterministic function of its key.

This is also why assignment is expressed as ranges rather than per shard. The table must be
`Configuration` — every server needs it to route — and a per-shard table would be
`Configuration` at `UserData` cardinality — and the cardinality column in
[schema/traits.md](schema/traits.md#replication-traits) budgets `Configuration` at Medium, which
is what a table replicated to every server can afford. Ranges are what keep routing metadata
inside that budget.

A **shard group** falls out with no additional concept: sibling leaves under a range with no
override share that range's triple, which is the definition of sharing a primary. See OQ-035.

The key that ranges are expressed over differs per family, exactly as placement does — the root
table's candidate key for `UserData`, the segment boundary for `LogData`, `DataId` as a last
resort (see [transaction-graph.md](transaction-graph.md#placement-keys-are-not-identity-keys)).
Since `DataId` is time-major, a range over it is a time range.

### The Range Tree Is Two Tables

```
type RangeBound = TextBound Text | NumBound Int | TimeBound Timestamp | IdBound DataId

table system.shards.RoleDefault : Configuration {
  family      : Text unique,
  primary     :> system.shards.Node,
  secondary_a :> system.shards.Node,
  secondary_b :> system.shards.Node,
  epoch       : Int = 0
}

table system.shards.RoleRange : Configuration {
  family      : Text,
  lower       : RangeBound,
  upper       : RangeBound,
  primary     :> system.shards.Node | Quarantined,
  secondary_a :> system.shards.Node | Quarantined,
  secondary_b :> system.shards.Node | Quarantined,
  epoch       : Int = 0,
  unique rangeRef { family, lower, upper }
}
```

Two tables rather than one with an "unbounded" variant, for the reason that already split
`ExtentPolicy` from `ExtentOverride`: an unbounded end would be a `Null`-derived variant in the
key, which is rejected
([schema/tables.md](schema/tables.md#ineligible-key-fields)). `RoleDefault` is the
family-wide root of the tree and carries no bounds; every `RoleRange` row carries both.

Constraints not expressible in the declaration:

- **Bounds are half-open, `[lower, upper)`**, and both are values of the family's placement
  order. The `RangeBound` variant must match that order's type, checked at schema commit — a
  `TimeBound` on a family placed by a `Text` root key is a compile-time error.
- **A composite root key is bounded on its leading field.** The CLI spells a composite bound as
  a `RecordLit` ([schema/railroad.md](schema/railroad.md#administration)) and it resolves to
  that field. Nothing is lost: a leading-field boundary is still a whole number of shards, which
  is all the coarsening claim needs.
- **Nesting is derived from containment, not declared.** A row whose interval lies inside
  another's is its child, so there is no parent foreign key to keep in agreement with the
  bounds. Most-specific-match is the narrowest interval containing the key.
- **Siblings may not overlap**, and every interval must lie wholly inside the next-widest one.
  Both are checked when the row is written, against the rows already in the family.
- **All three role fields read `Quarantined` together, or none does.** A partially assigned
  range has no meaning; see [Quarantine](#quarantine-needs-no-mechanism) for the one operation
  that writes the all-`Quarantined` form.

Storing the *boundary shard* instead of the bound value was considered and rejected. It would
have made "every range boundary is a partition boundary" true by construction, but comparing an
incoming key against a boundary named by a root row requires reading that row, which requires
routing — the routing table would depend on the routing it decides.

## Elevation Is Automatic; Failback Is Not

A shard whose primary stops answering promotes a secondary on its own. Moving authority *back*
is an operator act.

The asymmetry is the one OQ-007 already uses to keep a `UserData` split manual: **elevation
restores availability; failback only rebalances.** Only the second can wait for a human, so only
the second does.

### The Epoch Fences the Old Primary

Every role assignment carries an `epoch`, and every transaction node carries the epoch of the
term that ordered it. A replica rejects a node whose epoch is below the highest it has seen, and
a server holding a stale epoch has its writes refused and is told the current assignment. A
primary that was unreachable rather than dead therefore cannot land its in-flight writes after
its term ended, and it learns it lost as soon as it talks to anyone.

The epoch is in two places on purpose. On the range-tree row it says *who may write now*; on the
transaction node it says *which term ordered this*, which is the only one of the two a replica
can check without consulting a range tree it may itself be behind on.

### Two of Three, Not One of Two

A secondary that has not heard from the primary within the failure-detection window proposes
itself at `epoch + 1`, and must collect acknowledgements from **two of the three role holders,
counting itself**, before the range-tree row is written. A role holder acknowledges at most one
proposal per epoch.

Two candidates each needing a majority of three cannot both succeed, which discharges OQ-006's
split-brain constraint by counting rather than by coordination. The rule is also why the range
tree is the one `Configuration` table written by the shard's own role holders rather than by a
schema-shard primary: the structure that decides who serves cannot depend on a server it chose.
The winning row is committed on the shard whose roles it names and reaches every other server
through the ordinary `Configuration` fan-out. No server outside the triple votes; for them the
row is a read.

**A promoted secondary needs no log-recovery phase**, and that is what the synchronous class's
cost buys. Requiring both secondaries to acknowledge is a 3-of-3 write quorum, strictly less
available than a 2-of-3 majority — a deliberate trade, taken because it makes every surviving
secondary hold every committed transaction. Promotion is then a role change rather than a
reconciliation: no "which replica has the longest log" question, and no window in which an
acknowledged write is lost. Under the batched class the trade is not taken, and the cost is the
one stated with the class — up to one batch.

### Rejoining

A server that lost its term rejoins as a **tertiary**, never as its old role.

1. It reads the current assignment and finds its epoch stale.
2. It truncates every node it appended under that epoch which the new primary does not hold.
3. It fetches the sequence ranges it lacks over the announce-and-fetch path, like any other peer
   that fell behind.
4. An operator returns it to secondary or primary if that placement is wanted — the host
   rotation procedure above, unchanged.

Step 2 discards nothing a reader saw. A transaction is not committed until two secondaries hold
it durably, so a node the new primary lacks was never acknowledged and was never visible.

**What is open is the timing, not the mechanism.** How long a primary may be unreachable before
a secondary proposes itself is a `Configuration` value rather than a constant — a
cross-continental secondary and a rack neighbour want different numbers — and which detector
produces that signal is the rest of OQ-006.

## Replication Protocol

### Transaction Propagation
- Transactions are **sequence-numbered deltas** within a shard
- The primary assigns sequence numbers; all replicas apply them in order
- Secondaries acknowledge durability before a transaction is considered committed, in the
  synchronous durability class below
- Tertiaries receive transactions asynchronously — eventual consistency for reads, no durability guarantee

### Two Durability Classes

Every shard has exactly two secondaries, `LogData` included. What differs is whether the primary
waits for them.

| Class | Commits when | Default for |
|---|---|---|
| Synchronous | both secondaries have appended and fsynced the frame | `UserData`, `Configuration`, `Reference` |
| Batched | the local append is durable; secondaries catch up in batches | `LogData` |

**The ACK is durability, not receipt**, and the distinction is the whole content of the class. A
secondary that acknowledged into memory and then lost power would leave the transaction on one
copy, so the synchronous class would buy nothing against the correlated power or datacenter loss
that geodiversity exists to defend against. The cost is stated rather than hidden: one fsync per
secondary per commit, on top of the round trip.

`LogData` is high-volume, its value is aggregate rather than per-row, and paying two network
round trips per log append would put the slowest path in the cluster on the hottest one. Batched
replication is the right default for it.

**It is a default, not a property of the trait.** Losing a server before its batch ships loses
up to one batch, and some `LogData` is audit evidence that cannot be reconstructed —
`system.integrity.Violation` with `origin = Observed` or `Forced` is exactly that
([integrity.md](integrity.md#two-classes-of-nonconformance)). Silently making it lossy would
undo the retention guarantee that answered OQ-032.

So durability is a `Configuration` row keyed by table path and resolved most-specific-first —
the same shape as `ExtentPolicy`, and for the same reason: staging and production should be able
to differ without branching the schema
([schema/traits.md](schema/traits.md#traits-are-not-configuration)).

```
table system.shards.DurabilityPolicy : Configuration {
  table_path : Text unique,
  durability : Synchronous | Batched,
  geodiverse : Bool = True
}
```

`table_path` rather than `table`, which is a reserved word — the same reason
`system.integrity.Violation` spells it `subject_table`. There is **no per-server override
table**, and that is where this policy stops following `ExtentPolicy` / `ExtentOverride`: an
extent size is a local storage choice, while durability is a property of a shard's commit, and
a shard's three role holders disagreeing about it would mean the guarantee names nothing.

Two knobs on one row, because they are the same decision seen from two sides: **how much do you
mind losing this?** `geodiverse` is the placement half, and it is what
`system.logs.HttpRequest` needs. That table motivated the "server-local" language the batched
class replaced, and it needs less protection than a violation log does — so its secondaries may
sit in the same region, or the same rack, which is also what makes its bandwidth cheap. The
relaxation is **geographic, not role count**, which is exactly the shape
[Cold Shards](#cold-shards) already gives: *three role holders always; a dump is not one of
them.* One rule, two callers.

**A commit spanning two policies takes the stricter one.** Durability is a property of an
append: one shard, one sequence number, one decision about whether to wait. Keying the policy by
table path is right — it is the granularity an author reasons about, and it matches every other
`system.shards` policy — but it means a transaction touching two tables in one shard can name
two classes, and only one of them can be honoured. `Synchronous` wins, because the alternative
voids a guarantee somebody asked for in order to save a round trip somebody else did not ask to
save. In practice the case is rare: a `LogData` table is rooted at a `LogSegment` row and a
`UserData` table at its own root, so they are not in the same shard to begin with.

Nothing else changes. A `LogData` shard is already rooted at a `system.shards.LogSegment` row
whose key the range tree partitions on, so assigning it two secondaries is ordinary role
assignment, and batched deltas resume through the announce-and-fetch path like any other
sequence range.

### Push for Liveness, Fetch for Resume

Both directions exist and they answer different questions. Push is already mandatory for the
authoritative three — a secondary must ACK before the primary commits, so the commit fan-out is
a push — and the design extends that same fan-out to tertiaries and subscribed clients rather
than introducing a second mechanism.

| Mechanism | Who | Carries |
|---|---|---|
| **Commit fan-out** (push) | secondaries, then subscribed tertiaries and clients | the delta, or an invalidation |
| **Announce / fetch** (swarm) | any peer that has fallen behind | missing sequence ranges, pulled from any neighbour that has them |

The swarm is the catch-up path: each server announces which sequence numbers it holds, and a
peer fetches what it lacks from whoever has it rather than from the primary alone, which
distributes replication bandwidth and avoids saturating a single node. Network paths between
servers may be pre-declared as an optimization hint, not a requirement. Secondaries are
expected to be fully caught up; tertiaries may lag.

A client that was offline and a tertiary that lagged want the same thing — "deltas since
sequence N" — so resumption is one protocol serving both.

**Announce-and-fetch also addresses chunk digests, not only sequence ranges.** A large `File` is
stored as `Component` chunks named `<parent DataId>.<ordinal>`, each carrying a digest, and each
written as its own transaction — so a peer can ask for one chunk without pulling the transaction
that carried it, and a file propagates from whoever has the piece rather than from the primary
alone. Nothing new is required: the pieces are already named, already ordered, and already one
contiguous range scan. The digest is for **verification and transfer only, never for identity** —
sharing one content row across owners would break `erase` and collapse several access policies
onto one row, so deduplication stays rejected.

### What Gets Pushed Depends on Who Is Listening

> **Payload between servers. Invalidation to clients.**

A server-to-server push carries the delta: a tertiary already holds the whole shard and
presents a server token, so there is nothing to filter.

A client push carries `(shard, sequence, affected table paths and row identifiers)` and nothing
more. The client re-reads through the ordinary query path, where its access asserts are
evaluated by the code that already evaluates them. Pushing payloads to clients would require
the commit path to evaluate every subscriber's access asserts per row — an access decision on
the write path, which this design deliberately does not have anywhere else.

**An invalidation is access-controlled information, so the check moves to subscribe time.** A
table path plus a row identifier discloses that the row exists and when it changed, and repeated
invalidations disclose an activity pattern — which is exactly what returning `Redacted` rather
than an error protects on the read path. So:

- A client **declares an interest set**: a table path, optionally narrowed to one shard. That
  shape is what lets per-connection state be sized, and it is the coarsest thing a server can
  match a commit against without a per-row evaluation.
- The server evaluates the same access asserts against the interest set **when the subscription
  is created**, and rejects it outright where nothing in it is reachable.
- An assert whose truth depends on row *data* cannot be settled at subscribe time. Such a
  subscription is admitted only in its statically decidable form — the client is told the
  narrowing — because the alternative is a per-row access decision on the write path, which is
  the thing this section refuses.
- **A revoked grant drops the subscription.** Revocation is a commit, so the fan-out that
  carries it is the one already running; the connection is closed and the client re-subscribes
  under whatever it still holds.

**Push is not faster than a parked keep-alive.** A held long-poll, an SSE stream, and an HTTP/2
server push are the same thing on the wire: the connection is open and the server writes when
it has news, one way, about half a round trip. What costs latency is *periodic* polling, which
averages half the interval. So there is no latency argument for a bespoke push protocol — the
real constraints are how many parked connections a node can hold, and that an HTTP/1.1 client
needs a second connection so a parked subscription does not head-of-line its requests.

Subscriptions are **in-memory per-server state, not rows.** Making connect and disconnect
commits would put a write in the connection path. What may be durable is a client's declared
interest set, for resumption — and resumption is the sequence-fetch path above.

**A `Behavior` cannot be pushed.** Its value changes with no write, so there is no commit to
trigger a notification. A client watching `balance >= credit_limit` is asking the scheduler to
solve for a crossing (OQ-034) or to sample it with `every`; it is not a replication question,
and a subscription that treats it as one receives silence.

### Shard Splits
When a shard's data volume crosses a threshold, it splits:
1. The split is recorded as a special node in the transaction graph
2. The split node records the partition function (which rows go to which child shard)
3. New child shards begin accepting writes; parent shard becomes read-only at the split point
4. All servers that had the parent shard receive notification and begin syncing the child shards

The partition function ranges over **shard root rows**, and the key it partitions on is the
root table's candidate key — which is why that key is mandatory and why every other key in the
shard must reach the root through its foreign-key chain. A dependent row's placement is
therefore decided by the same split that placed its root, and no split *at a key boundary* can
separate a row from the root it is keyed against. A single-root shard splitting at a `DataId`
boundary does separate dependents from their root, which is why its sub-shards form a shard
group sharing one primary — see below. See
[transaction-graph.md](transaction-graph.md#shard-roots) and
[schema/tables.md](schema/tables.md#keys-must-be-rooted).

**A keyless table partitions on `DataId`.** The partition function needs a total order, not an
identity, so `LogData` — which declares no candidate key — partitions on the time source
carried in the high-order bytes of every `DataId`, rooted at a `system.shards.LogSegment` row
keyed by `{ origin_server, period_start, branch }`. See
[transaction-graph.md](transaction-graph.md#placement-keys-are-not-identity-keys).

**A shard with one root row splits on `DataId` too**, into sub-shards forming a **shard group**
that shares a primary. Non-root uniqueness, `assert` evaluation, and `Ordinal` assignment are
all defined as holding within one shard and linearized by its primary, so splitting a whale
splits storage and read capacity but never write authority. `LogData` needs no group — no
candidate keys, no cross-row asserts, and nothing to linearize beyond the append itself.

### Three Thresholds, Three Behaviours

The operations are not equally disruptive, so they are not equally automatic:

| Trigger | Action | Authority |
|---|---|---|
| An extent fills | Allocate the next; repartition in the background | Automatic and invisible — no locator changes, no graph node, nothing replicates |
| A `LogData` segment's grain bucket closes, or its segment exceeds the size threshold | Seal the segment and start a new one | Automatic — sealing moves no data |
| A `UserData` shard exceeds the size threshold | Report; wait for `split shard … at key` | Operator — a split redistributes roots and moves authority |

The line is mechanical rather than a matter of taste: an operation that moves no data and
writes no graph node can be automatic, and one that moves authority cannot. Thresholds and the
segment grain are `Configuration` rows (`system.shards.ExtentPolicy`, with a per-server
`system.shards.ExtentOverride`), not syntax and not trait parameters — see
[schema/traits.md](schema/traits.md#traits-are-not-configuration). This answers OQ-007; the
default values are OQ-035.

## Schema Shards Are Rooted at a Branch

The schema is data, so it is sharded like data: **one shard per branch**, rooted at the branch
row. The branch name is that root's candidate key, which makes OQ-026's "all branches must be
named" load-bearing rather than a policy — a root table's key is the cluster-wide shard
directory ([transaction-graph.md](transaction-graph.md#shard-roots)), so an anonymous fork would
be a shard nobody can route to.

Branches therefore get independent primaries. Schema work on two branches does not contend, and
a merge to `main` serializes at `main`'s primary, which is the only place it could.

| Lives on the branch shard | Lives elsewhere |
|---|---|
| Schema nodes: types, tables, traits, functors, routes | `Configuration` rows — operator tuning that must survive a merge |
| `Reference` rows, because inserting one *is* a schema transaction ([schema/traits.md](schema/traits.md#reference-tables-are-code)) | Table-wide `unique` value indexes (below) |

That split is the existing trait/configuration line ([schema/traits.md](schema/traits.md#traits-are-not-configuration)) doing the work: a branch may change what a table *is*, and must not silently
change how a deployment *treats* it.

### The Row Is Branch-Versioned; the Variant Tag Is Cluster-Wide

A `Reference` row lives on the branch shard, but the 2-byte **variant tag** it is stored under
does not. Two branches allocating tag 7 to different names would produce a merge carrying two
meanings for one tag, and renumbering cannot repair it — that would silently change the meaning
of every historical row already carrying the old tag
([schema/traits.md](schema/traits.md#reference-tables-are-code)).

A tag allocator is a table-wide `next`, and a table-wide `next` already has a home: the
constraint group's shard, beside the other cluster-wide counters (see
[Constraint Shards](#constraint-shards)). No new mechanism, and the cost lands on an operation
that is already a serialized schema commit.

One consequence: a genuinely offline branch cannot reach the allocator, so its `Reference` rows
exist **by name** on the branch and receive tags at upload. That is sound because a local branch
holds no user data, so nothing on it was ever stored under a tag.

### Local Branches

An administrator can create a branch on a workstation, work in it, and upload it — with no user
data present. Three consequences fall out, and the first is the useful one:

- **A local branch needs the schema graph to the branch point, plus its `Reference` rows, and
  nothing else.** `Reference` is low-to-medium cardinality, so the clone is bounded. "Without
  user data" is achievable; "without reference data" is not, because reference rows are code.
- **A new constraint cannot be validated locally**, since the rows it would be validated against
  are not there. Conformance is established per shard **at merge**, which is the bulk-mutation
  path below, reporting per shard. `enforce forward` is what keeps that merge non-blocking.
- **A local branch is not durable until uploaded.** It has no secondaries. This is the unpushed
  git branch and behaves like one; uploading is role assignment on a shard that already exists,
  the same act as bringing a new host into rotation.

Validation reads merged nodes only, so a local branch is inert with respect to the cluster for
the same structural reason a prepared transaction node is.

**A local branch is also the one place schema reclamation is free.** A schema node is
discardable exactly when no row was ever committed under it, and on a local branch none was, by
construction — the bullet above is the proof. So a merged branch's exclusive nodes become
prunable once nothing references them, through the refcount `prune` already needs, with no merge
mode and no rewriting. Squash-merging them away was rejected: a squashed branch is not a parent
of anything on `main`, so "a branch with any path to `main` cannot be deleted" stops protecting
it and history destruction arrives by convention. General graph reclamation is the open part;
this corner of it is not.

## Constraint Shards

A table-wide `unique` is the one constraint whose scope is the whole cluster
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)). Its value index does **not**
live on the schema shard, and it is not branch-versioned.

Putting it on the schema shard was considered and rejected: the index holds every value of the
column across the cluster — user-data volume in the shard that also holds DDL — it cannot split,
and one primary would then serialize writes to every table in the cluster that declares such a
constraint. The consequence that decided it: schema-shard unavailability would stop all writes
rather than only DDL.

### The Shard Is Rooted at a Group, Not at a Schema Node

```
table system.shards.ConstraintGroup : Configuration {
  name    : Text unique,
  members :> ConstraintMember : Component {
    constraint : Text unique,
    generation : Int = 0
  }
}
```

Rooting the constraint shard at the constraint's own schema-node row was the first answer and it
fails twice. A schema node is branch-versioned, so redeclaring the constraint on a branch mints a
new node, hence a new root, hence a different shard and a different index — which contradicts
the index spanning branches. And a shard is identified by its root *row*, so one root per
constraint makes "one constraint shard per namespace subtree" unrepresentable: a namespace
subtree is not a row.

A `ConstraintGroup` row is that missing row, and it is what the shard is rooted at. Each member
names its constraint by the **branch-invariant path** `<table>.<constraint-name>`, which survives
redeclaration — so the index spans branches by construction rather than by assertion, and
namespace-subtree grouping is an ordinary default. `generation` is the digest-key generation
described below; the per-constraint state that used to be imagined on a per-constraint root row
lives on the member instead.

**A constraint belongs to exactly one group, cluster-wide.** A `unique` on a component is
checked within its parent, so that declaration alone gives uniqueness within a group. The
cluster-wide check happens at schema commit instead, against the fully replicated
`ConstraintGroup` table — which is what stops the regress: the registry that routes table-wide
`unique` checks must not itself need one.

The shard is splittable by digest range, with its primary placeable near the writers and movable
by ordinary elevation. This also answers OQ-035's open question about where a table-wide `next`
counter lives: it is a row in that group's shard, and so is the `Reference` variant-tag
allocator.

### The `unique` Index Holds Digests, Not Values

> **The index stores a keyed digest of the value, never the value, and partitions on the
> digest.**

A `unique` constraint is satisfied by equality alone, so the index has no use for the plaintext.
Storing it anyway would put every email address in the cluster into a shard that is neither the
subject's nor prunable, replicated, and reachable by anyone who can read the constraint shard.

Four things follow, and the third is the one that decided it:

- **Constraint shards hold pseudonymised data, not plaintext.** The plaintext never leaves the
  subject's shard, so the exposure from reading a constraint shard is bounded. It is not
  anonymisation and must not be described as such: the keying material is held by the same
  controller and deliberately retained, so singling-out and linkability survive — GDPR
  Art. 4(5) calls keyed hashing pseudonymisation, and Recital 26's test is attributability using
  information reasonably likely to be used. Anyone who can read the shard *and* reach the key can
  confirm membership for a candidate value.
- **Enumeration is unchanged.** Any uniqueness constraint tells you "taken" for a value you
  already hold. That is inherent to the construct, and the digest neither adds nor removes it.
- **Reserving a value costs nothing**, which is what makes the release rule below a semantic
  choice rather than a privacy trade.
- **Cluster-wide ordering on the column is given up.** There was never a usable one — a
  cross-shard `order by` is a distributed merge regardless.

**Erasure still reaches the index, and it reaches it twice.** The entry is tombstoned, which
removes it from the current state; and retiring the member's digest-key generation renders every
entry written under it unrecoverable. That second half is crypto-shredding in the one place it is
free (OQ-037) — the key already exists, generations already exist, and nothing has to be
re-encrypted. What the digest construction buys is that the cross-shard half of the erasure
problem is *bounded*, not that it disappears: an `erase` propagates a tombstone to the
constraint shard like any other cascade.

The digest key is scoped **per constraint**, and it needs no new mechanism: it is a
`system.crypto.DataKey` named for the constraint's branch-invariant path, resolved by name
exactly as `CipherPolicy` resolves its key material, wrapped under the envelope in
[auth.md](auth.md#envelope-encryption-and-key-custody). The `ConstraintMember` row records which
generation is current, so nothing about the key is stored beside the digests it produced.

Key scope must equal comparison scope: a per-server key would produce two digests for one value
and the constraint would silently never fire.

Rotating it cannot recompute entries whose plaintext is gone, so entries carry a generation tag
and a check probes every live generation. Generations are rare; the probe count is one or two.
That is also the mechanism the erasure paragraph above spends: `DataKey` is already keyed
`{ name, generation }` precisely so a rotation adds a generation instead of replacing a row.

### A Reserved Value Is Released Only Deliberately

A tombstone does not free the value. The reason is stronger than privacy: a root table's
candidate key **is** the cluster shard directory
([transaction-graph.md](transaction-graph.md#shard-roots)), so freeing it and letting it be
re-registered would make the directory resolve one key to two shards depending on the sample
moment. Routing would stop being a function.

| Kind of `unique` | On delete or erase |
|---|---|
| Is, or contains, a root table's placement key | Reserved permanently. `release` is rejected. |
| Any other | Reserved, and releasable by an explicit `release`, recorded with authority and reason. |

`release` applies only to a value whose owning row is deleted or erased. Releasing a live row's
value would break the constraint it is declared under, so the command is **rejected when it
runs, naming the live row**. It cannot be a compile-time check: whether the owning row is
deleted is row state, and `release` takes a value, not a declaration. The genuinely static
rejection is the one in the table above — a placement-key release is refused unconditionally.

After a release and re-registration the value identifies different rows at different sample
moments. That is correct and already handled — key resolution happens at the query's moment —
but it makes one thing normative: a lookup by unique value resolves **at the query's sample
moment**, not at HEAD.

The rule also decides what a re-key may do. A write that changes a row's shard root is a delete
plus an insert, and the delete tombstones every `unique` value the row held — so a second
`unique` whose value did not change would collide with its own tombstone. The mutation is
therefore rejected, naming the constraint, and the escape is this command: `release` the value
deliberately, with its authority and reason, then re-key. Auto-releasing inside an ordinary
update would defeat exactly the property this section exists to protect.

### Constraint Groups

A transaction touching two table-wide constraints in different shards is a two-participant
cross-shard transaction, which costs a second hop. Constraints that tend to be touched together
should therefore share a primary.

"Together" has to be **declared**, because inferring which constraints an interactive or API
transaction might touch is not decidable. The default grouping is **one `ConstraintGroup` per
namespace subtree** — namespaces are already the grouping axis with inheritance semantics
(OQ-024), and a transaction spanning namespaces is already the unusual case. Reassigning a
constraint moves its `ConstraintMember` row to another group — a change of shard root, so a
delete plus an insert, carrying that constraint's index entries with it. It is an operator act
with a bulk cost, which is the honest shape for something that relocates an index.

**Colocation is an optimization, not a correctness requirement.** A transaction spanning two
groups is an ordinary multi-participant prepared-node transaction: it costs hops and nothing
breaks. Schema commit therefore *warns* where the touched set is static — generated routes,
declared functors — and stays silent where it cannot know. A hard rule here would be
unenforceable and would need exceptions immediately.

### Constraints Span Branches

The value index is shared across branches while the constraint's *declaration* is
branch-versioned. Two consequences follow:

- **An unmerged branch's table-wide `unique` has a partial index**, since only writes routed
  through that branch's version token are checked against it. The index is backfilled at merge —
  another bulk mutation with a per-shard report — and pre-merge the constraint is
  `enforce forward` by construction rather than by declaration.
- **A branch cannot change the value set of a table-wide `unique`**, only whether one is
  declared. Which is the same fact as "a local branch holds no user data", seen from the
  constraint's side.

## Materialized View Distribution

Materialized views are maintained independently per server but can be computed cooperatively:
- A server can broadcast a query plan fragment to neighbors
- Neighbors compute their local contribution and return results
- The requesting server merges contributions
- This is particularly useful for tertiary servers dedicated to analytical workloads
- View computations are pegged to a stable commit node so they can proceed without blocking ongoing transactions

Integrity reporting uses this path. Violations are written to the shard holding the subject
row — a single global violations table would be a cluster-wide write hotspot and would break
the `UserData` shard-local invariant — so "show me everything nonconforming" is a distributed
query merged from every participating shard. The report names which shards contributed, so a
partial result is never mistaken for a clean one. See [integrity.md](integrity.md).

## Commit Protocol (Simplified)

```
Client → Primary: mutation request
Primary → Secondary1, Secondary2: proposed transaction (sequence N, epoch E)
Secondary1 → Primary: ACK (appended and fsynced)
Secondary2 → Primary: ACK (appended and fsynced)
Primary: commit (sequence N confirmed)
Primary → Client: success
Primary (async) → Tertiaries: propagate via peer swarm
```

The primary does not wait for tertiary acknowledgment. Tertiaries are eventually consistent.

Under the batched class the primary commits and answers the client after its own append is
durable, then ships accumulated deltas to the secondaries. The steps are the same; only the wait
moves.

## Cross-Shard Transactions

There is no distributed lock. A cross-shard transaction is a **prepared node per participant, one
commit node at the coordinator, and one acknowledgement node in each other participant's shard**
— the graph's existing branch-and-merge shape applied at transaction scale:

```
1. A validates against pinned graph point P_A; appends a PREPARED node carrying the operation,
   P_A, and the read set it validated over. Invisible to reads. A keeps accepting other writes.
2. A sends (operation, P_A, prepared id) to B's primary.
3. B validates against its own pinned point P_B; appends its PREPARED node, carrying the
   operation, P_B and its own read set; answers yes or no.
4. yes → each side re-checks its read set against its current head. Both unchanged → A appends
          the COMMIT node and B appends a COMMIT-ACK node in its own shard; both halves
          become visible.
   no, or either read set advanced → A appends an ABORT node; nothing was ever visible.
```

What crosses the wire is the **operation**, not a row set, and each participant validates
locally against a point it pinned itself. There is no global coordinator — the coordinator is
whichever server accepted the mutation.

This replaces the cross-server lock on a `transaction_id` held until all operations complete
(OQ-027). A prepared node is not a lock: it excludes nothing, and A serializes only its own
writes, as it always did.

**Step 4's re-check is the validation phase, and the protocol is unsound without it.** Two
failures follow from omitting it:

- **The coordinator's own writes go unchecked.** A validated at P_A in step 1 and kept
  accepting writes, and nothing defines which of them are "unrelated".
  `assert underLimit { count (self.orders where status is Open) < 5 }` passes at A with four
  open orders, a purely local write opens a fifth, A appends COMMIT, and the constraint is false
  with no violation recorded. The read set is what makes "unrelated" a checkable property
  instead of a hope.
- **Symmetric transactions both commit.** If a transaction coordinated at A and one coordinated
  at B each touch rows in both shards, neither sees the other's prepared node, so both validate.
  Invisibility removes the wait *and* the detection.

That second case is why the earlier claim — "the only outcome is an abort" — was backwards:
without a re-check the outcome is a *lost* conflict, not an abort. Restated:

> **Neither participant waits, so deadlock is unrepresentable. Conflicts are detected at commit
> by re-checking the read set, never avoided by exclusion.**

**Validation reads merged nodes only.** This one invariant does three jobs — it is why a
prepared node is invisible, why an unmerged schema branch does not affect the cluster, and why
an administrator's local branch is inert until uploaded. Concurrent `A → B` and `B → A` chains
cannot wait on each other's prepared nodes, because neither can see them, so there is no
wait-for edge to close.

**B appends its own commit-acknowledgement node.** A's commit node is in A's shard and reaches
A's replicas; B's replicas hold no record of the outcome, so without the ack a reader on B
cannot tell a committed transaction from an abandoned prepare. The ack is B's local statement of
the outcome, and it is what makes B's half of the transaction readable on B's own replicas.

Prepared nodes are named by their own `DataId`, which satisfies OQ-026's prohibition on
anonymous DAG forks without a carve-out for transaction-scoped branches.

### A Re-key Is an Ordinary Two-Participant Transaction

A write that changes a row's shard root is a delete in the source shard plus an insert in the
destination shard, which needs no new machinery — it is the protocol above with two
participants. Four rules make the supersession record it carries legible:

- **Both prepared nodes carry an identical record.** A record on the source alone is invisible
  to the destination forever, which defeats it for the reader who needs it.
- **The commit node carries none**, and nothing in the record may be a value unknown at prepare
  time — not the commit node's id, not the outcome. B writes at step 3; A appends the commit node
  at step 4.
- **The record inherits its carrier node's visibility.** It is a historical statement about one
  transaction, not a live successor pointer, so an unresolved or aborted prepared node renders as
  pending or aborted rather than as a move.
- **Its content is a pure function of the operation both participants validated**, so the two
  copies agreeing is a property of the definition rather than of a check. Nothing existing could
  verify it — `verify shard` compares replicas of one shard, and these are two shards with
  different replica sets — so a detected divergence is a bug, recorded as a
  `system.integrity.Violation` with `origin = Forced`.

The record's fields and its place in the frame are in
[storage.md](storage.md#wire-format-for-replication).

### Why Re-validation Rarely Fails

The optimism is derived rather than hoped for. An assert's query must be rooted at `self`
([schema/constraints.md](schema/constraints.md#anchoring)), so its predicate depends only on the
subject row's connected component — which is also what bounds the read set each side records and
re-checks. A re-check can therefore fail only if something committed in the same shard, between
the pin and the commit, that touched those same rows. That is a genuine write conflict and has
to fail regardless of how the transaction was coordinated.

### Constraints That Cross Shards Cannot Promise `enforce always`

Anchoring bounds *work*, not *locality*: an FK may point into another shard, and a negative
assertion's revalidation set is the FK chain traversed backwards
([schema/constraints.md](schema/constraints.md#anchoring)). So a write in shard C can invalidate
an assert on a row in shard A, and no amount of pinning at A and B observes it. That guarantee
is unachievable without exactly the lock this design removes.

An attachment whose revalidation set crosses a shard boundary is therefore restricted to
`enforce forward`, `monitor`, or `repair into` — never `enforce always`
([integrity.md](integrity.md#enforcement-modes)) — and the breach surfaces as a
`system.integrity.Violation` rather than as a rejected write.

Schema commit **names the crossing edge and reports the coercion**. An author who wrote
`enforce always` and silently received `forward` would be facing exactly the sort of
read-behaviour change that OQ-005 already requires be surfaced in the commit diff.

## Bulk and Cluster-Wide Mutations

A mutation whose predicate is not anchored to a single shard cannot be executed by one primary.
It becomes a node on the schema shard that every shard primary applies to its own shard.

**The gate is structural, not a role check.** What makes such a mutation dangerous is its
*scope*, which is readable off the query — the same discipline by which an assert's variety is
read off its body rather than its name (OQ-005). An ordinary grant on the system table controls
who may use the path; privilege is a consequence of the rule, not the rule.

**Application is per shard, independent, and may be partial.** Each primary validates every
affected row against the full constraint set — a bulk mutation is subject to the same rules as
any other write — and records what it did in its own shard. The initiator's report is a
distributed query merged from every participating shard, exactly as integrity reporting already
works, and **it names which shards contributed, so a partial result is never mistaken for a
complete one** (see [integrity.md](integrity.md)).

Three consequences worth stating:

- **The initiator subscribes; it does not block.** A synchronous "wait for all primaries" return
  value cannot express "shard 47 is down". A per-shard application record can, and does so
  permanently.
- **It is restartable by construction.** A shard that was unreachable applies the node when it
  returns, because the node is in the graph and its application is a per-shard fact rather than
  a message that was missed.
- **Records stay in the shard.** One row per (operation, shard) written to the schema shard
  would make every bulk mutation a fan-in burst on the one node least able to absorb one.

The one case that resists independent per-shard validation is a bulk mutation touching a
table-wide `unique` column, whose authority lives outside every data shard (see
[Constraint Shards](#constraint-shards)).

## Deferral: Reads and Mutations Are Different Problems

**Global reads need no deferral.** A query is pegged to a `(commit node, sample moment)` pair
([schema/queries.md](schema/queries.md#every-query-has-a-sample-moment)) and never blocks a
writer. What an analytical scan can do is starve local work of I/O, which is a resource budget,
and the answer is the one already in this document: dedicated tertiary servers, with a budget.

**Global mutations queue.** They are queue rows processed by the event scheduler under a
`Configuration` policy, which already carries `backoff_base` and `aging_rate`
([events.md](events.md)). Cross-shard prepares and cluster-wide mutations are the same kind of
work item: a verified operation pinned to a graph point, admitted by a shard primary when its
queue position comes up. One mechanism, two callers.

**Admission never depends on another operation**: **the shard's write queue reaches zero, or the
item's age exceeds the aging threshold.** The first gives local work precedence and lets global
work resolve while a shard is quiet. The second is what prevents a steady local stream from
starving it forever — "wait for the server to be idle" alone has no guarantee of progress on a
busy server.

The age half does read a clock, and that is admissible here for a reason worth stating rather
than eliding: the age is a `Behavior Duration` sampled by the scheduler in `Effect`, which is
the one context permitted to read the clock. Nothing inside a functor reads it, so *time is a
parameter, never ambient* holds unchanged.

Which yields the property the whole arrangement exists for:

> **No operation waits on another operation. It waits on a queue position, and queue positions
> age.** There is no wait-for edge, so deadlock is unrepresentable rather than avoided.

That holds only alongside "validation reads merged nodes only" — a validation permitted to
observe a prepared node would reintroduce the wait-for edge this removes. The two are one
decision.

## Cold Shards

A shard nobody has written to for years should not occupy premium hardware. The relaxation that
buys that is **placement, not role count**.

> **Three role holders always. A dump is not one of them.**

An exported file is not verified, not sequence-tracked, and does not participate in the swarm,
so "we have a backup" is a claim nobody checks until restore day. Over a seven-year audit
retention the failures that actually arrive are regional loss and bit rot, which is precisely
what two geodiverse copies defend against and a single unverified file does not.

What may be relaxed instead:

- **Hardware class.** A cold shard's primary and both secondaries may sit on slow, cheap hosts
  on cheap storage.
- **Read path.** A cold shard is sealed — read-only until something touches it — so its hosts
  carry no write load.
- **Nothing else.** Geodiversity is retained, because it is the property the seven-year window
  needs most.

Moving a cold shard to cheaper hosts is a range-tree edit, which is what the coarsening of the
partition function was designed to make free.

**One sanctioned exception to "three role holders always": a range may name zero serving
roles.** That is the quarantine form, and it is an exception to *serving*, not to *holding* —
the three hosts keep their copies and stop answering, so durability is untouched and the shard
is simply unreachable. It is recorded here, beside the invariant it qualifies, rather than only
at the recipe that uses it.

The relaxation also has a second caller. `system.logs.HttpRequest` gives up geodiversity, not
role count, through `system.shards.DurabilityPolicy.geodiverse` — the same rule read from the
opposite end. See [Two Durability Classes](#two-durability-classes).

Where an operator insists on one copy plus a dump, the honest form of that is a dump that is
content-addressed, whose checksum is recorded as a graph node, and which a scheduled event
re-reads and reports on. That makes it a replica with a slow protocol rather than a hope, and
`verify shard` can then say something true about it.

### Sunset Is Proposed, Never Automatic

The maintenance queue notices a shard that has been inactive past a `Configuration` threshold
and **proposes** sunsetting it. An operator accepts.

This is the rule that already governs materialized views ([storage.md](storage.md#views-are-proposed-not-created-silently))
and the per-field timestamp cache, applied one scope wider, and it lands on the same side of the
line as `split shard`: an operation that moves authority is not automatic. Reading the
inactivity threshold is the maintenance queue's business, in `Effect`; deciding on it is the
operator's.

**Rolling up `UserData` history is a `retain` chain, not a command.** Collapsing a row's version
range is prunable-data semantics, and it is subject to the same rule as every other prune —
[it is only ever the consequence of a declared chain](schema/aggregates.md#pruning-is-only-ever-a-consequence).
The ordered `where` / `otherwise` branch form is what makes "these specific rows" expressible
without a manual prune. What to expect of the result is in
[schema/aggregates.md](schema/aggregates.md#retain-on-userdata-is-admissible-and-rare), which
owns it.

### Quarantine Needs No Mechanism

"Make this shard unreadable and unreplicated pending review" is **one row**: assign the shard a
range-tree entry naming no serving roles. Nothing serves it, so nothing reads it and nothing
replicates to it; the three former holders keep their bytes, so nothing is lost; and restoring
service is rewriting the triple, which is what an operator wants in the first hour of an
incident.

Revoking the namespace grant was the other half of this recipe and it is **withdrawn**. Grants
are namespace-scoped and recurse to descendants (OQ-024), while a shard is one row-rooted slice
of a family — so revoking the grant on `app.commerce` would make every customer's shard
unreadable rather than the one under investigation, which is the outage quarantine exists to
avoid. There is no per-shard grant, and the zero-role range does not need one.

It is documented as a recipe rather than built as a keyword. A dedicated `quarantine` verb would
add a second way to say what role assignment already says, and the two would drift.

## Geo-Diversity Goals

| Role | Target placement |
|---|---|
| Primary | Close to primary write workload |
| Secondary 1 | Different region from primary |
| Secondary 2 | Different region from both primary and Secondary 1 |
| Tertiaries | Anywhere — near read workloads or analytical clusters |

These are the defaults. A table whose loss is cheap relaxes them through
`system.shards.DurabilityPolicy.geodiverse`, and `system.logs.HttpRequest` is the one table that
does today — see [Two Durability Classes](#two-durability-classes). Role *count* relaxes in one
case only, and it is quarantine: a range naming no serving roles at all
([Cold Shards](#cold-shards)).

## Open Questions

- Failure detection and the unreachability threshold before a secondary proposes itself
  (OQ-006 — the elevation *mechanism* is settled above).
- Default extent size and segment grain, and whether a shard group forms automatically or by
  operator action (OQ-035 — the split *trigger* is settled above).
- How network path hints are declared and stored (OQ-012).
- The parked-subscription ceiling and its eviction policy (OQ-012).
- The I/O budget mechanism for analytical reads on a tertiary (OQ-012).
