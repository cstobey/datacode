# Command-Line Interface (CLI)

## Purpose

The CLI is the **primary interface during development and disaster recovery**. It predates the Admin IDE and remains essential even after the IDE exists, because:

- It works with no UI infrastructure — usable when the server is in a degraded state
- It is scriptable — schema definitions, migrations, and DR procedures can be automated as shell scripts
- It is the interface used during initial DataCode development before the IDE is built
- Disaster recovery procedures should always be expressible as CLI commands, independent of whether the IDE is functional

The CLI is to DataCode what `psql` is to PostgreSQL: not the preferred daily-use interface, but the one that is always available and always trustworthy.

## Invocation

```bash
# Connect to a local DataCode instance (server token implicit from localhost)
datacode

# Connect to a remote instance with explicit credentials
datacode --host db.example.com --port 7432 --client-token <token> --user-token <token>

# Execute a single command and exit (scriptable)
datacode --exec "DESCRIBE TABLE app.commerce.orders"

# Execute a script file
datacode --file schema/initial.dc

# Connect to a specific shard directly (for DR purposes)
datacode --shard user.commerce --host shard2.example.com
```

## Interface Style

The CLI is a REPL with a prompt indicating the current namespace context:

```
datacode[system]> USE NAMESPACE app.commerce
datacode[app.commerce]> DESCRIBE TABLE orders
datacode[app.commerce]> 
```

The current namespace context is a convenience default for unqualified names. Fully-qualified names (`app.commerce.orders`) always work regardless of context.

## Command Categories

### Schema Definition

```
-- Create a namespace
CREATE NAMESPACE app.commerce

-- Define a table
CREATE TABLE app.commerce.orders {
  id          : UUID       [primary_key]
  customer_id : -> app.commerce.customers
  total       : Amount
  status      : OrderStatus
}

-- Define a view (with all selector — see Schema DSL docs)
CREATE VIEW app.commerce.order_summary {
  * FROM connectors.mariadb.production.orders   -- wildcard: tracks source schema
  status : OrderStatus                           -- explicit override
}

-- Add a functor to an existing table
ADD FUNCTOR PositiveAmount ON app.commerce.orders.total
  VALIDATE amount > 0
  ERROR "Order total must be positive"

-- Add a path equivalence constraint
ADD CONSTRAINT BillingAddrEquiv ON app.commerce.orders
  ASSERT orders.customer_id -> customers.billing_address
      == orders.billing_address

-- Alter visibility
SET VISIBILITY app.commerce.orders STANDARD
SET VISIBILITY connectors.mariadb.production.* CONNECTOR

-- Show the schema transaction graph for a table
SHOW HISTORY app.commerce.orders [SINCE "2026-01-01"] [LIMIT 20]
```

### Query

```
-- Basic select
SELECT id, total, status FROM app.commerce.orders WHERE total > 100

-- With namespace context set:
SELECT id, total FROM orders WHERE status = Active()

-- Outer join (returns NOT_FOUND for unmatched)
SELECT o.id, c.email FROM orders o LEFT JOIN customers c ON o.customer_id = c.id

-- Pin query to a historical schema version
SELECT * FROM app.commerce.orders AT SCHEMA "schema-txn-abc123"

-- Inspect a materialized view
SELECT * FROM VIEW app.reporting.monthly_summary

-- Explain (show the functor chain and query plan)
EXPLAIN SELECT * FROM orders WHERE total > 100
```

### Data Mutation

```
-- Insert
INSERT INTO app.commerce.orders { customer_id: "uuid-...", total: Amount(99.99), status: Active() }

-- Update (DataCode uses functional update — returns new version)
UPDATE app.commerce.orders SET status = Shipped() WHERE id = "uuid-..."

-- Delete (soft delete by default — recorded in transaction log)
DELETE FROM app.commerce.orders WHERE id = "uuid-..."

-- Hard delete (removes from active state; record remains in transaction graph)
DELETE HARD FROM app.commerce.orders WHERE id = "uuid-..."
```

### System Administration

