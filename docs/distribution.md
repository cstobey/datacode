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

## Materialized View Distribution

Materialized views are maintained independently per server but can be computed cooperatively:
- A server can broadcast a query plan fragment to neighbors
- Neighbors compute their local contribution and return results
- The requesting server merges contributions
- This is particularly useful for tertiary servers dedicated to analytical workloads
- View computations are pegged to a stable commit node so they can proceed without blocking ongoing transactions

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
- Should shard splits be automatic (threshold-triggered) or operator-initiated with threshold warnings?
- How are network path hints declared and stored? (Likely a `system` shard table)
