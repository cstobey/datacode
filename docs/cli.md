# Command-line interface (CLI)

## Purpose

The CLI is the **primary interface during development and disaster recovery**. It predates
the Admin IDE and remains essential even after the IDE exists, because:

- It works with no UI infrastructure — usable when the server is in a degraded state
- It is scriptable — schema definitions, migrations, and DR procedures can be automated as shell scripts
- It is the interface used during initial DataCode development before the IDE is built
- Disaster recovery procedures should always be expressible as CLI commands, independent of whether the IDE is functional

The CLI is to DataCode what `psql` is to PostgreSQL: not the preferred daily-use interface,
but the one that is always available and always trustworthy.

## Scope of this document

This document covers the CLI *tool*: how to invoke it, the REPL model, and the
administrative and disaster-recovery commands that exist only here.

**It does not restate the schema language.** Type declarations, table definitions, traits,
constraints, evolution statements, queries, and mutations are all accepted verbatim at the
REPL prompt and in `.dc` scripts, and are documented in [schema/](schema/):

| For | See |
|---|---|
| Types, domain types, absence types | [schema/types.md](schema/types.md) |
| Tables, fields, foreign keys, sub-tables | [schema/tables.md](schema/tables.md) |
| Traits and replication policy | [schema/traits.md](schema/traits.md) |
| `assert`, path constraints, ACL | [schema/constraints.md](schema/constraints.md) |
| Redeclare, deprecate, prune, split and merge a table | [schema/evolution.md](schema/evolution.md) |
| Queries, derived tables, `limit`, mutation | [schema/queries.md](schema/queries.md) |
| Function definitions and imports | [schema/functions.md](schema/functions.md) |
| Full EBNF, including every command below | [schema/railroad.md](schema/railroad.md) |

Syntax shown here is illustrative. Where an example and the EBNF disagree, the EBNF is right.

## Invocation

```bash
# Connect to a local DataCode instance
datacode

# Connect to a remote instance with explicit credentials
datacode --host "db.example.com" --port 7432 --client-token <token> --user-token <token>

# Execute a single expression and exit (scriptable)
datacode --exec "app.commerce.Order where total > 100"

# Execute a schema and configuration script
datacode --file schema/initial.dc

# Connect to one shard family, or to one concrete shard (for DR purposes)
datacode --shard user.commerce --host "shard2.example.com"
datacode --shard 'user.commerce/"05KG3N0000ZQ8V4T1H7C"'

# Page every report in this session at 500 rows
datacode --limit 500
```

**Quote a hostname.** `--host` takes a `Value`, and a dotted or hyphenated name is not an
`Ident`. The `Host` positions inside a command (`elevate`, `demote`, `force sync`,
`show queries on`) accept the unquoted dotted form as well.

