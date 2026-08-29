# Transaction Graph

The append-only DAG that holds all data and all schema. This document covers its structure,
the version references that name points within it, shards, and the identifier types. For
the physical on-disk representation see [storage.md](storage.md); for the schema syntax
that produces graph nodes see [schema/evolution.md](schema/evolution.md).

## Structure

The transaction graph is an **immutable, append-only directed acyclic graph** (a git-like
commit DAG). Each node records:

- A `DataId` — globally unique 12-byte identifier; timestamp and server identity are encoded within it
- A sequence number within its shard
- A pointer to the schema graph node that was current at commit time
- The set of mutations applied (inserts, deletes — no in-place updates)
- The re-key records annotating those mutations
  ([Re-Keying Is Recorded on the Node](#re-keying-is-recorded-on-the-node))

That is the **logical** account of a node, and it is the one to edit. The physical frame that
carries it — field order, widths, and what may be added without breaking a rolling upgrade — is
in [storage.md](storage.md#wire-format-for-replication).

**Replaying a sequence-numbered delta is idempotent**: a replica applying transaction N twice
reaches the same state. A re-submitted *client* mutation is not a replay — it mints new
`DataId`s and burns any `next` value, so it is a second transaction with a second identity.

Records are **never mutated retroactively**, with two exceptions, and both destroy rather than
revise: `scrub` overwrites one field's bytes, and retention pruning unlinks whole segments.
Neither rewrites a node. The enumeration of what may touch a written extent has one home — the
table in [storage.md](storage.md#compaction-is-lossless).

### `system.graph.Transaction`

The graph is data, so a node is a row and is read like one:

```
table system.graph.Transaction {
  shard_root  : DataId,
  tx_seq      : Int,
  schema_node : DataId,
  parent     :> ParentNode : Component { node : DataId },
  rekey      :> ReKey : Component {
    subject_table : Text,
    old_row       : Text,
    new_row       : Text,
    old_root      : DataId,
    new_root      : DataId
  },
  unique txRef { shard_root, tx_seq }
}
```

Declaring it settles three things that were being claimed without it. `show transactions` and
`show transaction` ([cli.md](cli.md)) read a table and therefore take a grant like any other
read. Nonconformance is queryable because `system.integrity.Violation` is an ordinary table
([integrity.md](integrity.md)); a transaction is queryable for the same reason and no other. And
the re-key record below has somewhere to live that a reader can reach.

Four properties, none of which is a new mechanism:

- **It declares no replication trait**, because a transaction node *is* its shard's log and
  replicates exactly as that shard does. It sits outside the replication table below for the
  same reason schema shards and constraint shards do.
- **`shard_root` holds the shard's root-row `DataId`**, so `unique txRef` reaches the shard root
  by naming it rather than by walking a foreign-key chain to it. It is a bare `DataId` and not a
  `:>` because the root's *table* varies with the family, so there is nothing single to point at
  — the degenerate case of the rooting rule, in the way a `LogSegment`'s key names the server
  that wrote it. It is `shard_root` and not `shard` because `shard` is a reserved word, the same
  reason `ExtentPolicy` spells its first column `table_path`.
- **It stores nothing new.** Every column is already in the frame; the declaration names what
  the engine holds, exactly as [Virtual Columns](#virtual-columns) name bytes already in hand.
- **It is read-only to every token.** No `Mutation` writes it, and no `bypass` grant creates
  one. `tx_seq` is assigned by the shard primary ([distribution.md](distribution.md)).

`parent` carries one node normally and two on a merge, which is why it is a component sub-table
rather than a field: a `:>` to a `Component` target is table-valued
([schema/tables.md](schema/tables.md#component-sub-tables)), so the DAG's fan-in needs no list
type.

### Re-Keying Is Recorded on the Node

A write that changes a row's **shard root** is not an update. It is a delete plus an insert, and
the successor is a different row in a different shard with a different `DataId`
([schema/queries.md](schema/queries.md#delete-appends-a-version)). The link between the two is a
property of the **transaction**, not a column on either row: a supersession is a fact about a
transaction, so a row column would store it on the wrong object, and a `DataId | NotSuperseded`
column on every row of every rooted table would pay on every row for something that almost never
happens.

**The trigger is a change of shard root, not of any placement-key field.** Changing a non-head
field of a rooted key — `Order.order_num` under `unique orderRef { customer, order_num }` — leaves
the root where it was, so no ordinal is invalidated and nothing crosses a shard; it is an ordinary
update. And **a root row's candidate-key change is not a re-key at all**: a shard is named by its
root row's `DataId` ([Shard Roots](#shard-roots)), which does not move, so a username change, an
email change or a branch rename is an ordinary update plus a shard-directory write. Without that
second clause the rule would have rejected every root candidate-key change with no escape, since
a root is *defined* by its key containing no same-family foreign key.

The `rekey` component above is that link. Five fields, and each is load-bearing:

| Field | Why it cannot be dropped |
|---|---|
| `subject_table` | A bare identifier does not name a table; the delete mutation carries only the id |
| `old_row`, `new_row` | The `head_index` key, rendered ([storage.md](storage.md#component-subtrees-are-one-range-scan)) |
| `old_root`, `new_root` | Neither participant can derive the other's: the source holds the tombstone, the destination the successor |

`old_row` and `new_row` are `Text` rather than `DataId` because a component has no `DataId` and
its identifier is variable-length ([Component Ordinals](#component-ordinals)) — and a component
reparent is precisely the case this record exists to name. What they hold is the rendered
`head_index` key: a `DataId` for an ordinary row, a `DataId` plus one `Ordinal` per nesting level
for a component row.

Four rules follow, and the first two are what make the record trustworthy rather than merely
present:

- **Equality of `old_root` and `new_root` is how a reader tells a same-shard re-key from a
  cross-shard one.** No flag, no node kind, no second shape — the same derivation
  [Shard Roots](#shard-roots) already makes.
- **The pairing is not derivable from the mutation list.** Two rows of one table re-keyed in one
  transaction cannot be matched after the fact, because the values that would disambiguate them
  are exactly the ones that changed. That is why the record is explicit, and it is a stronger
  argument than legibility.
- **The record is never load-bearing for applying a transaction.** A decoder that ignores it
  applies the delete and the insert correctly and loses only the link, which is what keeps the
  frame additively evolvable ([storage.md](storage.md#wire-format-for-replication)).
- **A bare `DataId` resolves forward through the chain.** One rule covers
  `system.events.TriggerState.subject`, `system.integrity.Violation.subject`, and an id captured
  in a queue payload; without it each dangles at a tombstone.

**The record is old→new and lives on the source shard, and every consumer starts from the
successor** — the version-chain walk, a violation's subject, a held trigger bit, merge
reconciliation. A server-local, unreplicated **new→old index derived from the nodes** is what
closes that gap. It is derived rather than authoritative, so it costs nothing in the graph and
carries the same posture as [Physical Locators](#physical-locators): the wide global fact is in
the graph, the narrow lookup is local. The physical form is in
[storage.md](storage.md#wire-format-for-replication).

The cross-shard half — both prepared nodes carrying an identical record, the commit node
carrying none, and nothing in the record that is unknown at prepare time — is in
[distribution.md](distribution.md#cross-shard-transactions).

## Schema Transaction Graph

The schema itself is stored in the same transaction graph structure, on the **branch shard** —
one shard per branch, rooted at the branch row
([distribution.md](distribution.md#schema-shards-are-rooted-at-a-branch)). Earlier text said "the
`system` shard", which is two mistakes in three words: `system` is a namespace rather than a
shard, and there is no single shard holding schema. Every schema change — adding a table, adding
a field, defining a new functor — is a commit in the schema graph. This means:

- Every data record implicitly references a schema graph node ("this data was valid under schema version X")
- The full history of schema evolution is queryable
- Rollback is reading from an earlier graph node, not undoing changes

## Branches, Tags, and Version Tokens

The transaction graph supports three kinds of named references, all of which are valid
version tokens in API paths (`/v{token}/records/...`) and in the query `at` clause:

| Token type | Moves? | Example | Resolves to |
|---|---|---|---|
| **Graph node id prefix** | Never | `05KG3N0000Z` | Itself — the node's own `DataId` |
| **Tag** | Never | `v2.1.0`, `stable-2026-q2` | The specific node the tag was attached to |
| **Branch name** | Yes (HEAD advances) | `main`, `experiment-checkout` | Current HEAD of that branch |

All three resolve at dispatch time to a schema graph node, which then selects the route set
registered at that node. The id prefix is the lowest-level escape hatch — it works even when no
tag or branch name has been declared. A prefix short enough to be ambiguous **fails with an
ambiguity error**; the resolver never picks one of two matches.

**A graph node is named by its `DataId`. A schema node additionally carries a content digest,
and the two are not competing identities.** The first row of that table said "content-addressed"
while [Globally Unique Identifiers](#globally-unique-identifiers) makes a `DataId` a timestamp, a
server id and a sequence — not a hash, not deterministic from content, and different on two
servers that compute the same node. The split that removes the contradiction without giving up
what content addressing was carrying:

| | Name | Digest |
|---|---|---|
| What it is | the node's `DataId` | 32-byte SHA-256 over the declaration the node carries |
| What it answers | *which* node | whether two nodes carry the *same term* |
| Who has one | every graph node | schema nodes |

The digest covers the declaration, not the commit metadata around it, so two branches that
declare the same predicate agree on its digest and a rename of the branch does not perturb it.
It is an equality witness, never an address — which is all the arguments resting on it ever
needed: a replay finds the term a retired binary cannot supply
([dynamic-loading.md](dynamic-loading.md)), and an audit compares a predicate against the one it
replaced ([integrity.md](integrity.md)). Naming stays with `DataId`, so routing, parent pointers,
and `DataId 'TxNode` all mean one thing.

**Branch policy**: All branches must be explicitly named. Anonymous DAG forks are not
permitted — creating a divergent commit requires naming the branch first. The `main` branch
cannot be deleted.

**Tag attachment**: Tags are rows, inserted as part of a transaction. A tag, once written, is
immutable — it permanently identifies the schema at a specific point in time. Semantic names
(`v1.2.0`, `stable`) are the expected primary UX; the id prefix exists as the canonical fallback.

**Version ref storage**: a branch and a tag are separate tables under `system.schema`, which is
where [namespaces.md](namespaces.md) already places branches and tags:

```
table system.schema.Branch {
  name : Text unique,
  head : DataId
}

table system.schema.Tag {
  name : Text unique,
  node : DataId
}
```

Neither declares a replication trait. Both are schema, so their rows live on the branch shard
with every other schema node
([distribution.md](distribution.md#schema-shards-are-rooted-at-a-branch)); a `Branch` row is
additionally that shard's root, which is what makes "all branches must be named" load-bearing
rather than a policy.

**A branch name and a tag name may not collide**, or `at "v2.1.0"` has two answers. The check is
cluster-wide over the two `name` columns and is served by a constraint shard like any other
cluster-scoped uniqueness ([distribution.md](distribution.md#constraint-shards)).

**Immutability and deletion are table properties, not functors.** A `Tag` row is never updated
and the `main` `Branch` row is never deleted. Neither rule can be a validation functor: kind 1
receives the new field value and kind 3 the row being written
([schema/functors.md](schema/functors.md)), so neither sees the *previous* version, and no kind
is reached on a delete at all. Both are engine-enforced properties of the table, the same
category as `LogData` append-only. The earlier text attributed them to "a validation functor",
which would have been implemented as written.

**What this replaces.** Branches and tags shared one table, `system.VersionRef`, carrying a
`VersionRef` ADT so the mutability difference lived in the type and no discriminator column was
needed. That is a good instinct and it lost to three things:

- `ref : VersionRef` does not compile. The table was `system.VersionRef`, so within `system` the
  short name resolved to the table, and `:` may not name a table
  ([schema/railroad.md](schema/railroad.md#fields)).
- **`release` was undecidable for `name`.** A value that is a root table's placement key is
  reserved permanently and any other value is releasable
  ([distribution.md](distribution.md#a-reserved-value-is-released-only-deliberately)); `name` was
  both, depending on a sibling column's variant.
- **Half the rows rooted a shard and half did not**, with the difference carried in `ref` rather
  than in the key — which is exactly what "the key declaration is the sharding declaration"
  ([Shard Roots](#shard-roots)) forbids.

**The ADT goes with the shared table**, because with two tables the table *is* the discriminator
and the type has no job left. Reintroducing `Branch` and `Tag` as variant names would also
collide with the two table names, which is the defect that started this. A version token resolves
by the table it is found in: a `Branch` name, else a `Tag` name, else a `DataId` prefix.

**Creating and merging branches**: A new branch forks from an existing node and accumulates
commits independently. When a branch is merged back, the merge commit records **two parent
pointers** — one to the prior HEAD on the target branch and one to the tip of the incoming
branch. The DAG permanently shows both lineages; there is no rebase and no history
rewriting.

**Squash merge is rejected.** The motivation is real — a local admin branch accumulates schema
nodes nobody will ever need individually, and they should be reclaimable — but three things stop
a squash from being how:

- **It makes the source branch look orphaned.** Under a squash the branch is not a parent of
  anything on `main`, so the rule below stops protecting it, and deleting the branch is the idiom
  that follows a squash everywhere else. That is history destruction arriving by convention.
- **The second parent is load-bearing.** Merge reconciliation identifies "the same" row across
  branches by candidate key ([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)),
  and the audit property is that the DAG shows both lineages. Collapse the second parent and
  nobody can say which branch asserted a value.
- **Replay needs intermediate predicates.** `enforce forward` compares against the predicate *as
  it was* ([integrity.md](integrity.md)), and a squash discards those.

The third reason supplies the discriminator that makes reclamation safe without relaxing any
rule:

> **A schema node is discardable exactly when no row was ever committed under it.**

On a local branch none ever was, by construction — a local branch holds the schema graph plus
`Reference` rows and no user data ([distribution.md](distribution.md#local-branches)). So the
mechanism is **pruning, not squashing**: a merged branch's exclusive schema nodes become prunable
once nothing references them. That is the same refcount `prune` already needs, it keeps the merge
two-parented, and it rewrites nothing. General graph reclamation — the traversal, the refcount
representation, and the operator surface — is deliberately scheduled after the things being
counted are stable.

**Conflict detection and resolution are not designed.** Earlier text here described them as
"defining a functor that reconciles the divergent schemas", and that names a mechanism which does
not exist. Three gaps in one paragraph, recorded so the next pass starts from them rather than
from the claim:

- Each of the four functor kinds *enforces* something
  ([schema/functors.md](schema/functors.md)). A reconciliation is a migration, so the test that
  excludes `Behavior` as a fifth kind excludes it too.
- There is no syntax. `resolve conflict … using merge` is a connector command
  ([schema/railroad.md](schema/railroad.md#administration)), and no `EvolutionStmt` covers a
  branch merge.
- What *counts* as a conflict — between two branches' schema nodes, or two branches' writes to
  one row — is nowhere stated, so "the common case" has no denotation.

What survives from the intent, and is worth keeping: a resolution is a schema act and belongs in
the graph as a node. [schema/evolution.md](schema/evolution.md) already settles that a merge is a
join and a split is a set of projections, so an ordinary `Binding` is the likely shape and the
derived-key rules would check losslessness for free.

**Orphaned branches**: A branch is orphaned when it has never been merged to `main` (or any
branch that has been merged to `main`) and its continued development has been abandoned.
An orphaned branch and all nodes exclusive to it may be deleted, and this is the only place an
operator deletes graph nodes **directly**. Everything else that removes a node is the consequence
of a declared policy — retention pruning, and the reclamation of a merged branch's exclusive
nodes above. A branch with any path to `main` (via merge) cannot be deleted.

**No-version routing**: Requests without a version token are routed to `main` HEAD by
default. The server can also split unversioned traffic across named branches at a
configurable rate for A/B testing; routing decisions persist via session affinity so the
same client consistently receives the same branch. This makes local and A/B testing
seamless without requiring clients to specify a version.

**Promoting a version**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever
tag or branch name the operator has promoted. The `/versions` discovery endpoint lists all
live version tokens and marks the promoted one. Operators use this to signal "use this tag
going forward" without requiring client code changes. Promotion state is stored in a system
table and is itself versioned.

## Data Shards

A shard is a named slice of the schema containing related tables, identified by the `DataId` of
its root row. Two questions run together easily and are answered separately:

> **The replication trait says how a table's rows propagate. The candidate key says which shard
> they land in.** Neither implies the other.

Four replication traits (see [schema/traits.md](schema/traits.md#replication-traits)):

| Trait | Description | Cardinality | Replication |
|---|---|---|---|
| `Reference` | Code tables; treated as code, propagated everywhere | Low-medium | Branch shard, and from there every server |
| `Configuration` | Tuning tables managed by operators | Medium | All servers |
| `UserData` | Scales with user count | High | Three role holders; shard-local |
| `LogData` | Massive cardinality; prunable | Very high | Three role holders; each server authors its own segments; batched durability |

`Component` is **not** on that list. It is a marker trait: a component's rows live wherever its
parent's do, which is what rooted placement already means, so the row's replication answer comes
from the replication trait declared beside it. `table app.commerce.OrderTag : UserData, Component`
is legal. See [schema/traits.md](schema/traits.md#component).

**Which traits root a shard, and which do not:**

| Trait | Rooted at | Writes serialized by |
|---|---|---|
| `UserData` | a root row of the family, chosen by the candidate key ([Shard Roots](#shard-roots)) | that shard's primary |
| `LogData` | a `system.shards.LogSegment` row ([`LogData` Shard Roots](#logdata-shard-roots)) | the authoring server |
| `Reference` | nothing of its own — a `Reference` row *is* schema, so it lives on the branch shard | the branch primary |
| `Configuration` | nothing of its own — see below | not settled |

The key-declaration-is-the-sharding-declaration rule therefore scopes to `UserData`. Everything
outside it is rooted by an arrangement stated somewhere, and the list is short: schema shards
(rooted at a branch row), constraint shards (rooted at the constraint's schema-node row),
`LogData` segments, and components (rooted through their parent).

**`Configuration` rows do not root a shard, and where they live is not settled.** They replicate
to every server and must survive a merge, so they are neither branch-versioned like `Reference`
nor shard-local like `UserData`. That is a real gap rather than a detail:
`system.shards.ExtentPolicy`, `system.shards.Node`, `system.shards.DurabilityPolicy` and the
range tree are all `Configuration` and all load-bearing for routing, so "which shard holds them,
and who serializes writes to them" has to be answerable. It is the same shape as the cluster
shard directory's gap under [Shard Roots](#shard-roots): cluster-scoped authority with no
declared root.

**`system` is a namespace, not a replication class.** It was previously listed as a fifth
shard type here, which does not survive contact with the tables in it:
`system.integrity.Violation` and every queue under `system.events` carry `LogData`, and
`system.logs` is per-server and prunable ([namespaces.md](namespaces.md)). A table in the
`system` namespace carries whichever replication trait fits it, exactly as an `app` table
does. The namespace says whose a table is and who may see it; the trait says how it
propagates. Neither implies the other.

**What is server-local about `LogData` is authorship, not replication.** Each server authors its
own segments, and each segment shard still has the ordinary three role holders. Log volume is
what makes two synchronous round trips unaffordable, and the **batched** durability class is what
answers it: the primary commits when its own append is durable and ships accumulated deltas
afterwards ([distribution.md](distribution.md#two-durability-classes)).

This replaces "server-local by default: each server does not replicate its log data to peers",
which was the older reading and cannot be reconciled with the newer one — with no peer copy there
is nothing for a batched class to batch, and losing a server would lose the
`system.integrity.Violation` evidence the audit trail exists to hold. Where cheapness still
matters, the relaxation is **geographic rather than role count**: `system.logs.HttpRequest` may
place its secondaries in the same region or the same rack, which is the shape cold shards already
use — three role holders always, and a dump is not one of them
([distribution.md](distribution.md#cold-shards), [api.md](api.md)).

As data volume crosses configurable thresholds, a shard splits. The split is recorded as a
special node in the transaction graph so the history of which data lived in which shard is
always recoverable. The replication mechanics of a split are in
[distribution.md](distribution.md).

Two shards sit outside both tables above because they hold authority rather than a class of
rows. Both are ordinary shards with an ordinary root row:

| Shard | Rooted at | Holds |
|---|---|---|
| **Schema shard** | a `system.schema.Branch` row, one shard per branch | schema nodes and the branch's `Reference` rows |
| **Constraint shard** | a table-wide `unique`'s schema-node row | that constraint's cluster-wide value index and its `next` counter |

The schema shard is where the "schema is data" principle stops being a slogan: schema commits
are serialized by a branch's primary the same way row writes are serialized by a data shard's
primary, and a branch is therefore the unit of schema authority. See
[distribution.md](distribution.md#schema-shards-are-rooted-at-a-branch).

### Shard Roots

A shard is rooted at a **row**, not at a table. `DataId 'Shard` is defined above as the
`DataId 'Row` of the shard's root row, and `shardOf` is partial for exactly that reason — it
returns `Just` only for a root row. **A shard family is named by its root table's namespace** —
`app.commerce` is the family whose root is `app.commerce.Customer`, and it designates which
tables participate. The concrete shards within it are one per root row. Earlier text wrote these
names as `user.*`, which named no namespace in [namespaces.md](namespaces.md) and read as a third
naming space beside the namespace tree and the replication traits.

This is what makes `UserData` mean what its cardinality column says. Each `Customer` row roots
a shard holding that customer's orders, lines, and addresses; a split redistributes customers
across servers, which is why `split shard … at key` takes a key (see
[schema/railroad.md](schema/railroad.md#administration)).

**Which table roots a shard is declared by its candidate key, not by a separate keyword.** A
`UserData` table whose key contains no foreign key to another table in the same family is a
root; one whose key does contain such a foreign key is a dependent, rooted transitively
through it. Since keys are mandatory
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) and must reach the root,
one declaration does both jobs, and it cannot drift out of agreement with itself — adding a
foreign key to a table changes nothing unless it is put in the key.

The asymmetry that follows is worth stating, because it inverts the obvious expectation:

| | Root table's key | Every other key in the shard |
|---|---|---|
| Scope | Cluster-wide | Within the one shard |
| Index | *is* the cluster shard directory (`username → DataId → shard`), which routes a request to the right server | none — the shard primary linearizes its own writes |
| Cost of a check | one constraint-shard participant | none |

So the one key that must be globally unique is also the one the system already needs a global
index for. That is the property worth keeping, and it is what makes login a directory lookup
rather than a scan ([auth.md](auth.md)).

**The directory is not free, and earlier text said it was.** A root table's key is cluster-scoped
by exactly the definition that sends a table-wide `unique` to a shard of its own, so it is served
the same way: a constraint shard rooted at the constraint's schema-node row, holding digests,
splittable by digest range ([distribution.md](distribution.md#constraint-shards)). Inserting a
root row is therefore an ordinary two-participant transaction — a prepared node in each shard and
one commit node, not a lock (see OQ-027). The cost is one participant on root-row insert and
nothing at all on every other write, which is a good trade stated plainly and a false claim stated
as "none extra".

A **table-wide `unique`** differs from a root key in scope of *membership*, not in mechanism: it
constrains every row of the table rather than every root of the family, and it is not a candidate
key.

`Component` is the degenerate case of the same rule: the parent supplies placement and the
`Ordinal` supplies uniqueness within it, which is why a component table needs no declared key.
It may still declare one — a `unique` on a component is checked within the parent, so it costs
one shard-local check ([schema/tables.md](schema/tables.md#what-is-exempt-and-why)).

### Placement Keys Are Not Identity Keys

A candidate key answers *which row is this*. Placement answers *where does it go*, and needs
strictly less — a **total order over the rows of the shard family**. The two jobs read as one
while `UserData` was the only case considered, because there the root's candidate key happens
to serve both.

> **A placement key needs only a total order. `DataId` is always one.**

`DataId` is deliberately excluded from satisfying the candidate-key rule
([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) — counting the surrogate
would make that rule vacuous. It is nonetheless monotone, total, and present on every row, so
it is a perfectly good placement key. The consequence is worth stating plainly:

> **Every shard can be split, always.** A declared partition space chooses *where* the cut
> falls; it never decides *whether* a cut is possible.

| Shard family | Placement order | Cut point |
|---|---|---|
| `UserData` root | the root table's candidate key | key range |
| `UserData` dependent | inherited from its root through the FK chain | none — it follows its root |
| `LogData` | the retention time source (`created_at`, or `using`) | segment boundary |
| anything, last resort | `DataId` | any row boundary |

Cutting at a `DataId` boundary never splits a component subtree, because every descendant
shares the parent's byte prefix (see [Component Ordinals](#component-ordinals)). A
row-boundary cut is a prefix-boundary cut.

### `LogData` Shard Roots

`LogData` declares no candidate key, so it has no root key to partition on. The root is
supplied instead:

```
table system.shards.LogSegment : LogData {
  period_start  : Timestamp,
  retain_node   : DataId,
  retain_branch : Int,
  unique segmentRef { origin_server, period_start, retain_node, retain_branch }
}
```

`origin_server` is declared nowhere because it is a **virtual column** — bytes 6–7 of the
segment row's own `DataId`, typed `:> system.shards.Node` ([Virtual
Columns](#virtual-columns)). A segment is written by the server that owns it, so those bytes
*are* the answer; a declared field would have been a stored copy of them, free to disagree.
This is the general rule, and the key is where it earns out.

`system.shards.Node` is the server registry `show servers` reads — `Configuration`, one row per
registered server, carrying the 2-byte node id assigned at registration (see
[Globally Unique Identifiers](#globally-unique-identifiers)).

`period_start` *is* declared, and the asymmetry is the point: `segment_grain` is a
`Configuration` value that may be retuned, and routing is decided when a row is written and
never revised. A truncation under a mutable policy has to be pinned at write time or an
operator changing `segment_grain` would retroactively re-route sealed segments. Bytes 6–7
cannot be retuned, so `origin_server` needs no pinning.

**Which column `period_start` truncates depends on the chain.** By default it is `created_at`,
which is bytes 0–5 of the row's own `DataId`. Where the table declares `retain … using
<column>`, the segment is cut on **that** column, because the chain expires on it
([schema/aggregates.md](schema/aggregates.md#time-source)) and a segment cut on a different
clock would hold rows with a year's worth of expiries — the failure a back-filled connector
import produces on its first afternoon. The `using` column is stored, so `period_start` is
truncated from it and pinned at write time exactly as it is in the default case.

One row per (server, bucket, retention policy version, branch); each roots the shard holding
that segment's log rows. `LogData` exempts a table from *needing* a key and does not forbid one
— the same point that lets a rollup level declare one
([schema/aggregates.md](schema/aggregates.md#what-gets-generated)). The root row lives in the
segment it roots and is pruned with it, exactly as a `Customer` row lives in the shard it
roots.

That last sentence is an exception to "a `LogData` table with no `retain` statement is never
pruned at all" ([schema/aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence)),
and it is stated here because it is a property of rooting rather than of retention: **a segment
root row is governed by the chain of the table whose rows the segment holds**, not by a chain on
`system.shards.LogSegment`. Pruning the last retention step covering a segment unlinks the
segment and its root together. A `LogData` table with no chain therefore accumulates segments
that are never unlinked, which is what "silence means keep" costs.

Four properties earn the shape:

- **The log table stays keyless and the family still has a key.** A log row is an occurrence
  with no identity beyond its occurrence; a segment is an entity and has one. The
  root-key-is-the-shard-directory invariant above is restored without weakening the exemption.
- **Routing costs zero stored bytes under the default time source.** A log row's server is
  bytes 6–7 of its own `DataId` and its bucket is bytes 0–5 truncated — so a row's segment is
  computed from the identifier it already carries, with no lookup and no stored parent reference.
  Under `retain … using <column>` the bucket comes from that stored column instead, so the
  routing read is one field rather than zero bytes; everything else about the shape is unchanged.
  `origin_server` is a foreign key to a `Configuration` table, which does not participate in
  placement rooting ([schema/tables.md](schema/tables.md#keys-must-be-rooted)), so `LogSegment`
  is a root rather than a dependent; and because the key contains the server id, its cluster-wide
  uniqueness holds with no cluster-wide index.
- **Locality where it is used.** The identifier is time-major then server, so a segment is a
  strided set globally but a *contiguous range* on the server that wrote it — the server that
  authored it and the one that scans it ([distribution.md](distribution.md)). Secondaries hold
  the segment for durability rather than for querying.
- **Retention aligns to segments.** A closed segment is a whole retention unit, which turns
  pruning into an unlink rather than a row scan (below).

`segment_grain` is a `Configuration` value, not syntax — `Day` by default. It has to be
tunable, because a retention chain whose raw step is shorter than the segment grain would not
align, and because a low-volume server should not accumulate a million near-empty segments.

`retain_branch` is the index of the matching `retain` branch, or `0` where the table has no
`retain` statement or an unbranched one. It belongs in the key because branch predicates may
reference only the rollup's group keys and the time source
([schema/aggregates.md](schema/aggregates.md#branches)), so the branch is decidable when the
row is written. Without it a segment could hold rows with two different expiries and would not
be prunable as a unit. The column is `retain_branch` and not `branch` because a DAG branch is
the other thing that word means in this document, and a shard-root table is the worst place to
make a reader guess.

`retain_node` is the `DataId` of the `retain` declaration under which the row was routed, and it
is in the key for the same pin-at-write-time reason `period_start` is. **An index is only
meaningful against the version of the ordered block it indexes.** Branches are ordered so a rule
can be inserted ahead of a catch-all ([schema/aggregates.md](schema/aggregates.md#branches)),
and `retain` is an ordinary schema object, versioned in the graph — so that insertion renumbers
every later branch. Without `retain_node`, an open segment routed under old index 2 and rows
routed under new index 2 share one key inside the same bucket, and the segment holds two
retentions. With it, editing or reordering branches mints a new schema node and therefore a new
segment, so a sealed segment keeps the retention it was routed under. That is the forward-only
rule the rest of retention already follows.

The current segment accepts writes; when its bucket closes it is **sealed** and a new one
starts. Sealing moves no data, which is why it can be automatic where a `UserData` split
cannot ([distribution.md](distribution.md#shard-splits)).

### Extents Are Not Shards

A **shard** is a unit of authority: one primary, two secondaries, one sequence space. An
**extent** is a unit of storage: a run of the append-only log on one server, sized from
`system.shards.ExtentPolicy`. A shard is made of extents. The distinction is load-bearing, and
the `PhysicalLocator` already draws it:

| Move | What changes | Cost |
|---|---|---|
| A row moves between extents of its own shard | the `log_index` *value* (`offset`, `length`) | Nothing — see [storage.md](storage.md#relocation-rewrites-offsets-not-locators) |
| A row moves to another shard | `plShard`, hence the locator, hence `head_index` | A logical event, recorded as a split node |

The byte offset lives in the *value* of `log_index` and not in the locator, which is what makes
the first row of that table free. That is why background repartitioning can run continuously and
automatically: below the shard boundary it is invisible to the graph and to every other server,
exactly like the compaction it shares a queue with.

The word is **extent** rather than *page* because LMDB has pages of its own, at a lower level
and a different size.

Sizing is a `Configuration` row, not syntax and not a trait parameter
([schema/traits.md](schema/traits.md#traits-are-not-configuration)):

```
table system.shards.ExtentPolicy : Configuration {
  table_path  : Text unique,        -- default for every server
  extent_size : Int,                -- unit is OQ-035
  segment_grain : Grain = Day       -- LogData segment grain; ignored otherwise
}

table system.shards.ExtentOverride : Configuration {
  table_path  : Text,
  server     :> system.shards.Node,
  extent_size : Int,
  segment_grain : Grain,
  unique overrideRef { table_path, server }
}
```

Two tables rather than one keyed by `{ table_path, server }` with an "all servers" variant,
because a `Null`-derived variant in a key is rejected
([schema/tables.md](schema/tables.md#ineligible-key-fields)). Resolution is
most-specific-first. `table_path` rather than `table`, which is a reserved word — the same
reason `system.integrity.Violation` spells it `subject_table`.

`segment_grain` is a `Grain` rather than a `Duration`, so a segment may seal on a calendar
boundary — `Month` closes at month ends of unequal length, which a millisecond interval cannot
express. Sealing still moves no data, so it stays automatic.

OQ-035's requirement that the segment grain align with the retention grains in use is **two
checks, not one**, because a chain's steps are not all grains:

| Chain element | Check |
|---|---|
| Any step or terminal carrying `by` | The segment grain is an alignment ancestor-or-equal of the finest grain in the chain — an edge check over the declared forest ([schema/aggregates.md](schema/aggregates.md#grain-order)) |
| The raw first step, which carries no `by` | The segment grain's maximum span must not exceed the raw step's retention length — an arithmetic comparison against a `Duration` |

The second is the case that motivated the requirement: `for 6 hour` under a `Day` segment cannot
prune by segment, and there is no alignment edge between `Day` and `6 hour` because `6 hour` is
a length rather than a grain ([schema/railroad.md](schema/railroad.md#retention)). Comparing
against the grain's **maximum** span keeps the check conservative in the same way the
successor-coverage rule already is.

### Splitting a Shard With One Root Row

The partition function ranges over root rows, so a shard whose root set is a single row — one
customer with a hundred million orders — has nothing to cut on. It splits by descending the
placement chain to `DataId`, as any shard can. What that cannot do is move authority:

> **The extents of one shard may spread across disks and volumes freely. Across *servers* only
> if they share a primary.**

The sub-shards therefore form a **shard group** sharing one primary, and `LogData` needs no
group at all. Which invariants force that, and what the group costs, are in
[distribution.md](distribution.md#shard-splits) — splitting and write authority are its
subject, and it also owns the range-tree definition of a group.

## Pruning

`LogData` shards and old materialized views may be pruned. Pruning is recorded in the
transaction graph as a special node, so the system always knows that historical data before a
certain point has been discarded.

What the graph owns here is the **prune node** and the shape of its append. When a retention
policy expires data, the rollup rows are written by one transaction and the prune node covering
the source range by another — the transaction being summarized is never edited to hold the
summary in place of its rows. That is not a convention: a transaction node is immutable, and
rewriting one is the history mutation this whole structure exists to prevent. What stays
readable is "these rows existed, then were summarized, then were discarded, and when."

Because a `LogData` shard is rooted at a segment whose key carries the retention policy and
branch it was routed under, an expiring step usually covers a **whole sealed segment**, so the
prune node is accompanied by an unlink of that segment's extents rather than a row scan.
Row-level pruning is the fallback wherever an expiring step does not cover a whole segment — a
segment cut coarser than the step being expired, which is the case the segment-grain alignment
check above exists to keep rare.

The policy those nodes serve is not stated here. When pruning happens, why it is never a manual
act, what a `LogData` table with no chain gets, and why a rollup level is an ordinary table
rather than a materialized view are all in
[schema/aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence) and
[schema/aggregates.md](schema/aggregates.md#a-rollup-is-two-appends-not-a-rewrite).

## Globally Unique Identifiers

Both transaction graph nodes and logical rows use a unified 12-byte `DataId`:

```
Bytes 0–5:  Unix timestamp in milliseconds (big-endian, 6 bytes) — valid through year ~10 890
Bytes 6–7:  Server node ID                 (big-endian, 2 bytes) — up to 65 535 servers
Bytes 8–11: Sequence counter               (big-endian, 4 bytes) — up to ~4.29 billion per server per millisecond
────────────────────────────────────────────────────────────────────────────────────────
Total: 12 bytes
```

- **Timestamp**: Unix epoch milliseconds. 2^48 ms ≈ 8 925 years from the epoch.
- **Server node ID**: assigned sequentially at server registration; coordination is required only at registration time, not at ID generation time.
- **Sequence**: monotonically increasing counter per `(server, millisecond)`, reset each millisecond. 4 bytes = 2^32 ≈ 4.29 billion increments per millisecond per server, or ~4.3 × 10^12/second.

Big-endian encoding means lexicographic order approximates chronological order — now at
millisecond rather than second granularity — which benefits LMDB range scans. `DataId` is
globally unique without per-ID coordination.

`DataId` is the primary key type for all DataCode-native tables and the identity of
transaction graph nodes.

### Clock Regression

Millisecond resolution makes the generator sensitive to wall-clock steps. An NTP correction
that moves the clock backwards would otherwise let a server re-issue a `(timestamp, server,
sequence)` triple it has already used, breaking the uniqueness guarantee above.

**The generator clamps.** It retains the last timestamp it emitted and never emits a lower
one; if the wall clock regresses, the timestamp is held at the last emitted value and the
sequence counter continues from where it was. With 4.29 billion sequence values per
millisecond there is ample room to absorb a regression of any realistic magnitude, so no
stall and no coordination is required. The generator emits an operational warning when it is
clamping, because a persistently regressing clock is a host problem.

**The high-water mark is persisted, or the hole reopens at every restart.** Clamping against
in-memory state closes the NTP step only while the process lives, and a host with a bad clock is
a host that gets restarted — after which the generator reads a lower wall clock, remembers
nothing, and re-issues triples it already used. Since `DataId` is row identity, a duplicate is
two rows that are the same row. Three rules make it bounded:

- **Startup begins at `max(wall clock, persisted high water)`.** The mark lives beside the LMDB
  environment, not in the log, so recovering it never depends on replaying what it protects.
- **The mark is written ahead, not per id.** It is fsynced one lease interval beyond the current
  clock and refreshed once per interval, so the cost is one small write per interval rather than
  one per identifier, and a crash loses at most the unused remainder of a lease.
- **A missing mark refuses the start.** Trusting the clock instead is exactly the case the
  section exists to prevent. Generation-swap topologies put a new process on the same node id
  routinely ([dynamic-loading.md](dynamic-loading.md)), so restart is the common path rather than
  the exceptional one.

### Identifier Roles

The same 12 bytes are used in three roles. They share one encoding, one generator, and one
sort order, and are distinguished by a phantom type parameter rather than by three separate
newtypes:

```haskell
data IdRole = TxNode | Row | Shard

newtype DataId (r :: IdRole) = DataId ByteString   -- always 12 bytes
```

| Role | What it identifies |
|---|---|
| `DataId 'TxNode` | a transaction graph node |
| `DataId 'Row` | a logical row, stable for the row's whole lifetime |
| `DataId 'Shard` | a shard — **this is the `DataId 'Row` of the shard's root row** |

The role is `TxNode` and not `Tx` because the effect ladder's write rung is also `Tx`
([schema/functions.md](schema/functions.md)), and the design deliberately promotes `IdRole` into
type signatures — so the two would meet as `'Tx` in adjacent arguments of one function. `TxNode`
is also what the wire format calls the frame ([storage.md](storage.md#wire-format-for-replication)).

The roles cost nothing at runtime and are erased on the wire. They exist so that a shard
identifier cannot be passed where a row identifier is expected. Because a shard is named by
its root row, the coercion is one-directional and partial:

```haskell
shardOf :: DataId 'Row -> Maybe (DataId 'Shard)   -- Just only for a shard root row
```

**`shardOf` is not the routing primitive, and it is not free.** It answers "is this row a shard
root, and if so which shard does it name" — a predicate. What a request asks is the other
question, and it needs its own signature:

```haskell
shardContaining :: DataId 'Row -> Read (DataId 'Shard)   -- total
```

`shardContaining` consults the shard directory ([Shard Roots](#shard-roots)) and is total: every
row is in some shard. Both are lookups rather than casts — deciding whether an id is a root
requires reading the directory — so neither should be costed as a coercion merely because the
phantom role makes it read like one. For a component identifier there is no `DataId` of its own;
the answer is the shard of the parent whose prefix it carries.

In the schema DSL the type is written `DataId` with no role — the role is inferred from
position. See [schema/types.md](schema/types.md).

### Rendering

A `DataId` renders as 20 characters of Crockford base32 (upper case, no padding), which is
what appears in CLI output, API paths, and the IDE:

```
05KG3N0000ZQ8V4T1H7C
```

Base32 was chosen over hex because it is shorter, and over base64 because it is
case-insensitive and free of characters that require escaping in a URL path segment.
Lexicographic order over the rendered form matches lexicographic order over the bytes, so
sorting rendered ids sorts them chronologically.

## Component Ordinals

Rows of a table carrying the `Component` trait do not get their own `DataId`. They are
identified **relative to their parent** by a 4-byte `Ordinal`:

```
<parent DataId> . <Ordinal>          -- 12 bytes + 4 bytes, logically
<Ordinal>                            -- 4 bytes, physically stored
```

Only the `Ordinal` is stored. The timestamp, server node, and sequence are inherited from
the parent through the containment link, which is also the reason the parent reference costs
no bytes at all — the parent *is* the identifier prefix.

Ordinals are assigned per parent, monotonically, starting at 1, and are never reused. The
assignment is a read-modify-write against a **4-byte high-water mark on the parent row**, not a
scan of live children — under "never reused" the live maximum is the wrong number after any
delete, and there is no index that would make finding the all-versions maximum cheap. It is safe
without coordination because a component always lives in its parent's shard and the shard
primary linearizes writes. A component therefore never crosses a shard on its own, and this is
what makes the whole scheme sound rather than merely compact.

Two consequences worth pricing rather than hiding:

- **Allocation is a serialization point on the parent.** It is coordination-free, but two writes
  under one parent still order against each other, where a `DataId` needs no coordination at all.
  Bounded children — order lines, request headers, document nodes — do not notice; a component
  directly under a shard root with unbounded cardinality does. Schema commit prices it exactly as
  it prices a table-wide `next` ([schema/tables.md](schema/tables.md#sequences)): the same
  diagnostic, naming the serialization it introduces.
- **"Never reused" is a claim about author-written component tables.** A shredded document tree
  is a materialized view, rebuildable and droppable ([storage.md](storage.md#shredded-documents)),
  and its nodes take their ordinals from position in the source bytes rather than from the
  counter — so a rebuild is idempotent and an array node's children *are* its ordinals
  ([schema/documents.md](schema/documents.md)). Without that carve-out the two rules collide:
  allocating from the counter makes a rebuilt tree start at N+1 and array indexing meaningless,
  while restarting at 1 reuses ordinals.

**A re-key preserves ordinals; it does not reassign them.** When a row moves shard root
([Re-Keying Is Recorded on the Node](#re-keying-is-recorded-on-the-node)), its whole component
subtree moves with it by prefix substitution, which is what makes one key pair in the record
enough to name the subtree. Allocation on the successor seeds from the copied high-water mark,
importing the predecessor's gaps. Reassigning instead would renumber every array element in every
indexed document field — an array element's identity *is* its ordinal — and would need
O(subtree) bytes of mapping on the node.

**Reparenting is permitted only within the same shard root.** The record can name a component
reparent, because its row keys are `head_index` keys rather than `DataId`s, but moving a subtree
to a parent under a *different* root would cross a shard, which is the thing the ordinal scheme
cannot survive. So "a component cannot be reparented" is not a separate invariant to remember —
it is a prohibition on crossing, re-derived from where the ordinal is allocated.

Nesting appends another ordinal per level, so a component identifier is variable-length. That
is not a problem for LMDB, which sorts keys as bytes, and it buys a property the rest of the
design leans on heavily: **a parent's entire component subtree is one contiguous range
scan**, because every descendant shares the parent's byte prefix.

Rendered form is the base32 parent id followed by dot-separated decimal ordinals:

```
05KG3N0000ZQ8V4T1H7C.7
05KG3N0000ZQ8V4T1H7C.7.2
```

See [schema/traits.md](schema/traits.md) for the `Component` trait and the invariants it
enforces, and [schema/documents.md](schema/documents.md) for its principal use.

## Physical Locators

`DataId` names a row. It does not say where any particular *version* of that row lives. That
is the job of the **`PhysicalLocator`** — a composite address into the append-only log:

```haskell
data TxPosition = TxPosition
  { plTxSeq  :: Word64      -- monotonic tx sequence within shard (8 bytes)
  , plRowPos :: Word16      -- row position within transaction (2 bytes)
  }

data PhysicalLocator = PhysicalLocator
  { plShard  :: ShardIndex  -- server-local shard index (4 bytes)
  , plPos    :: TxPosition
  }
-- Encoded as 14 bytes, big-endian throughout
```

**The split is what makes "never replicated" true.** The two halves have opposite scopes and
were one type until this pass, which made the claim below contradict itself three ways:
`plTxSeq` is assigned by the shard primary and applied in order by every replica
([distribution.md](distribution.md#transaction-propagation)), so it is replicated by definition;
`plRowPos` must be identical on every replica or `verify shard`'s cross-replica comparison
compares different rows; and the `TxNode` frame carries a locator while the frame *is* the wire
format, so a `ShardIndex` travelled in a replication message against the [`ShardIndex`](#shardindex)
rule below.

| | Scope | Crosses the wire |
|---|---|---|
| `TxPosition` | the shard | yes — it is what the frame carries |
| `ShardIndex` | one server | never |
| `PhysicalLocator` | one server | never — each server composes its own |

Big-endian encoding is critical: LMDB sorts keys lexicographically, and big-endian integer
encoding makes `lexicographic order == numeric order`. This means "all rows written by
transaction 42 in shard 1" is a single contiguous LMDB range scan with no scatter-gather.

Transaction nodes themselves use `plRowPos = 0` by convention
(`txNodeLocator shard txSeq = PhysicalLocator shard (TxPosition txSeq 0)`). Rows within a
transaction occupy positions 1 through N, which puts a hard rule on the write path:

> **A transaction contains at most 65 535 row mutations.** `plRowPos` is two bytes and position
> 0 is the node itself.

That is a rule an author and an implementer both have to observe, not an encoding detail — a
bulk or cluster-wide mutation applies per shard, and a per-shard application exceeding the cap is
split into a sequence of transactions, each independently validated and recorded. Per-shard
application is therefore restartable but **not atomic**, which is the honest reading and is
already the shape [distribution.md](distribution.md#bulk-and-cluster-wide-mutations) gives bulk
mutations.

**Two-tier identifier model:**

- **Logical, user-visible**: `DataId`. Stable across mutations — the same `DataId` for the row's whole lifetime. 12 bytes, globally unique, replicated as-is.
- **Physical, internal**: `PhysicalLocator`. Changes on every mutation, pointing at one specific version in the log. Never exposed in the schema DSL and never replicated — each server composes its own from a replicated `TxPosition` and its own `ShardIndex`.

The LMDB `head_index` bridges the two: `DataId → current PhysicalLocator`. Following up
through `log_index` yields the location on disk. See [storage.md](storage.md).

**Relocation is not a version**, and that is why `plShard` sits *inside* the locator while the
byte offset does not: that placement is what separates a free move from a recorded one. What
relocation touches and what it leaves alone is in
[storage.md](storage.md#relocation-rewrites-offsets-not-locators).

**Sort order confirmed by spike** (`spikes/storage/output.txt`): ByteString lexicographic
sort of encoded locators produces the same ordering as Haskell's derived `Ord` instance.

### `ShardIndex`

`plShard` is a `Word32`, not a `DataId 'Shard`. Shards are named globally by their root row's
12-byte `DataId`, but embedding that in every LMDB key would take the key from 14 bytes to
22 for no gain — a locator is only ever meaningful on the server that computed it, and that
server knows its own shards.

`ShardIndex` is therefore a **server-local interning** of `DataId 'Shard`. The general rule,
which applies beyond this case:

> Logical identifiers are wide and global. Physical identifiers are narrow and local.

A `ShardIndex` must never appear in a replication message, an API response, or an error
string. Two servers may legitimately assign different indexes to the same shard.

**The interning table is not a table.** It sits below the table layer as LMDB-side state
alongside `head_index` and `log_index` ([storage.md](storage.md#two-complementary-structures-per-shard)),
and it is not queryable. Earlier text named it `system.shards.Index`, which no replication trait
can carry: `Configuration` and `Reference` reach every server and would collide two servers'
indexes — the exact thing the paragraph above requires be allowed — `UserData` needs a rooted
key, and `LogData` means prunable occurrences, whereas losing this mapping means a server cannot
decode its own LMDB keys. "Per-server, keyed, mutable, never pruned, never replicated" is not a
row class; it is storage.

## Virtual Columns

`created_at` is not a special case. It is bytes 0–5, and the rule it belongs to is:

> **Virtual columns cost no stored bytes, and most are projections of the row identifier.** The
> row already carries the bytes; naming them costs nothing and refusing to name them only means
> the engine has projections its users cannot write.

This table is the inventory. Any other list of virtual columns is a copy of it.

| Source | Column | Type | On which tables |
|---|---|---|---|
| the row's `DataId` | `id` | `DataId` | all except `Component` |
| `DataId` bytes 0–5 | `created_at` | `Timestamp` | all |
| `DataId` bytes 6–7 | `origin_server` | `:> system.shards.Node` | all |
| `DataId` bytes 8–11 | — sequence, deliberately unexposed | | |
| component id suffix | `ordinal` | `Int` | stored `Component` tables only |
| retention chain level | `grain` | `Grain` | rollup levels only |
| head `PhysicalLocator` | `updated_at` | `Timestamp` | all |

Three entries need a word, because they do not fit the identifier-projection framing — and the
framing is what gives, not the columns:

- **`id` is the identifier**, not a projection of it. It is what six documents were already
  filtering, updating and projecting on with nothing declaring it, so an implementer could not
  tell whether it was reserved, virtual, or a per-table field name. Naming it here settles that.
  It does **not** satisfy the candidate-key rule — counting the surrogate would make that rule
  vacuous ([schema/tables.md](schema/tables.md#candidate-keys-are-mandatory)) — and it renders as
  20 characters of Crockford base32 ([Rendering](#rendering)), never as a uuid.
- **`grain` is a property of the table**, supplied by the retention chain that generated the
  level ([schema/aggregates.md](schema/aggregates.md#grain-is-a-virtual-column)). It is
  key-eligible for the same reason the others are, and leaving it off this table while
  `schema/tables.md` decided key eligibility from it was the drift worth removing.
- **`ordinal` is available on a stored `Component` table only.** A nested table produced by
  `group` or by a projection sub-nesting has no ordinal to report — nothing was inserted there in
  any order ([schema/railroad.md](schema/railroad.md#queries-and-mutation)).

`updated_at` reads the row's current head. Everything derived from the identifier is free in the
strict sense: the bytes are in hand before any lookup happens.

Because `updated_at` is derived from the newest version of the row, anything that writes to a
row perturbs it. This is why nonconformance is recorded in separate rows that point *at* the
subject rather than as a flag on the subject — see [integrity.md](integrity.md).

**A re-key resets `created_at` and `origin_server`**, on the row and on its whole component
subtree, because the successor is a new row with a new `DataId`
([Re-Keying Is Recorded on the Node](#re-keying-is-recorded-on-the-node)). That is a value
changing with no write to any stored field, so it is worth naming at the point of decision rather
than finding later: it restarts any `retain` window and any `Behavior` closing over `created_at`.
`created_at` has an escape — declare a `Timestamp` field, the same escape a component already
has. **`origin_server` has none**, so a table that needs provenance across a re-key declares a
`:> system.shards.Node` field of its own.

That qualifies the sentence key eligibility rests on: `created_at`, `origin_server`, `ordinal`
and `grain` are immutable for the life of the **`DataId`**, not of the entity. A re-key mints a
new `DataId`, which is why it is a delete plus an insert and not an update.

### `origin_server`

The server that issued the row's `DataId`. It surfaces as a **foreign key to
`system.shards.Node`**, not as an `Int`, which is the whole of its value: as a bare 2-byte
integer every "which server wrote this" query is a manual join against a magic number, and the
number is meaningless outside the registry that defines it.

It is the only virtual column that is a reference, and it resolves unusually — through `Node`'s
candidate key on the node id, not through a `DataId`. The projected bytes *are* that key. Two
consequences worth stating:

- `system.shards.Node` rows are never pruned. They are `Configuration` and one per registered
  server, so this costs nothing, but it is now an invariant rather than an accident: a retired
  server's row is what makes its historical rows still readable. The alternative — an
  alternation `origin_server :> system.shards.Node | RetiredServer` — buys nothing and puts an
  absence case into every query for no gain.
- Resolution needs no cluster round trip. `Node` is `Configuration` and therefore replicated to
  every server ([schema/traits.md](schema/traits.md#replication-traits)), so the join is local
  wherever the query runs.

This is the column `system.shards.LogSegment` keys on: see `unique segmentRef` above, where
`origin_server` is the virtual column rather than a declared field. `LogSegment` previously
declared a `server` field for it, which was removed once the virtual column existed — a stored
copy of bytes the row already carries is free to disagree with them.

For a `Component` row, `origin_server` is inherited from the parent's `DataId`, as `created_at`
is: a component has no identifier bytes of its own beyond its ordinal.

### The Sequence Is Not Exposed

Bytes 8–11 disambiguate identifiers issued within one millisecond by one server. That is their
entire content. Naming them would invite code to read them as an ordering, and the ordering
they carry is per-server and per-millisecond — two rows from different servers cannot be
compared by it, and the clock-regression clamp above deliberately continues the counter across
a held timestamp, so even locally it is a tiebreak rather than a time. `DataId` order already
gives the total order anyone reaching for the sequence actually wants.

### `ordinal`

A stored `Component` row's position under its parent, assigned monotonically from 1 and never
reused. It is the one part of a component's identity that is physically stored, and it is already
user-visible in the rendered form (`05KG3N0000ZQ8V4T1H7C.7`), so the column publishes something
the system was showing anyway.

Naming it closes a real gap rather than adding a convenience: **without it there is no way to
express document order in a query.** Component subtrees come back in document order because the
range scan does ([storage.md](storage.md#component-subtrees-are-one-range-scan)), but "in the
order the scan happens to return them" is not a sort a query can state, restate after a join,
or reverse.

`ordinal` is the row's position **at its own level**, not the full path. Nesting appends an
ordinal per level, so a path is variable-length and is already spelled by the rendered
identifier; a column whose type varies with nesting depth would be worse than the identifier it
duplicates. Siblings under one parent are what `ordinal` orders, which is what a document
traversal wants at each level.

For a `Component` row, `created_at` is inherited from the parent's `DataId`: ordinals carry
no time of their own. A component that must record its own creation time declares a
`Timestamp` field.

### Per-Field Timestamps

Both columns are also meaningful **per field**, and both are computable without storing
anything:

- `Table.field.updated_at` — the timestamp of the newest version in which that field's value
  differs from its predecessor. A backward walk of the row's version chain, comparing one
  column.
- `Table.field.created_at` — the version in which the field first held a value other than a
  `Null`-derived one.

Both are written as an ordinary `FieldPath`, so **the reading has to be disambiguated from three
others of the same shape** — a component sub-table path, a document path into an `indexed` field,
and a table-valued column path that distributes. The rule: a `FieldPath` whose last segment is
`created_at` or `updated_at` and whose penultimate segment resolves to a declared field of the
named table is a per-field timestamp, and that reading wins. A field literally named `created_at`
or `updated_at` is therefore rejected.

Three cases have to be answered or the pair is undefined on ordinary rows:

| Case | `field.created_at` | `field.updated_at` |
|---|---|---|
| The field's value has never changed since the row was written | the row's own `created_at` | the row's own `created_at` |
| The field has never held a non-absent value | `NotGiven` | the row's own `created_at` |
| The field was added by evolution and never written on this row | the row's own `created_at`, since the default is an ordinary value the row reads | the **adding schema node's** commit timestamp, which is not a row version |

The third row corrects a premise this section used to rest on: that an evolution-added field
reads `NotGiven` from the row's creation forward, making "first non-absent" a real event. It does
not. Every added field carries a mandatory default and every older row reads that default
([schema/evolution.md](schema/evolution.md#redeclare-a-table)), so there is no absence to date
and no version to walk back to. The informative question — when the *column* appeared — is a
schema-graph fact rather than a row fact, and a cache row buys nothing for such a field until
something writes it.

**A version-chain walk crosses a re-key**, following the link on the transaction node
([Re-Keying Is Recorded on the Node](#re-keying-is-recorded-on-the-node)). One sentence covers it:
the predecessor's post-state is the successor's pre-state. So `Table.field.updated_at` does not
report every field as changed at the move, and an `on` condition sees a transition across the
link rather than a fresh insert. The walk **terminates at an `erase` on a predecessor**, and the
field then reads its value as of the re-key and no earlier — history closed by erasure is not
reconstructed by walking through it ([integrity.md](integrity.md)). An uncached walk that crosses
a re-key crosses a shard, so the hop is counted in `versions_walked` below.

**These are never stored on the row.** Per-field timestamps would multiply row width by field
count to hold something the log already contains — a second source of truth for a derivable
fact. The walk is the definition; anything else is a cache of it.

**The cache is a materialized view, not a rollup table.** The distinction is the one drawn in
[aggregates.md](schema/aggregates.md#pruning-is-only-ever-a-consequence): a materialized view
must be recomputable from its source. Here it always is, for two reasons that between them
cover every table:

- Compaction is lossless, so the version chain of a live row is complete back to its creation —
  or back to the re-key that created it, past which the predecessor's chain continues under its
  own key ([storage.md](storage.md#compaction-is-lossless)).
- `LogData` is the only thing pruning touches, and a log row is an occurrence, so there is
  normally no chain: every field's `updated_at` is the row's own `created_at`. The case where
  history is discarded is the case where there is no history.

**One `LogData` shape does have a chain**, and it is the one most likely to be asked: a `Queue`
extends `LogData`, and its `QueueState` field is the single exemption from append-only, written
repeatedly as an item moves `Pending → InFlight → Done`
([schema/traits.md](schema/traits.md#queue-and-queuestate)). "When did this item enter
`InFlight`" is therefore a real per-field-timestamp question over pruned-eligible data, and it is
the one place the recomputability argument above does not hold. A per-field timestamp over a
`QueueState` field whose earlier versions have been pruned reads `NotRetained`.

#### Declaring and Proposing the Cache

Which fields maintain a cache is a `Configuration` row, not syntax
([schema/traits.md](schema/traits.md#traits-are-not-configuration)) — the set is expected to
change with observed load, and a schema commit per tuning change would be the wrong grain:

```
table system.telemetry.FieldTimeCache : Configuration {
  table_path : Text,
  field      : Text,
  unique fieldTimeRef { table_path, field }
}
```

`table_path` rather than `table`, which is a reserved word — the same reason
`system.integrity.Violation` spells it `subject_table`.

A query may reference `Table.field.updated_at` whether or not a cache row exists; the cache
decides cost, never capability. Uncached, the walk runs, and the reference is recorded:

```
table system.telemetry.FieldTimeRequest : LogData {
  table_path : Text,
  field      : Text,
  versions_walked : Int
}
```

`versions_walked` counts a re-key hop as a step, because the walk crosses one and it is the most
expensive step there is — it leaves the shard. Undercounting it would let the proposal mechanism
argue from a number that hides the cost it exists to measure.

**Observed usage proposes; it does not act.** A recurring request accumulates, and the
maintenance queue raises a proposal to add the `FieldTimeCache` row — it does not add it. A
query that silently caused a view to exist would write schema-adjacent state nobody authored,
in a system whose posture is explicitly-named branches and no anonymous forks. Acceptance is
an operator act (or a `Configuration` policy that auto-accepts above a threshold, off by
default), and it is the same act either way: insert the row.

The proposal rides `system.events.MaintenanceQueue` alongside compaction, repartitioning, and
view refresh, and the request log carries a `retain` chain rolling to per-field request counts
— the frequency, not the individual references, is what a proposal is argued from.

The declaration path matters as much as the proposal path, because usage-driven discovery
cannot cover a cold start: the first query pays the full walk, and if it is a scan rather than
a point lookup it pays it per row. A field known in advance to be queried this way gets its
cache row written up front, and the proposal mechanism exists for the ones nobody predicted.
