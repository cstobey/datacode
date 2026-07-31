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

# Execute a single expression and exit (scriptable)
datacode --exec "app.commerce.Order where total > 100"

# Execute a schema definition file
datacode --file schema/initial.dc

# Connect to a specific shard directly (for DR purposes)
datacode --shard user.commerce --host shard2.example.com
```

## Interface Style

The CLI is a REPL with a prompt indicating the current namespace context. Everything typed is staged in a transaction until explicitly committed — nothing persists to the schema until `:commit`.

```
datacode[system]> :use app.commerce
datacode[app.commerce]> :describe Order
datacode[app.commerce]> :commit
datacode[app.commerce]> :rollback
datacode[app.commerce]> :help
```

The current namespace context is a convenience default for unqualified names. Fully-qualified names (`app.commerce.Order`) always work regardless of context.

**REPL meta-commands** (prefixed with `:`):

| Command | Effect |
|---|---|
| `:use <namespace>` | Set the current namespace context |
| `:describe <name>` | Show the definition of a table, trait, or type |
| `:history <name>` | Show the schema transaction graph for a table |
| `:commit` | Commit all staged changes to the schema |
| `:rollback` | Discard all staged changes |
| `:explain <expr>` | Show the functor chain and query plan for an expression |
| `:help` | Show available commands |

## DSL Categories

### Type and Trait Definitions

```
-- Domain types (colon means "is a kind of")
-- Note: { validate: ... } syntax is tentative
type Email  : Text    { validate: isValidEmail }
type Amount : Decimal { validate: \a -> a >= 0 }
type Zip    : Text    { validate: \z -> length z == 5 }

-- Custom absence types (used in outer joins)
type MissingCustomer : Null

-- Traits (abstract — cannot be instantiated directly)
trait Active {
  is_active : ActiveStatus | InactiveStatus

  active   self = self where is_active is ActiveStatus
  inactive self = self where is_active is InactiveStatus
}

-- Replication traits (built-in; user traits can extend them)
-- trait Reference     -- replicates to all servers
-- trait UserData      -- shard-local
-- trait LogData       -- prunable, server-local
-- trait Configuration -- all-server, operator-managed

trait Catalog : Reference {
  is_visible : Bool = True
}
```

### Table Definitions

Namespaces are implicit — just use them in table names.

```
-- Table with trait inheritance; DataId primary key is always implicit
table app.commerce.Customer : Active, UserData {
  email : Email unique
  name  : Text
  phone : Phone | NotGiven
}

-- FK field (arrow creates FK functor automatically)
-- Per-table default ordering declared inline
table app.commerce.Order : UserData {
  customer  : -> Customer
  placed_at : Timestamp
  total     : Amount
  status    : Pending | Processing | Shipped | Cancelled = Pending
  order by placed_at desc
}

-- Multi-field uniqueness constraint
table app.commerce.OrderLine : UserData {
  order   : -> Order
  product : -> Product
  qty     : Int
  price   : Amount
  unique lineRef { order, product }
}

-- Inline subtable (creates app.commerce.Address as sibling table)
table app.commerce.Customer {
  address : Address {
    street : Text
    city   : Text
    zip    : Zip
  }
}
```

### Constraints and Access Control

```
-- Inline in table body
table app.commerce.Order : UserData {
  customer  : -> Customer
  bill_addr : Address

  -- Path-equivalence constraint
  assert billingMatch { customer.billing_address == bill_addr }
  -- Access control: requesting user must match customer's owner
  assert access { user.id == customer.user_id }
}

-- Standalone (add after the fact)
assert app.commerce.Order.billingMatch { customer.billing_address == bill_addr }
assert app.commerce.Order.access { user.id == customer.user_id }
unique app.commerce.Order.lineRef { order, product }
```

### Schema Evolution

Redeclaring a table with the same name auto-hides the old type (still reachable via version tokens). Use `rename from` to disambiguate renames from add+remove.

```
-- Same-name redeclare: system diffs against last version
table app.commerce.Customer {
  account_status : AccountStatus rename from status  -- explicit rename
  loyalty_tier   : Tier = Bronze                     -- new field (default provided)
  -- phone omitted → automatically deprecated
}

