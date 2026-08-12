# Custom APIs and HTTP Dispatch

DataCode exposes data through two complementary API layers — auto-generated and
user-defined — both managed as **rows in system tables**. Because API registrations live in
the schema transaction graph, every change is automatically versioned. Version prefixes in
every URL path mean no route is ever removed: old client integrations remain valid
indefinitely.

For the representation layer (JSON vs. HTML vs. binary, theming, rendering) see
[api-and-rendering.md](api-and-rendering.md).

## Versioning and Backwards Compatibility

Every route — auto-generated and custom — is prefixed with the schema version at which it
was registered:

```
/v{N}/records/app.commerce.Order      -- auto-generated CRUD at version N
/v{N}/api/orders/{id}/ship             -- custom endpoint at version N
```

When a schema change is committed (a new transaction graph node), routes added at that node
are registered under the new version prefix. Routes from all prior nodes remain in the
dispatch table permanently — the table is append-only in practice. A client pinned to
`/v3/...` continues working after the schema advances to version 10.

This gives:

- **No breaking changes** — clients stay on their version prefix until they explicitly migrate
- **Multiple live versions simultaneously** — a single server process serves all version prefixes at once
- **Trivial rollback** — clients repoint to an older prefix; the server already handles it

Version tokens may be a graph node hash prefix, a tag, or a branch name — all three are
interchangeable in URL paths. See [transaction-graph.md](transaction-graph.md).

## Auto-Generated Routes

The auto-generated API is driven by a system table — one row per exposed table or view:

```
table system.api.GeneratedRoute : Configuration {
  table_ref   : TableRef unique,  -- which table or view to expose; one row each
  methods     : [HttpMethod],     -- which HTTP methods to expose (default: all)
  format_ref  : FormatRef,        -- which format functor to use
  enabled     : Bool
}
```

The response format is determined by a second system table of **format functors** —
pluggable representations of the same underlying data:

```
table system.api.FormatFunctor : Configuration {
  name        : Text unique, -- e.g. "json-flat", "graphql", "csv"
  functor_ref : FunctorRef   -- functor that transforms query results into the wire format
}
```

This decouples representation from schema: the same table can be served as JSON, GraphQL,
or CSV from different route registrations without touching the underlying schema
definition. New format functors can be registered at runtime.

## Custom Routes

User-defined endpoints are rows in a system table. Each row defines a URL template and the
functor to invoke per HTTP method:

```
table system.api.CustomRoute : Configuration {
  route_template : Text unique,     -- e.g. "/orders/{id}/ship"
  get_functor    : FunctorRef | NotAllowed,
  post_functor   : FunctorRef | NotAllowed,
  put_functor    : FunctorRef | NotAllowed,
  patch_functor  : FunctorRef | NotAllowed,
  delete_functor : FunctorRef | NotAllowed
}
```

`NotAllowed` means that HTTP method returns 405 on that route. A route with only
`post_functor` set is a write-only endpoint.

`route_template` is the table's candidate key, which is also what makes exact-path conflicts a
schema validation error at insert time rather than a bespoke check — the trie's handler slot
can only hold one handler, and the key says so (see OQ-028 and OQ-029).

Each referenced functor is an **API functor**: it receives the extracted path parameters and
request body (if present), performs reads and/or writes within a single transaction, and
returns a response value. Authentication and authorization apply automatically (see below).

There is no separate API functor type — field types are referenced directly from the
schema everywhere they are used. Auto-generated routes are fully typed by the table
definition.

Inserting or updating a row in `system.api.CustomRoute` takes effect immediately — the
WAI dispatch table is updated as part of committing the transaction, with no server restart.

## Route Conflict Resolution

Custom routes shadow auto-generated routes at the same path. If a custom route is registered
at `/records/app.commerce.Order/{id}`, it handles all requests to that path — the
auto-generated handler is bypassed for that schema version. Removing the custom route
restores auto-generated behavior.

**Reserved `raw/` prefix**: `/v{N}/raw/<table-path>` always routes to the auto-generated
handler. Custom routes whose template starts with `raw/` are rejected at insert time. This
guarantees auto-generated CRUD is always reachable regardless of custom route registrations:

```
GET /v{N}/records/app.commerce.Order/{id}  -- custom handler if registered; auto-generated otherwise
GET /v{N}/raw/app.commerce.Order/{id}      -- always auto-generated
```

**Path validation**: A custom route registered under the `/records/` prefix must reference a
table or view that exists in the current schema. Phantom overrides (custom routes for
non-existent tables) are rejected at insert time.

