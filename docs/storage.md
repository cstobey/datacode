# Physical storage

How the transaction graph is represented on disk. The logical model is in
[transaction-graph.md](transaction-graph.md).

## Log and indexes per shard

One append-only log, and one LMDB environment holding five sub-databases.

### 1. Append-only transaction log (Cap'n Proto frames)

Sequentially written, and append-only *at the graph level*. Below that it is a heap file with
two mutating operations — [relocation](#relocation-rewrites-offsets-not-locators) and
[scrubbing](#scrubbing-overwrites-in-place) — and both are listed here rather than left to be
discovered. Each entry is a length-prefix-framed Cap'n Proto `TxNode` message:

```
[4-byte big-endian length][4-byte CRC-32C][Cap'n Proto TxNode bytes...]
```

The checksum covers the length prefix and the payload together, so a corrupted length is caught
rather than silently reframing the rest of the extent. Three mechanisms depend on it existing:
`scrub` rewrites a frame and its checksum ([Scrubbing](#scrubbing-overwrites-in-place)), a scrub
node records the checksum before and after as tamper evidence
([integrity.md](integrity.md#scrub-overwrites-payload-bytes)), and `verify shard` compares
checksums across replicas ([cli.md](cli.md#disaster-recovery-commands)).

**A CRC detects corruption, not forgery.** Anyone who rewrites bytes recomputes it, so the
checksum alone is not tamper evidence and this document does not claim it is. Tamper evidence is
*cross-replica*: three role holders hold the same frames, so one replica differing is the signal,
and `scrub` is the one authorized rewrite — which is why its node records both checksums and the
divergence resolves against it rather than reading as corruption. `verify shard` without `deep`
recomputes each frame's checksum locally, which is what catches bit rot; `deep` additionally
exchanges per-extent digests with every replica. A coordinated rewrite of all three replicas is
outside what this mechanism detects; it is what the geodiverse placement in
[distribution.md](distribution.md#geo-diversity-goals) makes expensive.

Each `TxNode` carries:

| Item | Notes |
|---|---|
| its own `TxPosition` | the replicated half of a `PhysicalLocator` — sequence and row position, not `ShardIndex` ([transaction-graph.md](transaction-graph.md#physical-locators)) |
| schema version reference | 32-byte hash of the schema graph node |
| timestamp | µs since the Unix epoch |
| server ID | which server committed it |
| parent locator list | the transaction DAG's parents: one normally, two on a merge |
| mutation list | inserts and deletes |
| re-key record list | empty on almost every node. Content and rules: [transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node). Frame properties: [Wire format](#wire-format-for-replication) |

Benchmark: encode and full decode are both under 1µs/tx, and the 10,000-iteration timer could
not resolve them further (`spikes/capnproto/output.txt`). The cereal encoding used during
development measures 0.145µs encode and 0.096µs decode at 10 mutations/tx
(`spikes/storage/output.txt`); those two numbers are cereal's, not Cap'n Proto's.

With Cap'n Proto and mmap, the bytes on disk **are** the runtime representation — field access
is pointer arithmetic, not deserialization. This is the Mnesia analogy: the disk format evolves
with the schema, not with the data.

**No node-kind field.** Split, prune, scrub, erase and re-key are each a top-level annotation
list over the mutations, not a discriminant on the node. Two reasons: a transaction that both
mutates rows and records a prune has no single kind, and an enumerant is the one Cap'n Proto
change that is *not* additively safe ([Wire format](#wire-format-for-replication)) — an old
decoder meeting an unknown one drops the variant silently rather than failing.

### 2. Five LMDB sub-databases

**One LMDB environment per shard.** A shard is the unit that splits, sunsets, exports and
imports, so making it the unit of the environment turns each of those into a whole-environment
operation rather than a filtered copy.

| Sub-database | Key | Value | Purpose |
|---|---|---|---|
| `log_index` | 14-byte `PhysicalLocator` | 12-byte `{offset: Word64, length: Word32}` | Random access to any row version in O(1) |
| `head_index` | row key: 12-byte `DataId`, plus one 4-byte `Ordinal` per nesting level | 14-byte `PhysicalLocator` | Resolve a logical row to its current physical version |
| `version_index` | row key ++ 8-byte `plTxSeq` | 14-byte `PhysicalLocator` | [Walk a version chain](#walking-a-version-chain); resolve `at` by seek |
| `fk_index` | FK field identifier ++ referenced `DataId` ++ referencing row key | empty | [Traverse a `:>` edge backwards](#reverse-foreign-keys-are-an-index) |
| `rekey_index` | successor row key | predecessor row key | [Resolve a re-keyed row backwards](#wire-format-for-replication); empty on a shard that never carried one |

Every `log_index` key inside one environment carries the same `plShard`, so the field is
redundant *as a key*. It earns its four bytes as a **value**, because a server's maintenance
queue, its caches and its derived indexes all span the shards that server holds, and a locator
handed to any of them has to say which `log_index` resolves it. One encoding everywhere is what
the four bytes buy — not a key-size saving, which is the argument
[transaction-graph.md](transaction-graph.md#shardindex) gives and which does not hold at this
layout. The frame carries only the `TxPosition` half, so no `ShardIndex` ever crosses the wire.

All five are server-local and derivable from the log. None is a graph node and none replicates,
so a corrupt or lost index is rebuilt by a scan rather than restored from a peer.

LMDB properties that make this work: memory-mapped (reads touch the OS page cache, not a copy),
MVCC (readers never block writers), crash-safe by default (copy-on-write B-tree plus two root
pages, no separate WAL), and sorted keys — which is what turns a component subtree, a version
chain and a reverse foreign-key lookup each into one range scan.

## Full zero-copy read path

```
row key → head_index → PhysicalLocator
        → log_index  → (file_offset, length)
        → mmap[offset:length] → Cap'n Proto message
        → field access via pointer arithmetic (no copy)
```

### Readers see a stable buffer, or the read fails

Zero-copy means a reader holds a pointer into the mapped file, so anything that rewrites those
bytes rewrites them under the reader. This is the load-bearing hazard of the choice and it is
answered here rather than left implicit. Crotty, Leis and Pavlo, *Are You Sure You Want to Use
MMAP in Your DBMS?* (CIDR 2022), is the standard statement of it — a Cap'n Proto reader over a
buffer that changes mid-traversal does not fail cleanly, because pointer validation is lazy and
per-access, so a mutated message yields arbitrary structure rather than an error.

LMDB's MVCC protects the index, not the log file. The discipline that protects the log:

- **Relocation writes before it publishes.** The row is written to its new extent first, the
  `log_index` value is updated in one LMDB write transaction, and the old extent range is freed
  only after every read transaction older than that write has closed. LMDB already tracks reader
  transaction ids; reuse them as the epoch rather than inventing one.
- **Scrubbing takes the same fence**, with one difference: the bytes are zeroed rather than
  moved, so a reader that started before the fence and is still traversing may observe zeros.
  The frame checksum is what makes that detectable, and the read is retried against the rewritten
  frame. A scrub is rare and administrative, so a retry is the right cost.
- **A reader never re-resolves mid-message.** It resolves `log_index` once, inside a read
  transaction, and holds that transaction open for the length of the traversal.

## Component subtrees are one range scan

`head_index` keys are variable-length: a `DataId` for an ordinary row, and a `DataId` followed
by one 4-byte `Ordinal` per nesting level for a component row (see
[transaction-graph.md](transaction-graph.md#component-ordinals)).

Because LMDB sorts keys as bytes and every descendant shares its parent's byte prefix, a
parent's entire component subtree is a **single contiguous range scan** returning nodes in
document order — no scatter-gather and no stored parent pointers to follow. This is the property
the document type is built on.

Stated exactly, because the weaker version has been read as stronger: the subtree's `head_index`
entries are one contiguous range scan, and — given the containment clustering the same shard
requires ([Clustering order](#clustering-order)) — the frames they name are physically adjacent,
so a shredded document of 200 nodes is one sequential read rather than 200 scattered ones.
`log_index` resolution is still one lookup per node.

## Walking a version chain

`head_index` yields the head. Historical `at` reads, `diff` between two graph points, per-field
`created_at` and `updated_at`, and `enforce forward`'s comparison against the predicate as it was
all need the *prior* versions, and neither `head_index` nor the `TxNode`'s parent list can supply
them — a transaction's parents are the DAG's parents, and one transaction touches many unrelated
rows, so they say nothing about any single row's chain.

`version_index` is that structure. Its key is the row key followed by the 8-byte `plTxSeq`,
big-endian so lexicographic order is numeric order, which gives two operations for one index:

- **The whole chain** is one prefix range scan over the row key, in commit order.
- **`at <token>`** is a seek to the greatest key at or below the peg — no walk at all.

Two details the encoding decides rather than declares:

- **A chain scan is bounded by key length.** A parent's row key is a prefix of its children's,
  so a prefix scan would otherwise pick up descendants. An entry longer than the row key plus
  eight bytes belongs to a descendant and is skipped. This is the same prefix property the
  component subtree scan relies on, read in the other direction.
- **`head_index` is derivable from `version_index`** — it is the last entry of the prefix range.
  It stays a separate database because the head lookup is the hot path and deserves one B-tree
  descent rather than a range positioning.

Rejected: a `prevLocator` field on each row's frame, giving a singly-linked chain walked through
`log_index`. It costs a pointer word on every frame in the cluster forever, it makes `at` an
O(versions) walk instead of a seek, and it puts a derived fact in the replicated wire format. An
index is server-local, rebuildable by a log scan, and answers `at` directly.

The walk's one gap is retention: over a range pruned by a `UserData` `retain` chain there are no
versions left to find, and the chain reads `NotRetained` rather than a wrong answer. See
[Compaction is lossless](#compaction-is-lossless).

## Reverse foreign keys are an index

An anchored assert revalidates the rows that reach the inserted one, negative-assertion
revalidation does the same, and `erase shard` cascades through the foreign-key chain — all three
traverse a `:>` edge **backwards**. A dependent row's `DataId` bears no relation to the row it
references, so `head_index` cannot answer "which rows reference this row" and the only fallback
is a full shard scan. That defeats the reason anchoring exists
([schema/constraints.md](schema/constraints.md#anchoring)).

`fk_index` makes the reverse direction a prefix range scan. It is keyed by the FK field's
identifier, then the referenced `DataId`, then the referencing row key; the value is empty,
because the key carries everything. The field identifier is the interned field path, not the
declaring schema node — a field path is bound for the life of the table
([schema/evolution.md](schema/evolution.md#rename-a-field)), so an interned path keeps one
prefix across every redeclaration of that field, where a node id would fragment the range and
hide rows written under an earlier node.

Three properties worth stating:

- **It tracks current state, not history.** An insert that changes an FK removes the entry under
  the old target and adds one under the new, in the same LMDB write transaction as the
  `head_index` update.
- **It is mandatory, never proposed.** [Materialized views](#views-are-proposed-not-created-silently)
  are proposed from observed load after queries have run slowly; a correctness-critical
  revalidation set cannot wait on a proposal.
- **It costs one entry per `:>` field per live row**, written on every insert and delete of that
  field. That is the price of anchoring being bounded, and it is charged on write rather than on
  read.

## Extents and clustering

A shard's append-only log is written in **extents** — runs of the log allocated on one server
and sized from `system.shards.ExtentPolicy`. An extent is a unit of storage, not of authority;
the distinction and what rests on it are in
[transaction-graph.md](transaction-graph.md#extents-are-not-shards). *Extent* rather than
*page*, because LMDB has pages of its own at a lower level.

### Relocation rewrites offsets, not locators

`log_index` maps a 14-byte `PhysicalLocator` to `{offset, length}`. The offset is the **value**,
so moving a row between extents of its own shard rewrites that value and touches nothing else:
the locator is unchanged, `head_index` and `version_index` are unchanged, no new row version is
created, `updated_at` does not move, no graph node is written, and nothing replicates. Two
servers therefore cannot disagree about it — there is nothing to disagree about.

This is what makes repartitioning a background task rather than a maintenance window. It runs
under the event scheduler on `system.events.MaintenanceQueue` alongside compaction and view
refresh, pegged to a stable commit node the way a materialized view computation is, and it
publishes under the reader fence above.

### Compaction is lossless

Compaction shares the maintenance queue with repartitioning and shares its guarantee:

> **Compaction never discards a row version.** It changes where bytes live so they are stored
> more optimally as the schema evolves, and nothing else.

Superseded row versions are not garbage. They are the version chain, and the version chain is
the transaction graph's account of how a row reached its current value — the thing "nothing is
destroyed" is about. A compactor that collapsed old versions to reclaim space would be
rewriting history to save disk, which is the trade this design exists to refuse.

**Pruning is the sole way data is lost, and what it loses is granularity, on purpose.** It
happens only as the consequence of a declared `retain` chain, the coarser resolution is written
before the finer one is discarded, and a prune node records the boundary
([transaction-graph.md](transaction-graph.md#pruning)). The four are worth stating as a set,
because three of them share the maintenance queue and only two may lose anything:

| Operation | Trigger | May lose |
|---|---|---|
| Relocation | volume, background | nothing — not even a locator |
| Compaction | schema change, background | nothing — every version survives |
| Pruning | a declared `retain` chain | granularity of log buckets, and a `UserData` row's version chain where a chain covers it — deliberately, after the rollup exists |
| Scrubbing | an administrative act or a scrub rule | one field's bytes, irrecoverably |

The consequence relied on elsewhere: **anything derivable from a row's version chain stays
derivable for as long as the row exists, except over a range a `UserData` `retain` chain has
pruned.** That is what lets per-field timestamps be a cache rather than a stored column
([transaction-graph.md](transaction-graph.md#per-field-timestamps)); over a pruned range they
read `NotRetained`, a typed gap rather than a wrong answer
([schema/aggregates.md](schema/aggregates.md#retain-on-userdata-is-admissible-and-rare)).

Two operations break the guarantee, then, and they break it differently. Retention is declared,
scheduled and typed at the read. Scrubbing is administrative and irrecoverable, which is why it
records what it did.

### Scrubbing overwrites in place

Scrubbing is the one operation that mutates the *contents* of a written frame. Policy — who may
invoke it, what a scrub node records, and how tamper evidence survives — is in
[integrity.md](integrity.md#erasure-restricts-scrub-destroys). Three physical rules:

- **The payload allocation keeps its original length.** `log_index` maps a locator to
  `{offset, length}`, so a shorter replacement would force every row after it in the extent to
  relocate. Zeroing in place rewrites the frame and its checksum and touches no index at all.
- **The gap discloses the length of what was there.** This is a physical fact, not a policy
  choice, and it is why the scrub node records the length rather than pretending otherwise.
- **Compaction reclaims the gap, not the disclosure.** A scrubbed run is dead space that the
  next compaction pass reclaims through the ordinary locator indirection. The length stays
  readable to anyone who can read the scrub node, permanently and by design
  ([integrity.md](integrity.md#scrub-overwrites-payload-bytes)) — so the reason to prioritize
  scrubbed extents on the maintenance queue is the reclaimed space, not a privacy gain.

### Clustering order

Rows are laid out within an extent in an order chosen per shard family:

| Family | Order |
|---|---|
| `LogData` | time, which is `DataId` order |
| `UserData` | containment — the root row, then its component subtrees, then dependents by foreign-key depth |

`UserData`'s order matters more than it looks. "A shredded document of 200 nodes is one
sequential read" holds only because the log is clustered so that a component subtree is
*physically* adjacent, not merely adjacent in `head_index` — a contiguous key range still yields
200 locators, and they point somewhere. Any relocation that reorders rows without preserving
containment adjacency invalidates that claim. Containment is therefore the constraint, and
everything else is a tie-break inside it.

**Schema PageRank breaks the ties** — which dependent tables sit next to the root when they
cannot all fit. That score is computed over the *schema* graph
([api-and-rendering.md](api-and-rendering.md#schema-linearization)), so the ordering is a
function of the schema and is recomputed only on schema commit. A data-dependent ordering was
rejected for three reasons: it relocates rows for reasons unrelated to any write, it produces
layouts that differ between replicas computing it independently, and per-row importance is not
what schema PageRank computes in the first place. The determinism requirement this places on the
computation is noted in OQ-010.

## Files are chunked components

A `File` value's bytes are **`Component` rows of the row that holds the field**, so they are
identified by `<parent DataId>.<ordinal>`, ordered, and read as one contiguous range scan. No
new physical concept: the chunks reuse the structure documents already use.

The chunk table is generated, one per `File` field, the way `Doc indexed` generates its node
table. Nobody declares it, and generating one per field is what keeps two `File` fields on one
row from sharing an ordinal space.

Each chunk carries a digest. Two rules keep that from becoming something else:

- **The digest is for verification and transfer, never for identity.** Content-addressed pieces
  tempt deduplication, and deduplication is rejected: sharing one content row across owners
  breaks `erase` and collapses N access policies onto one row. This is where the design departs
  from BitTorrent, whose whole model is content-addressed identity.
- **Each chunk is its own transaction.** One large synchronous write head-of-line-blocks a
  linearized shard primary, which is the reason a size cap exists at all; chunked writes make it
  a stream of small transactions instead. The upload path and the distribution path are then the
  same work — announce-and-fetch widens from sequence ranges to chunk digests, so a peer can ask
  for piece 47 without pulling the transaction that carried it
  ([distribution.md](distribution.md#push-for-liveness-fetch-for-resume)).

A read of `File` content is bounded by a `system.config` size cap; above it the value is
reachable only through the streaming handler, which is a range scan the caller consumes rather
than a value the query returns. The write cap ships as a `Configuration` row, and the chunked
path above is the way past it rather than a bigger number.

### Where the chunks live

Three placements, and only the first two are mechanisms.

**(a) Inside the graph, by default.** Whether a field's chunks sit inline with the parent's
extent or in an extent of their own is pure tuning and invisible to the model, so it is a
`Configuration` row beside `ExtentPolicy`, per field with a per-server override:

```
table system.shards.ChunkPolicy : Configuration {
  field_path : Text unique,
  placement  : Inline | OwnExtent = Inline,
  chunk_size : Int
}

table system.shards.ChunkOverride : Configuration {
  field_path : Text,
  server    :> system.shards.Node,
  placement  : Inline | OwnExtent,
  chunk_size : Int,
  unique chunkOverrideRef { field_path, server }
}
```

Two tables rather than one keyed by `{ field_path, server }` with an "all servers" variant, for
the reason that already split `ExtentPolicy` from `ExtentOverride`: a `Null`-derived variant in
a key is rejected ([schema/tables.md](schema/tables.md#ineligible-key-fields)). Resolution is
most-specific-first.

**(b) On the server filesystem, as a separately named type.** The row holds a digest and a path;
the bytes are not in the graph. This is available, and it is a **distinct type rather than a
quiet per-field flag**, because it gives up four properties a reader otherwise assumes:

| Given up | Consequence |
|---|---|
| `verify shard` cannot check the bytes | corruption is invisible to the integrity path |
| replication does not carry them | a secondary has the row and not the file |
| a restore does not restore them | recovery is incomplete by construction |
| `scrub` cannot reach them | erasure has to be performed out of band |

Four properties is too much to lose to a field modifier nobody reads twice, so the type name is
what warns. The name and its declaration belong in
[schema/types.md](schema/types.md#primitive-types).

**(c) A purely external reference is an ordinary `Text` URL** and needs no mechanism at all.
DataCode serves its own CSS and JS, so this is for third-party content rather than for the
product's own assets.

## Shredded documents

A `Doc` field stores the received bytes in the row, and nothing else. The bytes stay
authoritative rather than becoming a cache of the shredded form, and the reason is not a storage
one: signature verification needs the exact bytes as received. The argument is in
[schema/documents.md](schema/documents.md#storage-bytes-first-shredded-second).

When the field is declared `indexed`, the shredded **node** tree is a materialized view over
those bytes: pegged to a commit node, computed in the background, rebuildable at any schema
node, and droppable without data loss.

That scope is exact. The `…Key` and `…KeyRaw` tables are **not** part of it. Which keys intern
and which spill depends on the cap's fill state when each document arrived, and which tag a key
holds depends on arrival order, so a rebuild is not a pure function of the bytes. Those tables
persist across a drop, and a rebuild reuses the key table at the schema node it rebuilds against
rather than recomputing it ([schema/documents.md](schema/documents.md#key-spill)).

## LMDB threading

Requires `-threaded` in GHC options and a session-level `runInBoundThread` wrapping the
entire LMDB session (open → read/write → close). The `lmdb` Haskell package calls
`isCurrentThreadBound` before acquiring its write lock. Production pattern: one dedicated
OS-bound thread (`forkOS`) for writes, with a `TQueue`; reads are concurrent (LMDB MVCC).

See `spikes/capnproto/src/Spike/LmdbFixed.hs`.

## LMDB latency

Confirmed in `spikes/capnproto/output.txt`: reads 11µs/op, writes 1,107µs/op. Write latency
is high because LMDB `fdatasync()`s on every transaction commit (durability guarantee).
DataCode batches multiple mutations per transaction (10–100 mutations/tx → 11–110µs/mutation),
so single-mutation micro-benchmarks are not representative of production write patterns.

**That number is the LMDB index write alone**, exclusive of the log append and its sync, and
exclusive of replication. A `UserData` commit under the default synchronous durability class
also waits for two secondary ACKs, and with a secondary out of region that wait is three to four
orders of magnitude larger and dominates everything else. The commit-latency budget, and what
placement does to it, are in [distribution.md](distribution.md#two-durability-classes).

## Wire format for replication

Confirmed in `spikes/capnproto/output.txt`: use cereal during initial development; swap to
Cap'n Proto generated code before production. Wire framing (length-prefix + single-segment
message header) is identical — only the payload encoding changes.

Cap'n Proto supports **additive** schema evolution: a field added at a new ordinal is readable by
old decoders, which ignore it, and by new decoders reading old messages, which see the field's
default — confirmed in both directions in `spikes/capnproto/output.txt`. Reusing an ordinal,
retyping one, or moving a field into or out of a union is a breaking change and is not permitted
on `TxNode`. "Always compatible" is the phrasing that invites precisely the change that breaks
it.

Cost depends on the field. The measured case — an 8-byte scalar forcing a third data word —
added 8 bytes (V1 = 112, V2 = 120). A `Bool` or small integer fitting free bits in an existing
data word costs nothing. A **pointer** field, which is what a list is, costs one pointer word on
every message whether or not it is populated, plus the content when it is. The re-key record is
a list, so it is priced that way: one word on every `TxNode` in the cluster, forever, against a
frame of roughly 112 bytes. The rule still wins — transactions are one to two orders rarer than
rows, and the alternative stores a fact about a transaction on a row — but it is priced, not
denied. Re-run the spike with a pointer field before leaning on the 8-byte number for it.

**Cap'n Proto's implicit zero is ordered under DataCode's declared default.** A row written under
an older schema node decodes short, and the encoder answers 0 where the schema says 42. The wire
zero is a decode artefact and never a value: field absence in the frame means "written before the
field existed", and what the field reads is the declared default resolved at read from the schema
node current for that row version
([schema/evolution.md](schema/evolution.md#redeclare-a-table)). Every field added to an existing
table carries a default, which is what makes a short decode's semantics well defined.

Protobuf is **not** a substitute: Protobuf requires full parsing; Cap'n Proto mmaps the bytes
directly. MessagePack is excluded by the same argument. Cap'n Proto requires the `capnp` C++ tool
at compile time (`apt install capnproto`).

### How the re-key record sits in the frame

What the record *says* is in
[transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node). Four facts about
how it is carried belong here, and each is a property of the format rather than of the rule:

- **A new top-level `TxNode` field, not a third `Mutation` union member**, even though the union
  is cheaper. Union compatibility is weaker than field compatibility: an old secondary meeting an
  unknown tag applies the transaction and drops the variant, which is silent divergence rather
  than a decode error. The record is also an annotation *over* the mutation list rather than
  another mutation, so a field is the honest shape.
- **It is never load-bearing for applying a transaction.** A decoder that ignores the field
  applies the delete and the insert correctly and loses only the link. That is what keeps the
  frame additively evolvable and what a rolling upgrade depends on
  ([distribution.md](distribution.md#host-rotation-and-upgrade-cycles)).
- **It inherits its carrier node's visibility.** The record is a statement about one transaction,
  not a live `successor` pointer, so a record on an unresolved or aborted prepared node renders
  as pending or aborted and never as a move.
- **One list per shard.** A bulk or cluster-wide re-key is already per-shard and possibly partial
  ([distribution.md](distribution.md#bulk-and-cluster-wide-mutations)), and records follow the
  mutations they annotate.

**The new→old index** is the physical form of the lookup every consumer actually needs. The
record is old→new and lives on the source shard, while the version-chain walk, a violation's
subject, a held trigger bit and merge reconciliation all start from the successor. So each
shard's environment carries a `rekey_index` sub-database keyed by the successor's row key and
valued by the predecessor's. It is built by scanning that shard's own records, which works
precisely because both prepared nodes carry an identical record
([distribution.md](distribution.md#cross-shard-transactions)) — the destination holds the same
pairing the source does. It has the same posture as the other four sub-databases — server-local,
unreplicated, derived, rebuildable — and a shard that has never carried a re-key has an empty one.

## Materialization

Materialization is how DataCode delivers data independence for analytical queries. A query you
have never run is slow, because nothing has been arranged for it. Subsequent runs are fast,
because the arrangement now exists and is maintained. Nothing about the query changes.

A materialized view is pegged to a **specific commit node** in the transaction graph, and to a
sample moment where the query reads a behavior
([schema/queries.md](schema/queries.md#every-query-has-a-sample-moment)):

- It never blocks or slows ongoing transactions, because it references a past, stable state.
- It is updated in the background, or lazily on access.
- Each server maintains its own.
- Neighbouring servers can share the computation — distribute the work, merge the results. See
  [distribution.md](distribution.md#materialized-view-distribution).

**Materialization always runs pre-redaction**, and access asserts are re-applied when the view is
read. That is why the peg needs no token: a view built under one requester's visibility would be
wrong for every other one ([schema/constraints.md](schema/constraints.md#redaction-scope)).

### A view is a derived table, not a second engine

A materialized view's rows *are* rows. They already have a format, an index, a locator
indirection, a compactor, a scrubber, a backup story and a wire protocol, so materialization
needs no storage engine of its own. Two physical concepts, and each refines something already in
this document rather than adding machinery:

| Concept | What it is |
|---|---|
| **Derived extent** | An extent holding a view's rows. Droppable and unreplicated, because it is recomputable from the peg. |
| **Arrangement** | One LMDB sub-database per view and per order, keyed by that order's tuple. |

**An index is the degenerate materialized view** — an arrangement over one table in one order,
with no projection and no join. That is the physical content of "materialization replaces the
user-defined index", and it is why the two need one mechanism rather than two.

Rejected: LMDB as a separate view store, and SQLite as an embedded one. Each adds a second row
format, a second index, a second compactor, a second scrubber, a second backup story and a second
wire protocol, plus a serialization boundary that breaks the zero-copy claim for that path. The
cost is paid to gain something the ordinary storage path already provides. DuckDB is worth having
as an Arrow or Parquet **export target** from a tertiary, where nothing is on the write path;
never as an engine.

**Materialization replaces the user-defined index for query arrangements.** There is no
`create index` over stored columns, because the set of arrangements worth maintaining is a
function of observed load rather than of the schema author's foresight. The one author-declared
arrangement is `Doc indexed`, where the shape being materialized is a property of the field
rather than of observed load — see [Shredded documents](#shredded-documents).

### Views are proposed, not created silently

The maintenance queue reads the request log (`system.logs.HttpRequest`,
[api.md](api.md#http-request-logging)) and **proposes** a materialized view. An operator accepts,
or a `Configuration` row sets the threshold above which a proposal is accepted automatically.

The proposal step is not ceremony. A query that silently created a view would write state
nobody authored, in a system built on named branches and no anonymous forks. This is the same
mechanism, one scope wider, as the per-field timestamp cache
([transaction-graph.md](transaction-graph.md#declaring-and-proposing-the-cache)) and as cold-shard
sunsetting ([distribution.md](distribution.md#sunset-is-proposed-never-automatic)) — automatic
behaviour is a policy somebody set, recorded in a row you can query and reject.

All three read the same two tables, which are declared here because this is the fullest
statement of the mechanism:

```
table system.telemetry.Proposal : LogData {
  kind      : MaterializedView | FieldTimeCache | ShardSunset,
  subject   : Text,
  evidence  : Doc,
  decisions :> Decision : Component { outcome : Accepted | Rejected }
}

table system.telemetry.ProposalPolicy : Configuration {
  kind              : MaterializedView | FieldTimeCache | ShardSunset,
  auto_accept_above : Int | Disabled = Disabled,
  unique policyKind { kind }
}
```

Acceptance is an **append, not a mutation**. `decisions` is a `:>` to a `Component` target, so it
is table-valued ([schema/tables.md](schema/tables.md#component-sub-tables)): it holds every
decision ever taken on that proposal, in `ordinal` order, and the current state is the last one —
an ordinary query. A mutable `state` column would have been another append-only exemption in a
design that advertises one, and it buys nothing: "accepted, rejected on review, accepted again"
is the history an operator wants, and a single column is exactly what destroys it.

`auto_accept_above` defaults to `Disabled`, so nothing is automatic until an operator says so.
No authority column on either table: the acting token is recoverable through
`system.logs.HttpRequest.tx_id` ([api.md](api.md#http-request-logging)), the same argument the
re-key record makes
([transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node)).

Operators inspect and override the result:

```
show materialized views shard user.commerce
materialize app.reporting.MonthlySummary
refresh view app.reporting.MonthlySummary
drop materialized view app.reporting.MonthlySummary
```

`materialize` is an admin command rather than schema syntax, for the reason `retain` and
`enforce` are separate statements: it is operational policy that changes over time, and it is not
the schema author's decision to make. See [cli.md](cli.md#materialized-views).

### Refresh class is decided by the key and by the aggregates

A derived table's candidate key comes from its sources rather than a declaration
([schema/queries.md](schema/queries.md#keys-are-computed-never-declared)), and which kind of key
it derives sets a ceiling on how the view can be maintained:

| Derived key | Refresh ceiling |
|---|---|
| Meaningful — a proper subset identifying an entity | **Incremental**, at best. The key says which row a recomputed one replaces, so a refresh upserts only what changed. |
| Degenerate — all attributes | **Full only.** Nothing identifies a row across recomputations, so the extent is rebuilt. |

A meaningful key is necessary and not sufficient. Refresh is actually incremental only if every
aggregate in the projection is invertible under deletion and the query contains no negation over
a source. `count` and `sum` are invertible; `min`, `max` and `percentile` are not, so
`Order group { customer } { customer, max rows.total as biggest }` has the same meaningful key as
its `count` counterpart and still has to rescan a group when the maximal row goes. The reported
class is therefore three-way — `incremental`, `insert-only`, `full only` — and `:describe` prints
it.

This is the same idempotence property that lets a retention rollup play catch-up without
duplicating buckets ([schema/aggregates.md](schema/aggregates.md#what-gets-generated)) — a
keyed derived table can be recomputed for any window and merged, an unkeyed one cannot.

It also decides whether a derived table can outlive its sources. See
[schema/evolution.md](schema/evolution.md#a-degenerate-dependent-blocks-deprecation).

Materialization is a storage decision, never a schema-level distinction: a table, a query, and a
derived table are one kind of thing, and whether rows are stored for it is decided here rather
than in the declaration. See [schema/queries.md](schema/queries.md).

**Two things are view-shaped and cannot be materialization.** Both fail the same test — a
materialized view is recomputable from its source by definition:

- **Retention rollup levels**, whose source is pruned as soon as the rollup exists. They are real
  tables with their own entries in the append-only log
  ([schema/aggregates.md](schema/aggregates.md#a-rollup-is-two-appends-not-a-rewrite)).
- **A binding whose source is superseded in the same commit**, which is frozen into storage
  because the definition it was written against is no longer current
  ([schema/evolution.md](schema/evolution.md#how-a-commit-resolves-names)).