**Single-quote a concrete shard reference** in the shell. The inner double quotes are part of
the `ShardRef`, not shell syntax — see [Shards](#shards) for the three spellings. `--limit` sets
the page size for the session and is overridden by an explicit `limit` on a statement; see
[Paging and the truncation footer](#paging-and-the-truncation-footer).

**On localhost the CLI still holds a client token.** It is issued against a
`system.auth.Registration` created at install time, and the CLI prompts for user credentials on
first connect. There is no server-token mode for a human operator: access is the intersection of
the client's schema-level reach with the user's row-level reach, and a credential that skips the
first half defeats the intersection. See [auth.md](auth.md#token-types).

## Interface style

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

### REPL meta-commands

Prefixed with `:` to distinguish them from schema and query input.

| Command | Effect |
|---|---|
| `:use <namespace>` | Set the current namespace context |
| `:describe <name> [deep]` | Show the definition of a table, trait, or type; `deep` follows containment edges — inline sub-tables and `:<` children |
| `:history <name> [since "<moment>"] [limit <n>]` | Show the schema transaction graph for a table |
| `:commit` | Commit all staged changes to the schema |
| `:rollback` | Discard all staged changes |
| `:explain <query>` | Show the functor chain and query plan for a query |
| `:help` | Show available commands, including the compiled-in page-size default |

```
:history app.commerce.Order since "2026-01-01" limit 20
:describe app.commerce.Order deep
:explain Order >< Customer where total > 100
```

### Transaction model

All input is staged until `:commit`. This prevents accidental schema changes from
exploratory queries. `:rollback` discards the staging area. The same model underlies
`--file` execution: a script commits as a single transaction unless it contains explicit
`:commit` statements. See [Scripting](#scripting).

## System administration

These commands exist only in the CLI and the IDE — they are not part of the schema language.

**Every `show` takes the same report clauses**: `where`, `order by`, `limit`, and a projection.
Filtering and paging are therefore uniform, and no command carries a bespoke `limit` tail:

```
show shards user.commerce where bytes > 1000000000 order by bytes desc limit 20
show shards user.commerce { family, primary, epoch, bytes }
show violations for app.auth.User.username / minLen12 where state is Open limit 50
```

`at`, `diff`, `group` and `><` are deliberately excluded. They would make a degraded server run
joins and resolve historical version tokens, which is the work the degraded path exists to
avoid. The full clause list is in
[schema/railroad.md](schema/railroad.md#administration).

**The degraded path still evaluates access asserts.** What `show` skips is the planner, the
distributed merge, and materialized views — never authorization.

### What a `show` reads

`show` exists for two reasons: the state that is deliberately not rows, and the degraded case
where the query engine is all that is working. Everywhere else it is an alias for a query, and
the query is the better tool once the cluster is healthy.

| `show` target | Reads |
|---|---|
| `servers` | `system.shards.Node` |
| `shards` | `system.shards.RoleDefault` and `system.shards.RoleRange`, resolved against the family's root rows |
| `connectors`, `connector conflicts` | the `system.connectors` tables |
| `tokens` | the `system.auth` token tables |
| `grants` | `system.auth.Grant` |
| `materialized views` | the materialization registry ([storage.md](storage.md#materialization)) |
| `transactions`, `transaction` | `system.graph.Transaction` |
| `violations` | `system.integrity.Violation` |
| `queries` | **nothing** — running queries are per-server state, rendered from memory |
| `replication lag` | **nothing** — per-server observed state |

The physical columns of `show shards` — byte counts, extent counts — are not rows either.
`PhysicalLocator` and the shard index are server-local and never appear in a replication
message or an API response
([transaction-graph.md](transaction-graph.md#physical-locators)).

A report that merges contributions from several servers names which servers answered, so a
partial result is never mistaken for a complete one.

### Servers

```
show servers
show servers for shard user.commerce
show replication lag for shard user.commerce
elevate secondary shard2.example.com to primary for shard user.commerce
demote primary shard1.example.com to tertiary for shard user.commerce
```

**Elevation is automatic**: a shard whose primary stops answering promotes a secondary on its
own. `elevate` and `demote` are for moving authority *back*, which stays an operator act —
elevation restores availability, failback only rebalances. See
[distribution.md](distribution.md#elevation-is-automatic-failback-is-not) for the server role
model and the epoch fencing that makes promotion safe.

### Shards

```
show shards
show shards user.commerce
show shards user.commerce from "a@example.com" to "m@example.com" order by bytes desc limit 20
describe shard user.commerce/"05KG3N0000ZQ8V4T1H7C"
split shard user.commerce at key "m@example.com"
```

**A shard is rooted at a row, so a name alone is ambiguous.** `ShardRef` has three spellings:

| Spelling | Denotes |
|---|---|
| `user.commerce` | the shard **family** — which tables participate |
| `user.commerce/"05KG3N0000ZQ8V4T1H7C"` | one **concrete** shard, named by its root row's `DataId` |
| `user.commerce from "a@example.com" to "m@example.com"` | every shard whose placement interval intersects `["a@example.com", "m@example.com")` |

Ranges are half-open, lower-inclusive. Bounds are values of the family's placement key — the
root table's candidate key for `UserData`, the segment boundary for `LogData`, `DataId` as a
last resort — and a composite key is written as a record literal,
`from { region = "EU", name = "acme" }`. `describe shard`, `show transactions`, `replay`,
`export shard`, and `import shard` take the concrete form only: `seq` is a per-shard sequence
space and a dump is one file.

Unqualified `show shards` reports families and ranges rather than individual shards. Under
row-rooting a family is one shard per root row, so the unqualified listing would otherwise be a
row per customer.

`split shard <ref> at key <value>` takes a **boundary value, not a predicate**. The partition
function is total and a cut splits its domain at one point, so a comparison has nothing to say
there; a stringly-typed predicate would be neither checkable nor typeable. The last resort is a
`DataId` boundary, `split shard user.crm at key "05KG3N0000ZQ8V4T1H7C"`.

Note the `shard` keyword. Splitting a *table* is a set of bindings and has no dedicated
statement — `split` and `merge` over tables were once statements and were withdrawn, because the
derived-key rules check losslessness where the statements could only assert it. See
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
  poll_interval  = 10 second,
  latency_window = 5 second,
  authority      = Symmetric
}
pause connector mariadb.production
resume connector mariadb.production
show connector conflicts mariadb.production limit 20
resolve conflict "05KG3N0002QP7H5J3K8M" using DataCode
resolve conflict "05KG3N0002QP7H5J3K8M" using merge { total = 149.50 }
```

`add connector` is ordinary row construction: the identifier names the connector kind, the
string literal names the instance, and the record supplies the remaining fields of the
`system.connectors.Connector` row. Every field in it must be declared there, so the field list —
including the connection endpoint and how credentials are supplied — has one home. See
[connectors.md](connectors.md).

`DataCode` and `External` in `resolve conflict … using` are ordinary variant names, not reserved
words. Reserving them would have made `authority : DataCode | External | Symmetric` — the field
whose values they are — unlexable.

### Running queries

```
show queries
show queries on db4.example.com limit 20
cancel "05KG3N0000ZQ8V4T1H7C"
cancel "05KG3N0004MM1P8B2D9F" reason "nightly ETL, rerun off-peak"
```

```
datacode[system]> show queries limit 5

 handle               | user      | source                    | elapsed | shards | state
----------------------+-----------+---------------------------+---------+--------+------------
 05KG3N0000ZQ8V4T1H7C | analytics | app.commerce.Order        | 14m 22s |     47 | Running
 05KG3N0004MM1P8B2D9F | analytics | app.crm.Contact           |  9m 03s |     47 | Running
 05KG3N0007TT4R2Y6K1J | bwhite    | app.reporting.MonthlyRoll |     41s |      3 | Merging

 contributed by: db1, db2, db4, db7   (db3 unreachable)
```

- **The handle is the query's own `DataId`**, and its server bytes name the coordinating server.
  `cancel` is therefore one point-to-point message and takes no host.
- **`cancel` reaches reads only.** A long-running *write* is a queue row, stopped by advancing
  its `QueueState` ([events.md](events.md#queue-state)).
- **A cancelled query returns an error, never a partial result.** A truncated analytical answer
  mistaken for a complete one is the failure the contributor footer also exists to prevent.
- **`reason` is optional**, and expected when cancelling somebody else's query.
- **`Ctrl-C` at the REPL sends `cancel`** for the in-flight handle rather than dropping the
  connection.

Filtering beyond `limit` and `on <host>` is the query language's job once the running-query
registry is queryable; until then, script it with `--format raw` and pipe into `cancel`.

### Tokens

```
show tokens
show tokens type client
issue client token for "MyApplication" scoped to app.commerce
revoke token "05KG3N0003NN6K2P9Q1R"
```

There is no `server` token type. A server is a `Client` kind that cannot be narrowed, so its
credential is an ordinary client token, and two names for one thing is what the
`Client`/`Registration` split removed. See [auth.md](auth.md#token-types).

### Grants

```
show   grants for app.commerce
grant  system.auth.Role.Admin on app.pm bypass access
grant  system.auth.Role.Auditor on app.crm bypass erasure
revoke grant system.auth.Role.Admin on app.pm
```

A grant is a row in `system.auth.Grant`; these commands write it. `bypass access` exempts the
grant from asserts that mention `authed_user`; `bypass erasure` lets a token read the history of
an erased row. Both are narrow, and what each does *not* cover is stated at
[namespaces.md](namespaces.md#bypass) and
[integrity.md](integrity.md#erasure-restricts-scrub-destroys).

### Erasure and scrubbing

```
erase   app.crm.Contact "05KG3N0001BB2M9X4E7Q" reason "DSR-2291"
erase   shard user.crm/"05KG3N0001BB2M9X4E7Q"  reason "DSR-2291"
scrub   app.log.Request.body at seq 84210 reason "credential in payload"
release unique app.crm.Contact.email "a@example.com" reason "DSR-2291"
```

These are the only three operations that remove anything, and none is reachable from the query
language. `erase` closes a row's history and requires the table to carry
[`Personal`](schema/traits.md#personal); `scrub` destroys bytes; `release` frees a reserved
`unique` value whose row is already deleted or erased, and is rejected on a placement key
([distribution.md](distribution.md#a-reserved-value-is-released-only-deliberately)). `reason` is
mandatory on every form, and each writes a graph node recording the target, the authority, and
the reason. What erasure restricts and what scrub destroys are in
[integrity.md](integrity.md#erasure-restricts-scrub-destroys).

There is no `row` marker: `erase <table> <id>` is unambiguous without one because `shard` is
reserved, and `row` is the likeliest identifier in any schema.

Automatic scrubbing needs no command. It is driven by `system.crypto.ScrubRule`, an ordinary
`Configuration` table — see [integrity.md](integrity.md#scrub-rules-are-configuration).

These belong in the admin web interface as well, and will be added there. They are CLI-only for
now because the CLI exists and the admin interface does not.

### Export

```
export app.commerce.Order where placed_at > "2026-01-01" to archive "orders-2026.jsonl" as jsonl
export app.crm.Contact where id == "05KG3N0001BB2M9X4E7Q" to archive "dsr-2291.json"
  reason "DSR-2291"
```

`export` writes a query's result outside the system, and the containment is the point:

- The identifier names a `system.export.Destination` row and the string is relative to that
  row's `root`. A `..` segment, an absolute prefix, or a symlink resolving outside `root` is
  rejected. **Default deny** — no destination row, no export.
- `reason` is mandatory where the source carries `Personal`.
- A `Secret` column serializes as `Sealed` in every format.
- Formats are `json`, `jsonl`, `csv`, and `tsv`. The `export shard` form under
  [Disaster recovery commands](#disaster-recovery-commands) takes the same destination pair, so
  a DR dump gets the same containment and the same audit trail.

### Materialized views

```
show materialized views shard user.commerce
materialize app.reporting.MonthlySummary
refresh view app.reporting.MonthlySummary at "05KG3N0000ZQ8V4T1H7C"
drop materialized view app.reporting.MonthlySummary
```

The system proposes and maintains materialized views on its own, from observed query load. These
commands inspect and override that. `materialize` pins one that the system has not chosen; `drop`
removes one it has. `refresh view … at` re-pegs a view to a named commit node. See
[storage.md](storage.md#materialization).

### Transaction log inspection

```
show transactions shard user.commerce/"05KG3N0000ZQ8V4T1H7C" since seq 1000 limit 50
show transaction "05KG3N0000ZQ8V4T1H7C"
```

Both read `system.graph.Transaction` and take a grant like any other read — the graph is data,
so a node is a row. `show transaction` renders that row: its parents, the mutations it carried,
and any re-key record annotating them. See
[transaction-graph.md](transaction-graph.md#systemgraphtransaction).

### Integrity

```
show violations
show violations for app.auth.User.username / minLen12 limit 50
show violations shard user.commerce
```

This is the only integrity command with dedicated syntax, and it exists for the degraded
case where the query engine is all that is working. Everything else — waiving a violation,
acknowledging one, raising one by hand — is an ordinary mutation against
`system.integrity.Violation`, because it is an ordinary table. The worked mutations are in
[integrity.md](integrity.md#reporting-and-administration).

Enforcement modes are schema statements, not admin commands, so they are typed at the REPL
like any other declaration and are staged until `:commit`:

```
enforce app.auth.User.username / minLen12 forward
monitor app.commerce.Order.billingMatch
```

See [integrity.md](integrity.md).

## Disaster recovery commands

These commands are explicitly designed for DR scenarios where the IDE may be unavailable:

```
-- Force-elect a new primary (use only when you are certain the old primary is dead)
-- WARNING: split-brain will occur if the old primary recovers
force elect primary shard2.example.com for shard user.commerce/"05KG3N0000ZQ8V4T1H7C"

-- Verify shard integrity (compares transaction log checksums across all replicas)
verify shard user.commerce deep

-- Replay transactions from a known-good checkpoint
replay shard user.commerce/"05KG3N0000ZQ8V4T1H7C" from seq 5000 to seq 6000

-- Export shard state for manual inspection
export shard user.commerce/"05KG3N0000ZQ8V4T1H7C" to archive "commerce-5000.frames" at seq 5000

-- Import shard state (for rebuilding a shard from scratch)
import shard user.commerce/"05KG3N0000ZQ8V4T1H7C" from archive "commerce-5000.frames"

-- Check replication lag
show replication lag for shard user.commerce

-- Sync a tertiary server manually
force sync tertiary3.example.com for shard user.commerce
```

`force elect` is the override for automatic elevation, not the ordinary path — see
[Servers](#servers).

**A shard dump is opaque.** It carries the shard's transaction frames as they sit on disk
([storage.md](storage.md#wire-format-for-replication)), so the file extension is conventional
and the bytes are not a text format. Stored bytes round-trip, which means a `Hashed`, `Secret`,
or `Encrypted` column restores in its stored form; an `Encrypted` column is readable after the
restore only where its wrapping key is still available
([auth.md](auth.md#envelope-encryption-and-key-custody)).

**`import shard` re-applies every scrub node at or before the restore point before the shard
comes online.** The wait is visible and can be long; the shard not coming online immediately is
the rule working, not the import failing. Without it a re-imported dump would be the path by
which scrubbed data returns — see
[integrity.md](integrity.md#replication-and-restore).

## Output formats

The default is aligned table output, like `psql`:

```
datacode[app.commerce]> Order where total > 100 { id, total } limit 3
 id                   | total
----------------------+--------
 05KG3N0000ZQ8V4T1H7C |  99.99
 05KG3N0004MM1P8B2D9F | 149.50
```

```bash
# JSON output (for scripting)
datacode --format json --exec "Order where total > 100 { id, total }"

# CSV output
datacode --format csv --exec "Order where total > 100 { id, total }"

# Raw (for piping into other commands)
datacode --format raw --exec "show servers"
```

### Paging and the truncation footer

A statement with no explicit `limit` is capped at `system.config.PageSize`, a `Configuration`
row resolved most-specific-first over the dotted path. With no matching row the cap is **100**,
compiled in and reported by `:help`. Narrowest wins:

> explicit `limit N` → `--limit N` for the session → the `system.config.PageSize` row → 100

A truncated result reports `100 of 100+`. The `+` comes from fetching `limit + 1` rows and
discarding the extra: exact for the only bit a caller can act on, one row of cost, and no
query-language feature. Where an exact total is wanted it is a second query —
`count (Order where total > 100)` — because an exact footer would mean running the whole query,
which is the cost `limit` exists to avoid.

| Format | Cap applies | Truncation signalled by |
|---|---|---|
| `table` | yes | the footer and the printed continuation |
| `json` | yes | `truncated` and `limit` in the response envelope |
| `csv` | **no** | — a CSV has nowhere to put it |
| `raw` | **no** | — same |

The cap is off in `csv` and `raw` deliberately. A pipe cannot carry a footer, so a capped export
would silently hand a script 100 rows of 123 456 — and a silently truncated export is worse than
a slow one. `--limit` is a session default and is suppressed with the cap in those two formats.
A `limit` written on the statement always applies: it was typed, so nothing about it is silent.

### The printed continuation

A truncated result prints the query that resumes it, ready to paste:

```
 placed_at            | total
----------------------+--------
 2026-08-27T14:02:11Z |  99.99
 …
100 of 100+
next: Order at "05KG3N0000ZQ8V4T1H7C"
        where placed_at < "2026-08-27T14:02:11Z"
           || (placed_at == "2026-08-27T14:02:11Z"
               && (customer > "05KG3N0004MM1P8B2D9F"
                   || (customer == "05KG3N0004MM1P8B2D9F" && order_num > 4471)))
        order by placed_at desc
        limit 100
```

Four rules make it correct rather than merely convenient:

- **It carries the `at` peg.** `at` defaults to request arrival, so a resume predicate with no
  peg runs against a relation that moved — the exact failure the cursor was chosen over an
  offset to avoid.
- **It uses the effective ordering tuple, tiebreak included.** That is the stated `order by`
  extended by the candidate key, and leaving the key out makes the predicate wrong at a tie
  boundary. The rule is in
  [schema/queries.md](schema/queries.md#limit-and-pagination).
- **It prints only when the result was truncated**, and never in `csv` or `raw`.
- **It is written out term by term.** There is no tuple comparison in the language, and mixed
  directions — a `desc` order with an ascending key tiebreak — could not use one anyway. Uglier
  and correct.

Pagination is a cursor and there is no offset; the reasoning is recorded at
[schema/queries.md](schema/queries.md#pagination-is-a-cursor).

## Scripting

Schema definition files use the `.dc` extension (DataCode schema file). They are plain text
DSL with `--` comments. Top-level declarations need no terminator — one ends where the next
begins, at column 0.

**`--file` takes a script, not a bare schema file.** A script carries statements, mutations,
`let` bindings, and `:commit`; a schema commit takes statements alone. The two are different
productions because configuration is rows, rows are written by a mutation, and a script that
reconstructs a deployment has to carry both. See
[schema/railroad.md](schema/railroad.md#schema-files).

**A script is re-runnable, but not by create-if-not-exists.** Re-running a `table` declaration
**redeclares** it: the system diffs the new body against the last version, finds no change, and
appends no schema node. Omitting a field is not a no-op — it deprecates the field — so the
evolution path is to edit the file and re-run it, never to accumulate a second file of deltas.
A script containing a binding that names the table it defines is **not** idempotent:
`Customer = Customer { *, status as account_status }` renames again on every run. See
[schema/evolution.md](schema/evolution.md#how-a-commit-resolves-names).

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
  placed_at : Timestamp,
  status    : Pending | Processing | Shipped | Cancelled = Pending,
  unique orderRef { customer, order_num },
  order by placed_at desc,

  assert ownerAccess { authed_user == customer.user }
}

table app.commerce.OrderLine : UserData, Component {
  order   :> Order,
  product :> Product,
  qty     : Int,
  unique lineRef { order, product }
}

-- Configuration is data, so the DR script carries it too
system.shards.ExtentPolicy { table_path = "app.commerce.Order", extent_size = 268435456 }
```

`OrderLine` carries `Component` because a line has no meaning without its order: that one bit —
does deleting the owner destroy the owned — is the only thing the key cannot say. See
[schema/traits.md](schema/traits.md#component).

Statement syntax is defined in [schema/](schema/); this example exists only to show the file
shape. For DR, maintain a set of `.dc` scripts that can reconstruct the schema and critical
configuration from scratch using only the CLI, version-controlled alongside the application
code.

## Relationship to the admin IDE

The CLI and IDE share the same underlying query engine and schema machinery. Every action
performable in the IDE is also expressible as a CLI command. The IDE is a graphical
front-end built on top of the same DataCode query and mutation APIs that the CLI uses.

Once the IDE is built, its schema (tables for diagram layouts, sidebar state, theme
configuration, etc.) is included in the initial system shard load. The IDE then becomes
self-hosting — managing its own configuration through DataCode's normal table machinery. See
[ide.md](ide.md).

## Implementation notes

- The CLI is likely the **first deliverable** in the DataCode implementation sequence — it forces the core schema definition, query, and mutation APIs to be built before anything else
- The REPL can be implemented using `haskeline` (Haskell readline library) for editing, history, and tab completion
- Tab completion should complete namespace paths, table names, field names, trait names, and DSL keywords
- The REPL uses a transaction model: all changes are staged until `:commit`; `:rollback` discards them
- `Ctrl-C` is free once the query handle exists: bind it to `cancel` rather than to connection teardown
- The CLI connects to DataCode via the same binary protocol as thick clients — it is itself a thick client
- Install-time provisioning creates the local `system.auth.Registration` the CLI authenticates against; there is no operator path that skips the client token
