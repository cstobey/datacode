# Command-Line Interface (CLI)

## Purpose

The CLI is the **primary interface during development and disaster recovery**. It predates
the Admin IDE and remains essential even after the IDE exists, because:

- It works with no UI infrastructure — usable when the server is in a degraded state
- It is scriptable — schema definitions, migrations, and DR procedures can be automated as shell scripts
- It is the interface used during initial DataCode development before the IDE is built
- Disaster recovery procedures should always be expressible as CLI commands, independent of whether the IDE is functional

The CLI is to DataCode what `psql` is to PostgreSQL: not the preferred daily-use interface,
but the one that is always available and always trustworthy.

## Scope of This Document

This document covers the CLI *tool*: how to invoke it, the REPL model, and the
administrative and disaster-recovery commands that exist only here.

**It does not restate the schema language.** Type declarations, table definitions, traits,
constraints, evolution statements, queries, and mutations are all accepted verbatim at the
REPL prompt and in `.dc` files, and are documented in [schema/](schema/):

| For | See |
|---|---|
| Types, domain types, absence types | [schema/types.md](schema/types.md) |
| Tables, fields, foreign keys, sub-tables | [schema/tables.md](schema/tables.md) |
| Traits and replication policy | [schema/traits.md](schema/traits.md) |
| `assert`, path constraints, ACL | [schema/constraints.md](schema/constraints.md) |
| Redeclare, deprecate, split, merge | [schema/evolution.md](schema/evolution.md) |
| Queries, joins, views, mutation | [schema/queries.md](schema/queries.md) |
| Function definitions and imports | [schema/functions.md](schema/functions.md) |
| Full EBNF, including every command below | [schema/railroad.md](schema/railroad.md) |

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

The CLI is a REPL with a prompt indicating the current namespace context. Everything typed
is staged in a transaction until explicitly committed — nothing persists to the schema until
`:commit`.

```
datacode[system]> :use app.commerce
datacode[app.commerce]> :describe Order
datacode[app.commerce]> :commit
datacode[app.commerce]> :rollback
datacode[app.commerce]> :help
```

The current namespace context is a convenience default for unqualified names.
Fully-qualified names (`app.commerce.Order`) always work regardless of context.

### REPL Meta-Commands

Prefixed with `:` to distinguish them from schema and query input.

| Command | Effect |
|---|---|
| `:use <namespace>` | Set the current namespace context |
| `:describe <name>` | Show the definition of a table, trait, or type |
| `:history <name>` | Show the schema transaction graph for a table |
| `:commit` | Commit all staged changes to the schema |
| `:rollback` | Discard all staged changes |
| `:explain <expr>` | Show the functor chain and query plan for an expression |
| `:help` | Show available commands |

```
:history app.commerce.Order since "2026-01-01" limit 20
:explain Order >< Customer where total > 100
```

### Transaction Model

All input is staged until `:commit`. This prevents accidental schema changes from
exploratory queries. `:rollback` discards the staging area. The same model underlies
`--file` execution: a `.dc` file commits as a single transaction unless it contains explicit
`:commit` statements.

## System Administration

These commands exist only in the CLI and the IDE — they are not part of the schema language.

### Servers

```
show servers
show servers for shard user.commerce
elevate secondary shard2.example.com to primary for shard user.commerce
demote primary shard1.example.com to tertiary for shard user.commerce
```

See [distribution.md](distribution.md) for the server role model.

### Shards

```
show shards
describe shard user.commerce
split shard user.commerce at key "customer_id > uuid-..."
```

