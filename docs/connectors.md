# Connectors and External Data Ingestion

## Overview

DataCode can ingest data from external sources and maintain bidirectional sync with them. The connector system is the bridge between DataCode's category-theoretic internal model and the messier reality of external databases, APIs, and services.

**Design principles:**
- All connector configuration lives in DataCode system tables — no config files, no restarts for config changes
- DataCode tends toward being the system of record (most information, all business rules encoded as functors), but authority is tunable per connector
- Bidirectionality is enforced entirely within DataCode — external systems do not need to know DataCode exists
- Connectors are modular; new connector types can be added without restart if no new Haskell packages are required (new package dependencies require a server reboot — this is a known limitation of the dynamic loading model)
- Auto-discovered external schemas live in their own namespace and can be layered over by human-managed schemas

---

## Connector Types

### Database Connectors (Row-Based Replication)

#### MariaDB / MySQL
**Required replication source.** This is the primary migration path and the only database replication connector in scope for v1.

**Library**: `mysql-haskell` (`Database.MySQL.BinLog`) — actively maintained, pure Haskell, no FFI.

DataCode connects as a pseudo-replica using `registerPseudoSlave` and opens the binlog stream with `dumpBinLog`. Only row-based replication is supported (`binlog_format=ROW` must be set on the source). `decodeRowBinLogEvent` decodes each event into Write/Delete/Update variants.

Setup requirements on the MariaDB source:
```sql
SET GLOBAL binlog_format = 'ROW';
GRANT REPLICATION SLAVE ON *.* TO 'datacode'@'%';
```

Position tracking: DataCode records the binlog filename and offset (from `getLastBinLogTracker`) in a system table after each processed event. This is the checkpoint — DataCode resumes from this position on reconnect.

#### PostgreSQL
**NOT DOING.** Nice-to-have; deprioritized in favor of MariaDB/MySQL. The available library (`postgresql-replicant`) was abandoned in 2021 and would require a fork or rewrite. This is not worth the investment for v1 given the company's predominant use of MariaDB/MySQL. Revisit post-v1 if there is demand.

#### Redis
**NOT DOING.** Nice-to-have; deprioritized. No Haskell library exists for the PSYNC replication protocol, and the Redis Streams CDC approach requires changes on the Redis source side (not transparent). Not worth the complexity for v1. Revisit post-v1 if needed.

---

### Web API Connectors

Web APIs have no change stream equivalent to a database binlog. Each API requires a custom connector, but DataCode provides tooling to make this easier.

**Supported patterns:**

| Pattern | Mechanism | Bidirectionality |
|---|---|---|
| Webhook ingestion | API calls DataCode; DataCode records event | Inbound only; outbound via API calls |
| Polling | DataCode polls API on schedule | Both directions via read + write calls |
| Hybrid (e.g. Stripe) | Webhooks for real-time + sigma/batch for drift detection | Full |

**Example — Stripe:**
- Inbound real-time: Stripe sends webhooks to DataCode's webhook endpoint; DataCode validates signature, records event in connector transaction log
- Outbound: DataCode calls Stripe API when DataCode-side changes need to propagate
- Drift detection: Stripe Sigma queries (time-delayed by hours to days) are scheduled to run periodically and compared against DataCode's transaction log for the same time window
- Latency window: configurable per connector (Stripe Sigma drift detection window might be 48 hours)

Web API connectors are not auto-generated — each API requires custom mapping work. Tooling to accelerate this is a separate concern (see vclods-adjacent tooling in the ecosystem).

---

## Sync Protocol

### Transaction Log Mapping

DataCode maintains a **connector transaction log** alongside its own internal transaction log. For each external source:

```
connector_log entry:
  connector_id        UUID        -- which connector
  external_seq        Text        -- external position (binlog offset, stream ID, etc.)
  external_timestamp  Timestamp
  operation           Enum(Insert, Update, Delete, StateCheck)
  external_table      Text
  external_key        Text        -- serialized PK of the affected row
  external_payload    JSONB       -- the raw external record
  datacode_txn_id     UUID?       -- linked DataCode transaction, if applied
  sync_status         Enum(Pending, Applied, Conflict, Skipped)
```

DataCode maps the two logs together by matching external records to internal ones via key mappings defined in the connector configuration. This gives DataCode full visibility into both sides' mutation history for any given entity.

### Conflict Resolution

Conflicts arise when both DataCode and the external source have mutations for the same entity between sync windows. Resolution priority (in order):

