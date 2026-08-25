# Distribution Architecture

## Server Roles

DataCode uses a three-tier server model per shard. Roles are not fixed to machines — they are assignable and transferable.

### Primary Server
- **Authoritative serialization point** for all mutations to its shard
- All writes go through the primary; it determines commit order
- Not distributed consensus (not Raft/Paxos) — the primary decides, secondaries confirm receipt
- Should be geographically close to the heaviest write workload, ideally close to the primary user population
- If the primary goes down, a secondary is elevated (see Elevation Protocol below)

### Secondary Servers (exactly 2 per shard)
- Maintain a **complete copy of the full transaction graph** including all history
- Confirm receipt of every transaction before the primary considers it committed
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
`Configuration` at `UserData` cardinality, which is exactly what
[schema/traits.md](schema/traits.md#traits-are-not-configuration) forbids. Ranges are what keep
routing metadata inside its cardinality budget.

A **shard group** falls out with no additional concept: sibling leaves under a range with no
override share that range's triple, which is the definition of sharing a primary. See OQ-035.

The key that ranges are expressed over differs per family, exactly as placement does — the root
table's candidate key for `UserData`, the segment boundary for `LogData`, `DataId` as a last
resort (see [transaction-graph.md](transaction-graph.md#placement-keys-are-not-identity-keys)).
Since `DataId` is time-major, a range over it is a time range.

## Replication Protocol

### Transaction Propagation
- Transactions are **sequence-numbered deltas** within a shard
- The primary assigns sequence numbers; all replicas apply them in order
- Secondaries acknowledge receipt before a transaction is considered committed, in the
  synchronous durability class below
- Tertiaries receive transactions asynchronously — eventual consistency for reads, no durability guarantee

### Two Durability Classes

Every shard still has exactly two secondaries. What differs is whether the primary waits for
them.

| Class | Commits when | Default for |
|---|---|---|
| Synchronous | both secondaries ACK | `UserData`, `Configuration`, `Reference` |
| Batched | the local append is durable; secondaries catch up in batches | `LogData` |

`LogData` is high-volume, its value is aggregate rather than per-row, and paying two network
round trips per log append would put the slowest path in the cluster on the hottest one. Batched
replication is the right default for it.

**It is a default, not a property of the trait.** Losing a server before its batch ships loses
up to one batch, and some `LogData` is audit evidence that cannot be reconstructed —
`system.integrity.Violation` with `origin = Observed` or `Forced` is exactly that
([integrity.md](integrity.md#two-classes-of-nonconformance)). Silently making it lossy would
undo the retention guarantee that answered OQ-032.

So durability is a `Configuration` row, `system.shards.DurabilityPolicy`, keyed by table path
and resolved most-specific-first — the same shape as `ExtentPolicy` / `ExtentOverride`, and for
the same reason: staging and production should be able to differ without branching the schema
([schema/traits.md](schema/traits.md#traits-are-not-configuration)).

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

### What Gets Pushed Depends on Who Is Listening

> **Payload between servers. Invalidation to clients.**

A server-to-server push carries the delta: a tertiary already holds the whole shard and
presents a server token, so there is nothing to filter.

A client push carries `(shard, sequence, affected table paths and row identifiers)` and nothing
more. The client re-reads through the ordinary query path, where its access asserts are
evaluated by the code that already evaluates them. Pushing payloads to clients would require
the commit path to evaluate every subscriber's access asserts per row — an access decision on
the write path, which this design deliberately does not have anywhere else.

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
therefore decided by the same split that placed its root, and no split can separate a row from
the root it is keyed against. See
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
  which is the ordinary elevation machinery.

Validation reads merged nodes only, so a local branch is inert with respect to the cluster for
the same structural reason a prepared transaction node is.

## Constraint Shards

A table-wide `unique` is the one constraint whose scope is the whole cluster
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)). Its value index does **not**
live on the schema shard, and it is not branch-versioned.

Putting it on the schema shard was considered and rejected: the index holds every value of the
column across the cluster — user-data volume in the shard that also holds DDL — it cannot split,
and one primary would then serialize writes to every table in the cluster that declares such a
constraint. The consequence that decided it: schema-shard unavailability would stop all writes
rather than only DDL.

Instead, a table-wide `unique` is served by a shard **rooted at that constraint's schema-node
row**, splittable by digest range, with its primary placeable near the writers and movable by
ordinary elevation. This also answers OQ-035's open question about where a table-wide `next`
counter lives: it is a row in that constraint's shard.

### The `unique` Index Holds Digests, Not Values

> **The index stores a keyed digest of the value, never the value, and partitions on the
> digest.**

A `unique` constraint is satisfied by equality alone, so the index has no use for the plaintext.
Storing it anyway would put every email address in the cluster into a shard that is neither the
subject's nor prunable, replicated, and reachable by anyone who can read the constraint shard.

Four things follow, and the third is the one that decided it:

- **Constraint shards hold no personal data**, so erasure has nothing to propagate to them. The
  cross-shard half of the erasure problem disappears rather than being solved.
- **Enumeration is unchanged.** Any uniqueness constraint tells you "taken" for a value you
  already hold. That is inherent to the construct, and the digest neither adds nor removes it.
- **Reserving a value costs nothing**, which is what makes the release rule below a semantic
  choice rather than a privacy trade.
- **Cluster-wide ordering on the column is given up.** There was never a usable one — a
  cross-shard `order by` is a distributed merge regardless.

The digest key is scoped **per constraint** and lives in that constraint shard's root row,
beside the `next` counter, replicated to its three role holders. Key scope must equal comparison
scope: a per-server key would produce two digests for one value and the constraint would
silently never fire. It is an ordinary data key under the envelope in
[auth.md](auth.md#envelope-encryption-and-key-custody).

Rotating it cannot recompute entries whose plaintext is gone, so entries carry a generation tag
and a check probes every live generation. Generations are rare; the probe count is one or two.

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
value would break the constraint it is declared under, so that is a compile-time rejection
rather than a runtime one.

After a release and re-registration the value identifies different rows at different sample
moments. That is correct and already handled — key resolution happens at the query's moment —
but it makes one thing normative: a lookup by unique value resolves **at the query's sample
moment**, not at HEAD.

### Constraint Groups

A transaction touching two table-wide constraints in different shards is a two-participant
cross-shard transaction, which costs a second hop. Constraints that tend to be touched together
should therefore share a primary.

"Together" has to be **declared**, because inferring which constraints an interactive or API
transaction might touch is not decidable. The default grouping is **one constraint shard per
namespace subtree** — namespaces are already the grouping axis with inheritance semantics
(OQ-024), and a transaction spanning namespaces is already the unusual case. An explicit
`Configuration` row reassigns a constraint to another group, resolved most-specific-first.

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
Primary → Secondary1, Secondary2: proposed transaction (sequence N)
Secondary1 → Primary: ACK
Secondary2 → Primary: ACK
Primary: commit (sequence N confirmed)
Primary → Client: success
Primary (async) → Tertiaries: propagate via peer swarm
```

The primary does not wait for tertiary acknowledgment. Tertiaries are eventually consistent.

Under the batched class the primary commits and answers the client after its own append is
durable, then ships accumulated deltas to the secondaries. The steps are the same; only the wait
moves.

## Cross-Shard Transactions

There is no distributed lock. A cross-shard transaction is a **prepared node per participant
plus one commit node**, which is the graph's existing branch-and-merge shape applied at
transaction scale:

```
1. A validates against pinned graph point P_A; appends a PREPARED node (operation + P_A).
   Invisible to reads. A keeps accepting unrelated writes.
2. A sends (operation, P_A, prepared id) to B's primary.
3. B validates against its own pinned point; appends its PREPARED node; answers yes or no.
4. yes → A appends the COMMIT node; both sides become visible, B learns through the
          ordinary commit fan-out.
   no  → A appends an ABORT node; nothing was ever visible.
```

What crosses the wire is the **operation**, not a row set, and each participant validates once,
locally, against a point it pinned itself. There is no global coordinator — the coordinator is
whichever server accepted the mutation.

This replaces the cross-server lock on a `transaction_id` held until all operations complete
(OQ-027). A prepared node is not a lock: it excludes nothing, and A serializes only its own
writes, as it always did.

**Validation reads merged nodes only.** This one invariant does three jobs — it is why a
prepared node is invisible, why an unmerged schema branch does not affect the cluster, and why
an administrator's local branch is inert until uploaded. It is also what makes deadlock
unrepresentable: concurrent `A → B` and `B → A` chains cannot wait on each other's prepared
nodes, because neither can see them. The only outcome is an abort.

Prepared nodes are named by their own `DataId`, which satisfies OQ-026's prohibition on
anonymous DAG forks without a carve-out for transaction-scoped branches.

### Why Re-validation Rarely Fails

The optimism is derived rather than hoped for. An assert's query must be rooted at `self`
([schema/constraints.md](schema/constraints.md#anchoring)), so its predicate depends only on
the subject row's connected component. B's re-validation can therefore fail only if something
committed at B between the pin and the handoff that touched those same rows — which is a
genuine write conflict and has to fail regardless of how the transaction was coordinated.

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

Admission is on a condition readable off data, not off a clock: **the shard's write queue
reaches zero, or the item's age exceeds the aging threshold.** The first gives local work
precedence and lets global work resolve while a shard is quiet. The second is what prevents a
steady local stream from starving it forever — "wait for the server to be idle" alone has no
guarantee of progress on a busy server, and inactivity is a clock property besides.

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

Where an operator insists on one copy plus a dump, the honest form of that is a dump that is
content-addressed, whose checksum is recorded as a graph node, and which a scheduled event
re-reads and reports on. That makes it a replica with a slow protocol rather than a hope, and
`verify shard` can then say something true about it.

### Sunset Is Proposed, Never Automatic

The maintenance queue notices a shard that has been inactive past a `Configuration` threshold
and **proposes** sunsetting it. An operator accepts.

This is the rule that already governs materialized views ([storage.md](storage.md#views-are-proposed-not-created-silently))
and the per-field timestamp cache, applied one scope wider, and it lands on the same side of the
line as `split shard`: an operation that moves authority is not automatic, and inactivity is a
clock reading besides.

**Rolling up `UserData` history is a `retain` chain, not a command.** Collapsing a row's version
range is prunable-data semantics, and it is subject to the same rule as every other prune —
[it is only ever the consequence of a declared chain](schema/aggregates.md#pruning-is-only-ever-a-consequence).
The ordered `where` / `otherwise` branch form is what makes "these specific rows" expressible
without a manual prune. Two consequences to expect: the version chain over the pruned range is
gone, so anything derived from it — per-field timestamps most of all — reads `NotRetained`
rather than a wrong answer.

### Quarantine Needs No Mechanism

"Make this shard unreadable and unreplicated pending review" is two rows: revoke the namespace
grant, and assign the shard a range-tree entry with no serving roles. Both operations exist, and
both are reversible, which is what an operator wants in the first hour of an incident.

It is documented as a recipe rather than built as a keyword. A dedicated `quarantine` verb would
add a second way to say what grants and role assignment already say, and the two would drift.

## Geo-Diversity Goals

| Role | Target placement |
|---|---|
| Primary | Close to primary write workload |
| Secondary 1 | Different region from primary |
| Secondary 2 | Different region from both primary and Secondary 1 |
| Tertiaries | Anywhere — near read workloads or analytical clusters |

## Open Questions

- What is the failure detection mechanism? Heartbeats? Lease-based? (Affects elevation latency)
- How long can a primary be unreachable before a secondary auto-elevates vs. requiring manual intervention?
- What are the default extent size and segment grain, and is a shard group formed automatically or by an operator? (OQ-035 — the split *trigger* itself is settled above)
- How are network path hints declared and stored? (Likely a `system` shard table)
- How many parked client subscriptions should a node hold, and what is the eviction policy when
  that ceiling is reached? The latency question is settled — a parked connection is a push
  channel — but the capacity question is not.
- What is the I/O budget mechanism for analytical reads on a tertiary, and is it expressed per
  connection, per token, or per query?