**Exact-path conflicts**: two custom routes at the same pattern are a schema validation
error at insert time. The route trie's handler slot can only hold one handler.

**Version semantics**: Custom routes are schema objects — they are committed to the
transaction graph and are naturally included or excluded based on which schema node a
version token resolves to. No special routing-mode flag is needed on branches or tags; the
schema graph already captures when a custom route existed.

## Transaction Semantics

Reads and writes share the same transaction graph snapshot. The primary server linearizes
and executes transactions one at a time. Cross-shard transactions require all shard
primaries to agree: a cross-server lock is taken on a `transaction_id` across the involved
shards and held until all operations complete. Consequence: group related shards on the same
server, and prefer placing the primary close to the users making requests.

The transaction is atomic — it either fully commits or fully fails. On failure, only the
HTTP request log is written (to a per-server system shard that always succeeds
independently). The error is returned to the client. 500s should be avoided; all known
failure modes return 4xx.

Internal event functors (index updates, view refresh) resolve within the transaction as they
occur. External side effects are never executed inline — see [events.md](events.md).

## Authentication and Authorization

**Authentication** is always on. Every request to any route — auto-generated or custom —
must carry a valid client token and user token. There is no mechanism to create an
unauthenticated DataCode endpoint.

**Authorization** is automatic and derived from the access control functors on the tables
the API functor accesses. No per-route permission declaration exists: if the functor reads
`app.commerce.Order`, the same access control functors apply as if the caller had queried
that table directly. A custom functor that reads multiple tables must satisfy the access
control functors on all of them.

See [auth.md](auth.md).

## HTTP Dispatch

All routes — auto-generated and custom — are materialized from the system tables into a
runtime WAI dispatch table backed by a hand-rolled route trie. The Servant frame handles the
static URL structure (`"schema" :> Capture "ns" String :> Capture "name" String :> Raw`);
the `Raw` endpoint delegates to an `IORef (RouteTrie Application)` for runtime-dynamic
routing. Route templates are compiled into path-matchers at registration time; path
parameters are extracted at request time and passed to the functor.

Schema changes rebuild the trie and atomically swap the `IORef` — zero request interruption.

Performance (confirmed in `spikes/route-trie/output.txt`): 0.2µs/request at 10 000
registered routes, `O(depth × log fanout)`, independent of total route count. Linear scan
was ruled out (132µs at 10k routes); `wai-routes` was ruled out (compile-time Template
Haskell route tables are incompatible with runtime registration).

**Precedence**: static segments always beat captures at the same depth.

## HTTP Request Logging

Every HTTP request to any DataCode endpoint is logged to `system.logs.HttpRequest` — a
per-server `LogData`-type shard. This write is **independent of the main transaction**: it
succeeds whether the transaction commits, is rejected, or errors. It is the only write that
DataCode guarantees on every request path.

```
table system.logs.HttpRequest : LogData {
  server_id     : ServerId,
  received_at   : Timestamp,
  method        : HttpMethod,
  path          : Text,
  version_token : Text,
  status_code   : Int,
  duration_ms   : Int,
  client_token  : TokenId | NotFound,
  user_token    : TokenId | NotFound,
  tx_id         : DataId  | NotFound,
  error         : Text    | NotFound
}
```

`error` is a rendered diagnostic, and this table is append-only and always written — which
makes it the highest-risk sink in the system for a value that should never have been
persisted. A rejected commit names the **path** that refused it, never the value that failed
(see [schema/README.md](schema/README.md#addressing-validations)), and a validation functor
attached to a `Secret` type has no channel to return a value at all
([schema/types.md](schema/types.md#secret-types)). The runtime erases error payloads
originating from `Secret` types as a backstop.

`DataId` values appearing in `path` are the 20-character Crockford base32 rendering; component
rows append dot-separated ordinals (`05KG3N0000ZQ8V4T1H7C.7`). See
[transaction-graph.md](transaction-graph.md#rendering).

Key properties:

- **Always written** — a failed, rejected, or errored transaction still produces a log row
- **Per-server** — not cross-replicated; each server is authoritative for its own request history
- **Prunable** — subject to the same time-bounded retention as other `LogData` shards
- **Auditable** — inspectable in the IDE; queryable with standard DataCode tools

This log is the foundation for observability: correlating `tx_id` with the transaction graph
gives the full audit trail from HTTP request through to committed mutations.