Note the `shard` keyword. `split shard <name> at key ...` is a physical operation. Splitting a
*table* is a set of bindings and has no dedicated statement — see
[schema/evolution.md](schema/evolution.md#split-and-merge-a-table).

`describe shard` reports the shard's extents and, for a `LogData` shard, the
`system.shards.LogSegment` row that roots it. Splitting is not uniformly manual: an extent
filling and a log segment sealing are automatic and invisible, and only a `UserData` split
waits for `split shard … at key`
(see [distribution.md](distribution.md#three-thresholds-three-behaviours)).

There is no command for extent sizing or the segment period. Those are `Configuration` rows,
so tuning them is an ordinary mutation, staged and committed like any other — the same
self-hosting principle that keeps violation waivers out of the admin grammar:

```
system.shards.ExtentPolicy { table_path = "system.logs.HttpRequest", extent_size = 268435456 }
```

### Connectors

```
show connectors
describe connector mariadb.production
add connector mariadb "production" {
  host              = "db.example.com",
  port              = 3306,
  user              = "datacode_repl",
  password_env      = "MARIADB_REPL_PASSWORD",
  latency_window_ms = 5000,
  authority_model   = Symmetric
}
pause connector mariadb.production
resume connector mariadb.production
show connector conflicts mariadb.production limit 20
resolve conflict <conflict-id> using DataCode | External | merge { ... }
```

See [connectors.md](connectors.md).

### Tokens

```
show tokens type server | client | user
issue client token for "MyApplication" scoped to app.commerce
revoke token <token-id>
```

See [auth.md](auth.md).

### Grants

```
show   grants for app.commerce
grant  system.auth.Role.Admin on app.pm bypass access
revoke grant system.auth.Role.Admin on app.pm
```

A grant is a row in `system.auth.Grant`; these commands write it. `bypass access` exempts the
grant from every `assert` that mentions `authed_user` and from nothing else — data
constraints still run. See [namespaces.md](namespaces.md#bypass).

### Materialized Views

```
show materialized views shard user.commerce
materialize app.reporting.MonthlySummary
refresh view app.reporting.MonthlySummary at "schema-txn-abc123"
drop materialized view app.reporting.MonthlySummary
```

The system proposes and maintains materialized views on its own, from observed query load. These
commands inspect and override that. `materialize` pins one that the system has not chosen; `drop`
removes one it has. See [storage.md](storage.md#materialization).

### Transaction Log Inspection

```
show transactions shard user.commerce since seq 1000 limit 50
show transaction <txn-id>
```

See [transaction-graph.md](transaction-graph.md).

### Integrity

```
show violations
show violations for app.auth.User.username / minLen12 limit 50
show violations shard user.commerce
```

This is the only integrity command with dedicated syntax, and it exists for the degraded
case where the query engine is all that is working. Everything else — waiving a violation,
acknowledging one, raising one by hand — is an ordinary mutation against
`system.integrity.Violation`, because it is an ordinary table:

```
system.integrity.Violation where id == "05KG..." { state = Waived "legacy import, TICKET-4471" }
```

Enforcement modes are schema statements, not admin commands, so they are typed at the REPL
like any other declaration and are staged until `:commit`:

```
enforce app.auth.User.username / minLen12 forward
monitor app.commerce.Order.billingMatch
```

See [integrity.md](integrity.md).

## Disaster Recovery Commands

These commands are explicitly designed for DR scenarios where the IDE may be unavailable:

```
-- Force-elect a new primary (use only when you are certain the old primary is dead)
-- WARNING: split-brain will occur if the old primary recovers
force elect primary shard2.example.com for shard user.commerce

-- Verify shard integrity (compares transaction log checksums across all replicas)
verify shard user.commerce deep

-- Replay transactions from a known-good checkpoint
replay shard user.commerce from seq 5000 to seq 6000

-- Export shard state for manual inspection
export shard user.commerce to "/tmp/shard-export.json" at seq 5000

-- Import shard state (for rebuilding a shard from scratch)
import shard user.commerce from "/tmp/shard-export.json"

-- Check replication lag
show replication lag for shard user.commerce

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

Schema definition files use the `.dc` extension (DataCode schema file). They are plain text
DSL with `--` comments. Top-level declarations need no terminator — one ends where the next
begins, at column 0. Files are idempotent — running them twice produces the same result
(create-if-not-exists semantics by default).

```
-- Initial schema for the commerce application
-- Run with: datacode --file schema/commerce.dc

type Email  : Text    where isValidEmail
type Amount : Decimal where \a -> a >= 0

table app.commerce.Customer : UserData {
  email : Email unique,
  name  : Text,
  user  :> system.auth.User
}

table app.commerce.Order : UserData {
  customer  :> Customer,
  order_num : Int,
  total     : Amount,
  status    : Pending | Processing | Shipped | Cancelled = Pending,
  unique orderRef { customer, order_num },
  order by placed_at desc,

  assert ownerAccess { authed_user == customer.user }
}

table app.commerce.OrderLine : UserData {
  order   :> Order,
  product :> Product,
  qty     : Int,
  unique lineRef { order, product }
}
```

Statement syntax is defined in [schema/](schema/); this example exists only to show the file
shape. For DR, maintain a set of `.dc` scripts that can reconstruct the schema and critical
configuration from scratch using only the CLI, version-controlled alongside the application
code.

## Relationship to the Admin IDE

The CLI and IDE share the same underlying query engine and schema machinery. Every action
performable in the IDE is also expressible as a CLI command. The IDE is a graphical
front-end built on top of the same DataCode query and mutation APIs that the CLI uses.

Once the IDE is built, its schema (tables for diagram layouts, sidebar state, theme
configuration, etc.) is included in the initial system shard load. The IDE then becomes
self-hosting — managing its own configuration through DataCode's normal table machinery. See
[ide.md](ide.md).

## Implementation Notes

- The CLI is likely the **first deliverable** in the DataCode implementation sequence — it forces the core schema definition, query, and mutation APIs to be built before anything else
- The REPL can be implemented using `haskeline` (Haskell readline library) for editing, history, and tab completion
- Tab completion should complete namespace paths, table names, field names, trait names, and DSL keywords
- The REPL uses a transaction model: all changes are staged until `:commit`; `:rollback` discards them
- The CLI connects to DataCode via the same binary protocol as thick clients — it is itself a thick client
- In localhost mode, the server token is implicit; the CLI prompts for user credentials on first connect