-- Extend an existing sum type with a new variant
extend app.commerce.Customer.account_status with Archived

-- Deprecate and prune
deprecate app.commerce.Customer.phone   -- hide field; data stays in graph
deprecate app.commerce.OldCustomer      -- hide table; dependent views stay alive
prune app.commerce.OldCustomer          -- remove data (only valid once no live references)

-- Split one table into two
split app.commerce.Customer into {
  Person      { name : Text; birth_date : Date }
  ContactInfo { email : Email; phone : Phone | NotGiven }
}

-- Merge two tables into one
merge app.commerce.Person, app.commerce.ContactInfo into app.commerce.Customer {
  name       : Text
  birth_date : Date
  email      : Email
  phone      : Phone | NotGiven
}

-- Schema visibility
set visibility app.commerce.Order standard
set visibility connectors.mariadb.production.* connector
```

### Queries

```
-- Filter and project
app.commerce.Order
  where total > 100
  { customer.name as name, total }

-- With namespace context set (after :use app.commerce)
Order where status is Active

-- Natural join (FK-default path)
Order >< Customer
  where total > 100
  { customer.name as name, total as order_total }

-- Outer join: guard semantics — MissingCustomer (: Null) always matches
Order >< Customer | MissingCustomer

-- Chained outer join fallback
Order >< Customer | HistoricalCustomer | MissingCustomer

-- Explicit FK path when multiple FKs exist between two tables
Order >< Customer via customer

-- Grouping: non-grouped fields collapse into a nested table
Order
  group customer
  { customer, orders.total sum as total_spend }

-- Ordering override
Order order by total desc { customer, total }

-- Local binding
let activeOrders = Order where status is Active
activeOrders >< Customer { customer.name, total }

-- Pin query to a historical schema version
Order at "schema-txn-abc123" where total > 100

-- Inspect a materialized view
app.reporting.monthly_summary

-- Query plan
:explain Order >< Customer where total > 100
```

### Data Mutation

```
-- Insert
app.commerce.Order { customer: customerId, total: 99.99, status: Pending }

-- Functional update (returns new version; all functors re-evaluated)
Order where id = "uuid-..." { status: Shipped }

-- Soft delete (recorded in transaction log; data stays in graph)
delete Order where id = "uuid-..."

-- Hard delete (removes from active state; record remains in transaction graph)
delete! Order where id = "uuid-..."
```

### Functions

Top-level function definitions are global — committed to the schema when `:commit` is issued.

```
-- Global function (stored in schema)
isPositive a = a > 0
premiumFilter = Order where total > 1000

-- Import extra Haskell packages (admin allow-list controls availability)
import Data.Time (UTCTime, diffUTCTime)
import Data.Aeson (Value)
```

### System Administration

```
-- Server roles
show servers
show servers for shard user.commerce
elevate secondary shard2.example.com to primary for shard user.commerce
demote primary shard1.example.com to tertiary for shard user.commerce

-- Shards
show shards
describe shard user.commerce
split shard user.commerce at key "customer_id > uuid-..."

-- Connector management
show connectors
describe connector mariadb.production
add connector mariadb "production" {
  host: "db.example.com",
  port: 3306,
  user: "datacode_repl",
  password_env: "MARIADB_REPL_PASSWORD",
  latency_window_ms: 5000,
  authority_model: Symmetric
}
pause connector mariadb.production
resume connector mariadb.production
show connector conflicts mariadb.production [limit 20]
resolve conflict <conflict-id> using DataCode | External | merge { ... }

-- Token management
show tokens [type server | client | user]
issue client token for "MyApplication" scoped to app.commerce
revoke token <token-id>

