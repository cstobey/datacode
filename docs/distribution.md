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

## Replication Protocol

### Transaction Propagation
- Transactions are **sequence-numbered deltas** within a shard
- The primary assigns sequence numbers; all replicas apply them in order
- Secondaries must acknowledge receipt before a transaction is considered committed
- Tertiaries receive transactions asynchronously — eventual consistency for reads, no durability guarantee

### Peer-to-Peer Propagation (BitTorrent Model)
Instead of all nodes pulling from the primary directly (MySQL-style with explicit replication routes), DataCode uses a **gossip/swarm model**:
- Each server announces what sequence numbers it has to its neighbors
- Servers fetch missing sequences from any neighbor that has them (not only from the primary)
- This distributes the replication bandwidth and avoids single points of saturation
- Network paths between servers may be pre-declared as an optimization hint (not a requirement)
- Secondaries are expected to be fully caught up; tertiaries may lag

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
keyed by `{ server, period_start, branch }`. See
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
| A `LogData` period closes, or its segment exceeds the size threshold | Seal the segment and start a new one | Automatic — sealing moves no data |
| A `UserData` shard exceeds the size threshold | Report; wait for `split shard … at key` | Operator — a split redistributes roots and moves authority |

The line is mechanical rather than a matter of taste: an operation that moves no data and
writes no graph node can be automatic, and one that moves authority cannot. Thresholds and the
segment period are `Configuration` rows (`system.shards.ExtentPolicy`, with a per-server
`system.shards.ExtentOverride`), not syntax and not trait parameters — see
[schema/traits.md](schema/traits.md#traits-are-not-configuration). This answers OQ-007; the
default values are OQ-035.

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
- What are the default extent size and segment period, and is a shard group formed automatically or by an operator? (OQ-035 — the split *trigger* itself is settled above)
- How are network path hints declared and stored? (Likely a `system` shard table)