1. **Functor-based semantic resolution** (preferred): DataCode applies its business rule functors to evaluate whether the sequence of mutations on both sides is logically consistent. Example: if DataCode and Stripe both have an "order status changed to Shipped" event with different timestamps but identical semantics, they can be reconciled without a conflict.

2. **Log-sequence analysis**: DataCode compares the ordering of events in both logs. If one side's mutations are a strict prefix of the other side's, the longer sequence wins.

3. **Timestamp last-write-wins** (last resort): If semantic and sequence analysis cannot resolve the conflict, the most recent mutation timestamp wins. This is configurable and can be disabled in favor of alerting.

4. **Manual resolution**: Unresolvable conflicts are flagged in a system table for operator review. The conflicting records are held in a `Conflict` state and not applied until resolved.

The authority model is tunable per connector:
- `DataCode-authoritative`: DataCode's version wins on unresolvable conflict; external is updated
- `External-authoritative`: External version wins; DataCode records the override
- `Symmetric`: Full resolution protocol as above (default)

### State Verification

Replication channels break. DataCode verifies sync correctness by periodically comparing live state against the external system, independently of the transaction log:

1. **Verification schedule**: Configurable per connector (e.g., every 6 hours for Stripe Sigma, every 5 minutes for MariaDB)
2. **State snapshot**: DataCode fetches the current state of a sample or full set of entities from the external source
3. **Comparison**: Compared against DataCode's current materialized state for the same entities
4. **Discrepancy handling**: Discrepancies within the connector's **latency window** are ignored (the sync channel may simply be behind). Discrepancies outside the latency window trigger reconciliation.

### Latency Windows

Every connector has a configurable latency window — the expected maximum delay between a mutation at the source and its appearance in DataCode (or vice versa). Discrepancies within this window are not acted on:

```
-- Stored in connector system table
connector_config:
  connector_id         UUID
  latency_window_ms    Int          -- ignore discrepancies younger than this
  verification_interval_ms  Int     -- how often to run state checks
  authority_model      Enum(DataCode, External, Symmetric)
  max_retry_attempts   Int
  conflict_action      Enum(Auto, Alert, Halt)
```

Stripe Sigma example: `latency_window_ms = 172800000` (48 hours), because Sigma data can lag webhooks by up to 2 days.

---

## Schema Auto-Discovery

When a connector is added, DataCode introspects the external source's schema:

1. **Auto-generated shadow schema**: Created in a dedicated namespace (e.g., `connectors.mariadb.production`). Contains DataCode table definitions mirroring the external schema, with types mapped to the closest DataCode equivalents.

2. **Schema change tracking**: The connector monitors for external schema changes (new columns, type changes, dropped tables) and updates the shadow schema in the connector transaction log. Each change creates a new node in the schema transaction graph.

3. **Human-managed overlay**: Users define their own schema namespace (e.g., `app.commerce`) that references or views over the auto-generated namespace. This is where DataCode-native types, renamed fields, ADTs replacing nullable columns, and access control functors live.

4. **Visibility**: Auto-generated schemas are hidden from the default IDE view. Users explicitly opt in to viewing them (see ide.md).

5. **Backwards compatibility**: Because all schema versions live in the transaction graph, old queries against the auto-generated schema continue to work even as the external schema evolves.

---

## Dynamic Configuration

All connector configuration is stored in DataCode system tables. Adding or modifying a connector does not require a server restart:

- **New connector instance** (same type, e.g., a second MariaDB database): insert a row in `system.connectors`; the connector daemon picks it up immediately
- **Configuration changes** (credentials, latency window, authority model): update the system table row; takes effect on next sync cycle
- **New connector type** (new Haskell package required): requires server reboot — no way around this with static compilation. New connector types that need no new packages (implemented entirely in existing DataCode machinery) can be added dynamically.

The connector daemon polls `system.connectors` for changes on a short interval (configurable, default 10 seconds).

---

## Known Library Status

| Source | Library | Status | Action |
|---|---|---|---|
| MariaDB/MySQL | `mysql-haskell` `Database.MySQL.BinLog` v1.2.5 | Active, Stackage Nightly | **Required — use directly** |
| PostgreSQL | `postgresql-replicant` v0.2.0.1 | Abandoned 2021 | **Not doing** (post-v1 if demand) |
| Redis | None | Not available | **Not doing** (post-v1 if demand) |
| Web APIs | Custom per-API | — | Build tooling; no universal library |

---

## Open Questions

See open-questions.md: OQ-019 (connector daemon architecture), OQ-020 (webhook endpoint security). OQ-017 and OQ-018 (PostgreSQL and Redis) are not doing for v1.