```
-- Server roles
SHOW SERVERS
SHOW SERVERS FOR SHARD user.commerce
ELEVATE SECONDARY shard2.example.com TO PRIMARY FOR SHARD user.commerce
DEMOTE PRIMARY shard1.example.com TO TERTIARY FOR SHARD user.commerce

-- Shards
SHOW SHARDS
DESCRIBE SHARD user.commerce
SPLIT SHARD user.commerce AT KEY "customer_id > uuid-..."

-- Connector management
SHOW CONNECTORS
DESCRIBE CONNECTOR mariadb.production
ADD CONNECTOR mariadb "production" {
  host: "db.example.com",
  port: 3306,
  user: "datacode_repl",
  password_env: "MARIADB_REPL_PASSWORD",
  latency_window_ms: 5000,
  authority_model: Symmetric
}
PAUSE CONNECTOR mariadb.production
RESUME CONNECTOR mariadb.production
SHOW CONNECTOR CONFLICTS mariadb.production [LIMIT 20]
RESOLVE CONFLICT <conflict-id> USING DataCode | External | MERGE { ... }

-- Token management
SHOW TOKENS [TYPE server | client | user]
ISSUE CLIENT TOKEN FOR "MyApplication" SCOPED TO app.commerce
REVOKE TOKEN <token-id>

-- Materialized views
SHOW MATERIALIZED VIEWS [SHARD user.commerce]
REFRESH VIEW app.reporting.monthly_summary [AT SCHEMA "schema-txn-abc123"]
DROP MATERIALIZED VIEW app.reporting.monthly_summary

-- Transaction log inspection
SHOW TRANSACTIONS [SHARD user.commerce] [SINCE seq 1000] [LIMIT 50]
SHOW TRANSACTION <txn-id>
```

### Disaster Recovery Commands

These commands are explicitly designed for DR scenarios where the IDE may be unavailable:

```
-- Force-elect a new primary (use when primary is unresponsive)
FORCE ELECT PRIMARY shard2.example.com FOR SHARD user.commerce
  -- WARNING: run this only when you are certain the old primary is dead.
  -- Split-brain will occur if the old primary recovers.

-- Verify shard integrity
VERIFY SHARD user.commerce [DEEP]
  -- Compares transaction log checksums across all replicas

-- Replay transactions from a known-good checkpoint
REPLAY SHARD user.commerce FROM SEQ 5000 TO SEQ 6000

-- Export shard state for manual inspection
EXPORT SHARD user.commerce TO "/tmp/shard-export.json" [AT SEQ 5000]

-- Import shard state (for rebuilding a shard from scratch)
IMPORT SHARD user.commerce FROM "/tmp/shard-export.json"

-- Check replication lag
SHOW REPLICATION LAG [FOR SHARD user.commerce]

-- Sync a tertiary server manually
FORCE SYNC tertiary3.example.com FOR SHARD user.commerce
```

## Output Formats

```bash
# Default: aligned table output (like psql)
datacode> SELECT id, total FROM orders LIMIT 3
 id                                   | total
--------------------------------------+-------
 550e8400-e29b-41d4-a716-446655440000 | 99.99
 6ba7b810-9dad-11d1-80b4-00c04fd430c8 | 149.50

# JSON output (for scripting)
datacode --format json --exec "SELECT id, total FROM orders LIMIT 3"

# CSV output
datacode --format csv --exec "SELECT id, total FROM orders LIMIT 3"

# Raw (for piping into other commands)
datacode --format raw --exec "SHOW SERVERS"
```

## Scripting

Schema definition files use the `.dc` extension (DataCode schema file). They are plain text with CLI commands, one per line, with `--` comments:

```
-- Initial schema for the commerce application
-- Run with: datacode --file schema/commerce.dc

CREATE NAMESPACE app.commerce

CREATE TABLE app.commerce.customers {
  id    : UUID  [primary_key]
  email : Email
  name  : Text
}

CREATE TABLE app.commerce.orders {
  id          : UUID  [primary_key]
  customer_id : -> app.commerce.customers
  total       : Amount
  status      : OrderStatus
}

ADD FUNCTOR PositiveAmount ON app.commerce.orders.total
  VALIDATE amount > 0
  ERROR "Order total must be positive"
```

Schema files are idempotent — running them twice produces the same result (CREATE IF NOT EXISTS semantics by default).

## Relationship to the Admin IDE

The CLI and IDE share the same underlying query engine and schema machinery. Every action performable in the IDE is also expressible as a CLI command. The IDE is a graphical front-end built on top of the same DataCode query and mutation APIs that the CLI uses.

Once the IDE is built, its schema (tables for diagram layouts, sidebar state, theme configuration, etc.) is included in the initial system shard load. The IDE then becomes self-hosting — managing its own configuration through DataCode's normal table machinery.

For disaster recovery, operators should maintain a set of `.dc` script files that can reconstruct the schema and critical configuration from scratch using only the CLI. These scripts should be version-controlled alongside the application code.

## Implementation Notes

- The CLI is likely the **first deliverable** in the DataCode implementation sequence — it forces the core schema definition, query, and mutation APIs to be built before anything else
- The REPL can be implemented using `haskeline` (Haskell readline library) for editing, history, and tab completion
- Tab completion should complete namespace paths, table names, field names, and command keywords
- The CLI connects to DataCode via the same binary protocol as thick clients — it is itself a thick client
- In localhost mode, the server token is implicit; the CLI prompts for user credentials on first connect
