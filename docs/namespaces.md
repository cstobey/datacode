# Namespaces

## Concept

DataCode organizes tables, derived tables, types, traits, and functors into a **tree of
namespaces**. Namespaces replace the SQL concepts of "database" and "schema" (in the PostgreSQL
sense). They are the primary organizational unit above the table level.

A fully-qualified name reads `app.commerce.Order` — lowercase namespace segments, capitalized
table name. See [schema/README.md](schema/README.md#capitalization).

```
system.auth.User
app.commerce.Order
connectors.mariadb.production.Order
```

Namespaces are:

- Hierarchical, to arbitrary depth
- Carried by the schema transaction graph, so a namespace lives on the branch's schema shard
  with every other schema node — see
  [transaction-graph.md](transaction-graph.md#data-shards)
- The unit a grant names: a token may hold a grant on `app.commerce` and none on `system.auth`
- Versioned. Moving or renaming creates a new graph node and the old name stays live until you
  `deprecate` it — see [Moving and renaming](#moving-and-renaming)

## Namespace tree structure

The tree names **namespaces, not tables**. Each namespace's tables are declared in the document
that owns them; a second inventory here would only drift out of step with the first.

```
(root)
├── system/           -- DataCode's own operational data
│   ├── api/          -- route registration and response formats
│   ├── auth/         -- users, credentials, tokens, grants
│   ├── config/       -- deployment-tunable policy rows
│   ├── connectors/   -- connector rows, replication positions, conflicts
│   ├── crypto/       -- hash, cipher, wrapping, and scrub policy
│   ├── events/       -- scheduler policy, handler registration, trigger state
│   ├── export/       -- export destinations
│   ├── files/        -- media types
│   ├── graph/        -- the transaction graph, self-hosted
│   ├── ide/          -- the admin IDE's own schema
│   ├── integrity/    -- violations and their dispositions
│   ├── logs/         -- operational logs, authored per server, rolled by `retain`
│   ├── runtime/      -- handler generations and recycling policy
│   ├── schema/       -- branches, tags, and the table registry
│   ├── shards/       -- topology, role ranges, extent and durability policy
│   ├── telemetry/    -- proposals, and the per-field timestamp cache
│   ├── text/         -- canonicalization policy
│   └── ui/           -- themes and type renderers
│
├── connectors/       -- generated shadow schemas, one namespace per connector
│   ├── mariadb/
│   │   └── production/
│   └── stripe/
│       └── billing/
│
└── app/              -- application schema you declare and maintain
    ├── commerce/
    └── reporting/
```

There is no top-level `reference/` branch. A namespace named after a replication policy would
repeat for `Reference` the category error corrected below for `system`: replication follows the
trait, and a `Reference` table lives wherever it belongs — `system.crypto.HashPolicy` and
`app.commerce.OrderStatus` are both `Reference`.

## Creating a namespace

Namespaces have no declaration form. A dot-separated name brings every intermediate namespace
into existence when the declaration commits. `namespace` is not a statement and not a reserved
word — see [schema/README.md](schema/README.md#namespace-organization) and the grammar in
[schema/railroad.md](schema/railroad.md#schema-files).

```
table app.commerce.Order : UserData {
  customer  :> Customer,
  order_num : Int,
  total     : Amount = 0,
  unique orderRef { customer, order_num }
}
```

That declaration creates `app` and `app.commerce` if they do not already exist. Every row
carries a `DataId` row identifier implicitly; a candidate key is declared, never implicit — see
[schema/tables.md](schema/tables.md#candidate-keys-are-mandatory).

## Name resolution

- **A name with more than one segment is absolute.** `app.commerce.Order` names that table
  wherever it is written, and a fully-qualified name always resolves.
- **A single-segment name resolves in the namespace of the enclosing declaration.** Inside
  `table app.commerce.Order`, the `Customer` in `customer :> Customer` is
  `app.commerce.Customer`.
- **The REPL adds a session default.** `:use app.commerce` makes an unqualified name resolve
  there for the rest of the session. This is a convenience for typed input, not a schema-file
  construct. See [cli.md](cli.md#interface-style).
- **`import` names a Haskell package, not a namespace.** It admits library functions to a schema
  file and takes no part in namespace lookup. See
  [schema/functions.md](schema/functions.md#haskell-functions).

Two questions are open, and an implementer needs both answered before writing the resolver:
whether a single-segment name falls back to an ancestor namespace when it does not resolve in
the enclosing one, and what happens when two candidates resolve — an error naming both, or
shadowing by proximity. An error is the safer default, because shadowing lets a new declaration
silently redirect an existing reference.

## Relationship to shards

Namespaces are a logical organization; shards are a physical one. A namespace does not map to a
shard.

- **The replication trait selects the family.** `Reference` and `Configuration` rows reach every
  server; `UserData` and `LogData` rows are shard-local. See
  [schema/traits.md](schema/traits.md#replication-traits).
- **Within a shard-local family, the candidate key selects the shard.** A row lands in the
  row-rooted shard its key reaches through the foreign-key chain, so placement is computed and
  there is no stored namespace-to-shard mapping to consult. See
  [schema/tables.md](schema/tables.md#keys-must-be-rooted).
- **A shard family is named by its root table's namespace** — `app.commerce` is the family whose
  root is `app.commerce.Customer`. That naming is the one place the two organizations touch, and
  it designates which tables participate, not where their rows go. See
  [transaction-graph.md](transaction-graph.md#shard-roots).
- **Data volume triggers a split, not an assignment.** See [cli.md](cli.md#shards).

`system` is **not** among the replication traits: it is a namespace, and a table in it carries
whichever trait fits. `system.integrity.Violation` is `LogData`; `system.shards.RoleRange` is
`Configuration`. The namespace says whose a table is and who may see it; the trait says how it
propagates.

A namespace can span multiple shards. A shard can hold tables from multiple namespaces.

## Connector namespaces

A connector's generated shadow schema lands under `connectors.<kind>.<name>`, so a `mariadb`
connector named `production` places its discovered tables under
`connectors.mariadb.production.*`. The path is read off the connector row, so the kind and the
namespace segment are the same word by construction.

Two rules elsewhere are decided by that path rather than by a flag on the table:

- Generated schemas carry `connector` visibility, so they are hidden from the default IDE view.
- A validation attached under `connectors.*` defaults to `monitor`, so one bad row cannot halt a
  binlog. See [integrity.md](integrity.md#ingestion-must-not-enforce).

These namespaces are **automatically managed** — the connector updates them when the external
schema changes ([connectors.md](connectors.md#schema-auto-discovery)) — and **referenceable**
from your own namespace by binding a query over them:

```
-- app.commerce.Order refines the connector shadow schema
app.commerce.Order = connectors.mariadb.production.Order
  { customer, centsToAmount (total_cents) as total, toOrderStatus (status) as status }
```

Each projected expression mints the field's type — see
[schema/queries.md](schema/queries.md#field-types). Naming the function rather than inlining the
arithmetic is worth doing anyway: it gives the coercion an identity a diagnostic can address, and
the next binding needing the same conversion reuses it.

A shadow table's name follows the ordinary capitalization convention, so the MariaDB table
`orders` appears as `connectors.mariadb.production.Order`. How a source identifier is
transliterated is not specified, and the hard cases are the ones an implementer meets first: a
name that cannot form an `Ident`, a source carrying both `order` and `orders`, and a collision
with a table already discovered.

## Schema visibility layers

Every table, derived table, and functor carries a **visibility level**:

| Level | Meaning | In the default IDE view |
|---|---|---|
| `system` | DataCode internals | No |
| `connector` | Generated connector shadow schemas | No — opt in per connector |
| `internal` | Yours, but an implementation detail | No — opt in |
| `standard` | Normal application schema | Yes |
| `featured` | High-importance, shown prominently | Yes, weighted higher in PageRank |

The level is stored as a field on the schema transaction graph node and changed with
`set visibility` ([schema/evolution.md](schema/evolution.md#set-visibility)). `app.*` is
`standard` or `featured` by default and `connectors.*` is `connector` by default; you can
override the level per table.

**Visibility is a presentation hint, never an access control.** It affects the IDE's default
view and the schema PageRank calculation, and nothing on the query path. What a request may
reach is decided in two other places: the client token's `system.auth.Client` row decides which
tables it reaches at all, and grants plus row-level asserts decide the rest — see
[auth.md](auth.md#schema-level-access-and-bypass) and
[Namespace access control](#namespace-access-control). Hiding `system.*` from a sidebar and
refusing a query against it are different mechanisms, and merging them would put one decision in
two places, which is what the `authed_client` proposal was rejected for.

## Namespace access control

The model is **default-deny with recursive grants** (OQ-024). Access control functors apply at
the namespace level, not only at the table level:

- A grant on `app.commerce` reaches every table in that namespace and in its children.
- Further functors narrow it at the table or row level. Recursion sets the ceiling; functors
  lower it.
- Grants are per-subtree and explicit. A grant on `app` reaches `app` and its descendants and
  confers nothing on siblings or ancestors — access to `app` is not access to `system`, and
  there is no implicit grant at the root.
- A grant is over the subtree **as it evolves**, not as it stood when the grant was written. The
  schema is data, so `app.hr.Salary`, declared under an existing grant on `app`, is reachable by
  that grant from the commit that declares it. Whether declaring a table under a
  `bypass`-bearing grant should warn at commit is not settled.

### Bypass

Recursion sets the ceiling and functors lower it — which leaves no way to express an
administrator, whose authority is precisely *not* to be lowered. A grant may therefore declare
that row-level access does not apply to it:

```
grant  system.auth.Role.Admin on app.pm bypass access
revoke grant system.auth.Role.Admin on app.pm
show   grants for app.pm
```

`bypass access` skips every `assert` that mentions `authed_user`, on read and on write, and
**skips nothing else**. Data constraints still run: an administrator is exempt from access
control, never from data integrity. Because the set of access constraints is read off the assert
bodies rather than off their names
([schema/constraints.md](schema/constraints.md#the-variety-is-decided-by-the-body)), that
exemption is exact rather than a matter of whether a rule was named the way its author expected.

`bypass erasure` is the second kind and is independent of the first. It lets a token read the
history of a row that has been erased, and it is kept separate because that is a narrower and
rarer permission than administering a namespace — an auditor may need it where an application
administrator should not have it. A grant may carry either, both, or neither. See
[integrity.md](integrity.md#erasure-restricts-scrub-destroys).

Two properties follow from putting this in the grant rather than in the tables. Bypass is
**one queryable place** — "who can see everything under `app.pm`" is a query against
`system.auth.Grant`, not a scan of every table's asserts. And it is **subtree-scoped** like
every other grant, so an administrator of `app.pm` is an ordinary user everywhere else.

The grant is a row; the CLI spelling above writes it. See [cli.md](cli.md#grants) and
[auth.md](auth.md#schema-level-access-and-bypass).

## Moving and renaming

Every namespace and schema change is recorded in the schema transaction graph, so no path is
destroyed:

- Moving `app.Order` to `app.commerce.Order` creates a new graph node. Both names stay live at
  head until you `deprecate` the old one — the same mechanism a field rename uses. See
  [schema/evolution.md](schema/evolution.md#keep-old-names).
- Once deprecated, the old name is still queryable at any earlier version, addressed by an `at`
  clause.
- An external system can additionally pin to a historical schema node, which fixes the whole
  schema it sees rather than one name.

No structure is destroyed, so every historical name stays resolvable. That is a consequence of
the append-only schema graph. It is a narrower claim than **data independence**, which is the
layering property — an `app.*` schema evolving independently of the connector schema underneath
it — and belongs to [schema/README.md](schema/README.md).