-- Materialized views
show materialized views [shard user.commerce]
refresh view app.reporting.monthly_summary [at "schema-txn-abc123"]
drop materialized view app.reporting.monthly_summary

-- Transaction log inspection
show transactions [shard user.commerce] [since seq 1000] [limit 50]
show transaction <txn-id>

-- Schema history
:history app.commerce.Order [since "2026-01-01"] [limit 20]
```

### Disaster Recovery Commands

These commands are explicitly designed for DR scenarios where the IDE may be unavailable:

```
-- Force-elect a new primary (use only when you are certain the old primary is dead)
-- WARNING: split-brain will occur if the old primary recovers
force elect primary shard2.example.com for shard user.commerce

-- Verify shard integrity (compares transaction log checksums across all replicas)
verify shard user.commerce [deep]

-- Replay transactions from a known-good checkpoint
replay shard user.commerce from seq 5000 to seq 6000

-- Export shard state for manual inspection
export shard user.commerce to "/tmp/shard-export.json" [at seq 5000]

-- Import shard state (for rebuilding a shard from scratch)
import shard user.commerce from "/tmp/shard-export.json"

-- Check replication lag
show replication lag [for shard user.commerce]

-- Sync a tertiary server manually
force sync tertiary3.example.com for shard user.commerce
```

## Output Formats

```bash
# Default: aligned table output (like psql)
datacode[app.commerce]> Order where total > 100 { id, total } limit 3
 id                           | total
------------------------------+-------
 05KG3N0000...                | 99.99
 05KG3N0001...                | 149.50

# JSON output (for scripting)
datacode --format json --exec "Order where total > 100 { id, total }"

# CSV output
datacode --format csv --exec "Order where total > 100 { id, total }"

# Raw (for piping into other commands)
datacode --format raw --exec "show servers"
```

## Scripting

Schema definition files use the `.dc` extension (DataCode schema file). They are plain text DSL, one statement per logical block, with `--` comments. Files are idempotent — running them twice produces the same result (create-if-not-exists semantics by default).

```
-- Initial schema for the commerce application
-- Run with: datacode --file schema/commerce.dc

-- Note: { validate: ... } block syntax is tentative
type Email  : Text    { validate: isValidEmail }
type Amount : Decimal { validate: \a -> a >= 0 }

table app.commerce.Customer : UserData {
  email : Email unique
  name  : Text
}

table app.commerce.Order : UserData {
  customer  : -> Customer
  total     : Amount
  status    : Pending | Processing | Shipped | Cancelled = Pending
  order by placed_at desc

  assert access { user.id == customer.user_id }
}

table app.commerce.OrderLine : UserData {
  order   : -> Order
  product : -> Product
  qty     : Int
  unique lineRef { order, product }
}
```

## Relationship to the Admin IDE

The CLI and IDE share the same underlying query engine and schema machinery. Every action performable in the IDE is also expressible as a CLI command. The IDE is a graphical front-end built on top of the same DataCode query and mutation APIs that the CLI uses.

Once the IDE is built, its schema (tables for diagram layouts, sidebar state, theme configuration, etc.) is included in the initial system shard load. The IDE then becomes self-hosting — managing its own configuration through DataCode's normal table machinery.

For disaster recovery, operators should maintain a set of `.dc` script files that can reconstruct the schema and critical configuration from scratch using only the CLI. These scripts should be version-controlled alongside the application code.

## Implementation Notes

- The CLI is likely the **first deliverable** in the DataCode implementation sequence — it forces the core schema definition, query, and mutation APIs to be built before anything else
- The REPL can be implemented using `haskeline` (Haskell readline library) for editing, history, and tab completion
- Tab completion should complete namespace paths, table names, field names, trait names, and DSL keywords
- The REPL uses a transaction model: all changes are staged until `:commit`; `:rollback` discards them
- The CLI connects to DataCode via the same binary protocol as thick clients — it is itself a thick client
- In localhost mode, the server token is implicit; the CLI prompts for user credentials on first connect
