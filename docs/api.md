# Custom APIs and HTTP dispatch

DataCode exposes data through two API layers — auto-generated and user-defined — and both are
**rows in system tables**. A route registration is therefore a schema act: it commits to the
transaction graph, it is versioned by schema node, and it lives on the branch shard with every
other schema node ([distribution.md](distribution.md#schema-shards-are-rooted-at-a-branch)).

[api-and-rendering.md](api-and-rendering.md) owns what a route *returns* — representation
selection, JSON encoding, themes, and the `File` response mode. This file owns registration,
versioning, dispatch, authentication, status codes, and the request log.

## Versioning and backwards compatibility

Every route — auto-generated and custom — is served under a version token:

```http
/v{token}/records/app.commerce.Order      -- auto-generated CRUD
/v{token}/orders/{id}/ship                -- custom route
```

A token is a graph node id prefix, a tag, or a branch name. The three are interchangeable and
resolve at dispatch time to one schema graph node, which selects the route set registered at that
node. [transaction-graph.md](transaction-graph.md#branches-tags-and-version-tokens) owns
resolution, including that an ambiguous id prefix fails rather than picking a match.

| A client pinned to | Sends | Moves? |
|---|---|---|
| A tag | `/vv2.1.0/records/…` | No |
| A node id prefix | `/v05KG3N0000Z/records/…` | No |
| A branch | `/vmain/records/…` | Yes — follows that branch's HEAD |

**There is no monotone integer version.** The graph is a DAG with branches, so "the schema
advances to version 10" names nothing across two branches. A client pins to a tag or an id prefix
and keeps resolving after `main` advances.

**Nothing is removed from a node.** Deleting a `CustomRoute` row is an ordinary commit: the row is
absent at nodes after it and present at nodes before it. So a client pinned to an earlier token
keeps the route it was written against, and "removing the custom route restores auto-generated
behavior" is a statement about later nodes only.

This gives:

- **No breaking changes** — a client stays on its token until it migrates deliberately
- **Multiple live versions at once** — one server process serves every token
- **Trivial rollback** — a client repoints to an earlier token the server already serves

### Unversioned requests, aliases, and discovery

Four rules, all settled in OQ-026. Each is a dispatch behaviour rather than a resolution rule,
which is why they live here and token resolution lives in `transaction-graph.md`.

- A request with **no version segment** routes to `main` HEAD.
- A deployment may **split unversioned requests across branches** at a configurable rate for A/B
  testing. The decision persists by session affinity, so one client sees one branch across
  requests rather than alternating mid-session.
- **`/vcurrent/` is an alias** that redirects to whichever tag or branch is designated. It is what
  lets an operator say "use this from now on" without a client code change.
- **`/versions` lists every live token** and marks the designated one.

Both the alias and the discovery endpoint are ordinary routes and carry no authentication
exemption.

## Route types

The route tables use six declared types. Declaring them here is the general rule that a type used
by one document's system tables belongs to that document
([schema/types.md](schema/types.md#structural-and-system-types)).

```
type RoutePattern : Text where isRoutePattern
type HttpMethod   = Get | Post | Put | Patch | Delete | Head | Options
type RouteResult  = Value Doc | Content File | NoContent
type RouteHandler = Moment -> Doc -> Tx RouteResult
type Formatter    = Doc -> Read Bytes
type NotAllowed   : Null
```

Five things those declarations settle that the earlier `FunctorRef` columns left open:

- **A handler column names a declared function type rather than writing an arrow inline.** Every
  function in a field shares one signature, because a field has a type
  ([schema/functions.md](schema/functions.md#function-types)). `FunctorRef` is still the storage;
  the declared type is what the compiler checks and what a diagnostic addresses.
- **The request arrives as a `Doc`.** Path captures differ in arity between `/orders/{id}/ship`
  and `/reports/{year}/{month}/{table}`, and `Doc` is the language's answer to tree-shaped data of
  unknown shape ([schema/documents.md](schema/documents.md)). Schema commit checks that the
  captures a handler reads are the ones its template declares.
- **The `Moment` is a parameter, never a read.** No handler reads a clock. The moment is the
  request's arrival, which is also what an unpegged `at` resolves to
  ([schema/queries.md](schema/queries.md#every-query-has-a-sample-moment)).
- **The effect index is load-bearing.** `RouteHandler` is `Tx` and `Formatter` is `Read`, so
  neither can make an external call and a format functor cannot write. That is the missing
  `Effect → Tx` lift doing its work at the HTTP surface ([events.md](events.md)).
- **`Content File` bypasses the format functor.** Octets are already a wire form and their media
  type is the value's own — see
  [api-and-rendering.md](api-and-rendering.md#serving-a-file).

## Auto-generated routes

The auto-generated API is driven by a system table — one row per exposed table or derived table:

```
table system.api.GeneratedRoute : Reference {
  table_ref     :> system.schema.Table unique,  -- which table or derived table to expose
  format_ref    :> FormatFunctor,               -- which format functor renders the result
  expose_get    : Bool = True,
  expose_post   : Bool = True,
  expose_put    : Bool = True,
  expose_patch  : Bool = True,
  expose_delete : Bool = True,
}
```

`table_ref` is a **foreign key, not a name**, which turns the phantom-override check below into
referential integrity rather than a bespoke validation. It names the same table
`system.integrity.Violation.subject_table` does.

**Five `Bool` columns rather than a set of methods.** The method set is closed and fixed by
dispatch, each method's exposure defaults independently, and there is no list type: a repeated
value would be a `Component` sub-table ([schema/tables.md](schema/tables.md#component-sub-tables)),
which is more machinery than a five-element closed set needs. The earlier
`methods : [HttpMethod]` parsed under no production and named a collection type the language does
not have. `HttpMethod` survives as the type the request log records.

Each exposure column carries its default **as syntax**. "Default: all" written in a comment is not
checked; `= True` is, and a field added to this table later has no choice about it
([schema/evolution.md](schema/evolution.md#every-added-field-declares-a-default)).

The response format is a second system table of **format functors** — pluggable representations of
the same underlying data:

```
table system.api.FormatFunctor : Reference {
  name       : Text unique,                -- "json-flat", "graphql", "csv"
  media_type :> system.files.MediaType,    -- what the response's Content-Type carries
  formatter  : Formatter,                  -- Doc -> Read Bytes
}
```

This decouples representation from schema: one table is served as JSON, GraphQL, or CSV from
different route registrations with no change to the schema definition. New format functors are
registered at runtime, which is to say by schema commit — inserting a `Reference` row is one
([schema/traits.md](schema/traits.md#reference-tables-are-code)). `media_type` sits on the row
rather than inside the functor, so the header a format answers with is data.

### Why the route tables are `Reference`

Both tables carried `Configuration`, and that contradicted the versioning claim above. A
`Configuration` row deliberately does **not** live on the branch shard — it is operator tuning
that must survive a merge ([distribution.md](distribution.md#schema-shards-are-rooted-at-a-branch))
— so a route added on `experiment-checkout` would be visible on `main` at once and no version
token could exclude it.

`Reference` is the right trait on its own terms. A route registration is code selection; inserting
a `Reference` row is already a schema transaction; and a `Reference` table is the one place a
function literal is admissible
([schema/functions.md](schema/functions.md#where-a-literal-is-admissible)), which is what a handler
column needs.

Two consequences to price rather than hide:

- **A `Reference` table is capped at 65 535 rows**, so that is also the route cap. It is six times
  the 10 000 routes the trie was measured at, and the diagnostic when it is reached says the table
  is not a code table any more.
- **Operator tuning leaves the row.** `enabled` was the one genuinely operational column, and it
  moves to a `Configuration` override keyed by mounted pattern:

```
table system.api.RouteOverride : Configuration {
  pattern : RoutePattern unique,
  enabled : Bool = True,
}
```

Whether a table is exposed at all is a schema fact; disabling a route in one deployment is
deployment tuning that must survive a merge. That is the trait-versus-configuration line
([schema/traits.md](schema/traits.md#traits-are-not-configuration)) applied to routes.

A disabled route answers **404**. To a client, an endpoint an operator turned off should be
indistinguishable from one that was never registered; any other code leaks deployment state to
callers who cannot act on it.

## Custom routes

A user-defined endpoint is a row carrying a URL template and the handler to invoke per HTTP
method:

```
table system.api.CustomRoute : Reference {
  route_pattern  : RoutePattern unique,    -- capture names erased: "/orders/{}/ship"
  route_template : Text,                   -- as written: "/orders/{id}/ship"
  format_ref     :> FormatFunctor,
  get_functor    : RouteHandler | NotAllowed,
  post_functor   : RouteHandler | NotAllowed,
  put_functor    : RouteHandler | NotAllowed,
  patch_functor  : RouteHandler | NotAllowed,
  delete_functor : RouteHandler | NotAllowed,
}
```

`NotAllowed` means that method returns 405 on that route. A row with only `post_functor` set is a
write-only endpoint.

**Two columns for one path, and the key is the pattern.** `/orders/{id}/ship` and
`/orders/{order_id}/ship` are different `Text` values that compile to one trie slot, so a `unique`
on the template as written does not catch the conflict it was credited with. Erasing capture names
is what makes the key mean what OQ-029 attributes to the trie's handler slot. Keeping the template
beside it is the settled shape for a canonicalized value — the canonical form carries the key, the
form as written stays beside it ([schema/types.md](schema/types.md#canonical-types)) — and here the
form as written is load-bearing, because the capture names are what bind path parameters into the
handler's `Doc`.

**Re-registering the same path at a later node is a new version of the same row**, not a second
row. The key is the pattern, so an update is the only thing it can be, and both versions stay
readable, each at the node it was current for.

Each referenced handler receives the path captures and the request body as one `Doc`, performs
reads and writes within a single transaction, and returns a `RouteResult`. Authentication and
authorization apply automatically (below).

The earlier claim — "there is no separate API functor type; field types are referenced directly
from the schema" — was half right and the wrong half was doing damage. The *data* types are the
schema's, and auto-generated routes are fully typed by the table definition. But the handler column
still needs a signature, or the compiler cannot check the call and the effect ladder cannot see
whether a route writes. `RouteHandler` is that signature.

Inserting or updating a row takes effect when the branch ref advances: the WAI dispatch table is
rebuilt as part of committing the schema transaction, with no server restart.

## Route conflict resolution

**Template normalization.** `route_template` is an absolute path below the version segment: leading
slash required, version segment excluded, no trailing slash. It mounts at `/v{token}<template>`.
There is no `/api/` prefix — a custom route sits at the path it declares, which is what lets it
shadow a generated one.

**Custom routes shadow auto-generated routes at the same path.** A custom route registered at
`/records/app.commerce.Order/{id}` handles every request to that path; the auto-generated handler
is bypassed at that schema node.

**Reserved `raw` first segment.** A normalized template whose first segment is `raw` is rejected at
insert time, which guarantees auto-generated CRUD stays reachable whatever else is registered:

```http
GET /v{token}/records/app.commerce.Order/{id}  -- custom handler if registered; auto-generated otherwise
GET /v{token}/raw/app.commerce.Order/{id}      -- always auto-generated
```

The check is stated against the normalized form on purpose. Written against `raw/`, a template of
`"/raw/app.commerce.Order/{id}"` passes the check the check exists to enforce.

**Path validation.** A custom route under `/records/` must reference a table or derived table that
exists at that schema node. `GeneratedRoute.table_ref` is a foreign key, so a phantom override is a
referential-integrity failure rather than a bespoke rule.

**Exact-path conflicts** are a schema validation error at insert time, and two things say so: the
`route_pattern` key rejects a second registration of the same normalized pattern, and the trie's
handler slot holds one handler (OQ-028, OQ-029).

**Version semantics.** Custom routes are schema objects, so a version token that resolves to a
schema node includes or excludes them naturally. No routing-mode flag on a branch or tag is
needed; the graph already records when a route existed.

## Inbound routes

An inbound webhook is a custom route, not an event
([events.md](events.md#the-event-system-is-outbound)). Dispatch verifies the provider's signature,
and the handler inserts into a landing table. Nothing is enqueued, because the row *is* the durable
record, and whatever should happen next is an ordinary `on … emit` on that landing table.

Two rules keep the write attributable:

- The route authenticates **by signature**, not by a DataCode token — an external provider holds
  none. See the table under Authentication below.
- The write is attributed to a **named service account**, which is an ordinary `User` row
  (OQ-015), so every landing row has an author and the ordinary access asserts apply to it.

How each provider's signature is verified is
[OQ-020](open-questions.md#oq-020-webhook-endpoint-security), which is a route concern rather than
an event one.

## Transaction semantics

Reads and writes share the same transaction graph snapshot. The primary server linearizes and
executes transactions one at a time.

**Cross-shard transactions take no lock.** Each participant pins its own graph point, and a
read-set re-check at commit is what turns a concurrent conflict into an abort rather than a lost
update. [distribution.md](distribution.md#cross-shard-transactions) owns the protocol. Two
consequences reach a caller: a 409 is a retryable conflict rather than a defect, and grouping
related shards on one server — with the primary near the users making requests — still pays.

The transaction is atomic — it either fully commits or fully fails. On failure, only the HTTP
request log is written, and the error is returned to the client.

Atomicity holds per transaction, which is why a **cluster-wide mutation is not one transaction**. A
mutation whose predicate is not anchored to a single shard is applied by each shard primary
independently and may be partial; its result is a per-shard report naming which shards contributed,
not an all-or-nothing status code. See
[distribution.md](distribution.md#bulk-and-cluster-wide-mutations).

**Index updates are part of the commit. View refresh and repartitioning are not.** They run on
`system.events.MaintenanceQueue`, pegged to a stable commit node, so a write never pays refresh
cost ([storage.md](storage.md#materialization)). "Internal event functors resolve within the
transaction" was the wrong framing twice over: an event functor always enqueues, and there is no
fifth functor kind called internal ([schema/functors.md](schema/functors.md)).

External side effects are never executed inline — see [events.md](events.md).

## Status codes

One row per named failure mode. A 500 means a defect rather than a documented outcome, which is
what the earlier "500s should be avoided" was reaching for — but "all known failure modes return
4xx" was wrong for this file's own unavailability case, and returning 4xx for it blames the client
and defeats retry for every conforming client and proxy.

In request-lifecycle order — authenticate, route, decode, commit, answer:

| Outcome | Status | Notes |
|---|---|---|
| No token, or an expired session | 401 | |
| Client scope or a missing grant | 403 | Resolved before any row is read |
| An access assert fails on a **write** | 403 | The transaction is rejected, as for any constraint |
| An access assert fails on a **read** | 200 | Every field of the row resolves to `Redacted`; the query does not abort ([schema/constraints.md](schema/constraints.md#redaction-scope)) |
| A value the caller may not read inline (`Sealed`, `TooLarge`) | 200 | The typed absence *is* the value; `reveal` is `Effect` and unreachable from a route |
| No route at that path and token | 404 | |
| The matched route's method is `NotAllowed` | 405 | |
| No acceptable representation | 406 | [api-and-rendering.md](api-and-rendering.md#representations-are-selected-by-accept) |
| Unsatisfiable `Range` on a `File` response | 416 | |
| Malformed body | 400 | |
| Body above the configured write cap | 413 | [storage.md](storage.md#files-are-chunked-components) |
| Validation failure under `enforce always` | 422 | Names the address that refused it, never the value |
| `unique` collision or foreign-key violation | 409 | |
| Read-set re-check failed at commit | 409 | A genuine write conflict; the client retries the whole request |
| Violation recorded under `monitor` or `enforce forward` | 2xx | The write succeeds and a `system.integrity.Violation` is recorded ([integrity.md](integrity.md#enforcement-modes)) |
| No reachable primary for a shard | 503 with `Retry-After` | Server-side; never 4xx |
| Cluster-wide mutation, applied per shard | 202 | Body is the per-shard report naming which shards contributed |

**The error body names an address, never a value.** A rejected commit names the path that refused
it ([schema/README.md](schema/README.md#addressing-validations)), and a validation attached to a
`Secret` type has no channel to return a value at all
([schema/types.md](schema/types.md#secret-types)). That rule is what keeps the request log below
from becoming a disclosure channel.

## Authentication and authorization

**Every request authenticates.** There is no mechanism to create an unauthenticated DataCode
endpoint. What a request authenticates *with* depends on the route, and naming the three cases is
what keeps the rule from forbidding the login and ingress routes it needs:

| Route | Presents |
|---|---|
| Any ordinary route, generated or custom | A client token — a `Server` is a `Client` that cannot be narrowed — and a user token |
| The credential exchange | A client token and a credential. The user token is what the route *returns*, so it cannot be a precondition |
| A signature-authenticated ingress route | The provider's signature over the body. The write is attributed to a named service account |

[auth.md](auth.md#token-types) owns the token kinds and their lifecycle.

**Authorization has three layers**, and a request is authorized only if all three hold:

1. The **client token's schema-level reach** covers every table the route touches. That is decided
   by its `Client` row, never by an assert ([auth.md](auth.md#schema-level-access-and-bypass)).
2. The user token holds a **recursive namespace grant** reaching each of them. The model is
   default-deny, so a table with no access assert is *denied* absent a grant, not open
   ([namespaces.md](namespaces.md#namespace-access-control)).
3. Every **`assert` mentioning `authed_user`** passes — unless the grant carries `bypass access`,
   which skips exactly that set and nothing else
   ([schema/constraints.md](schema/constraints.md#schema-level-access-and-bypass)).

No per-route permission declaration exists, and none is wanted: a functor that reads
`app.commerce.Order` faces the same access control functors as a caller querying that table
directly, and one reading three tables must satisfy all three. Putting a fourth authority on the
route row would put one decision in two places.

## HTTP dispatch

All routes — auto-generated and custom — are materialized from the system tables into a runtime
WAI dispatch table backed by a hand-rolled route trie. The Servant frame is a version capture over
a `Raw` remainder:

```haskell
Capture "version" Text :> Raw
```

The `Raw` endpoint delegates to an `IORef (RouteTrie Application)` for runtime-dynamic routing.
Route templates are compiled into path-matchers at registration time; path parameters are
extracted at request time and passed to the handler as a `Doc`.

The schema meta-API is a different frame and keeps its own
(`"schema" :> Capture "ns" String :> Capture "name" String :> Raw`). That frame was the one
recorded in the OQ-002 spike, and using it for the data plane means no request to
`/v{token}/records/…` ever reaches a handler.

Schema changes rebuild the trie and atomically swap the `IORef` — zero request interruption.

Performance (confirmed in `spikes/route-trie/output.txt`): 0.2µs/request at 10 000 registered
routes, `O(depth × log fanout)`, independent of total route count. Linear scan was ruled out
(132µs at 10k routes); `wai-routes` was ruled out (compile-time Template Haskell route tables are
incompatible with runtime registration).

**Precedence**: static segments always beat captures at the same depth.

## HTTP request logging

Every HTTP request to any DataCode endpoint is logged to `system.logs.HttpRequest`. This write is
**independent of the main transaction**: it succeeds whether the transaction commits, is rejected,
or errors. It is the only write DataCode guarantees on every request path.

```
type TokenId      : DataId
type NotCommitted : Null
type NoError      : Null

table system.logs.HttpRequest : LogData {
  method        : HttpMethod,
  path          : Text,
  version_token : Text,
  status        : Int,
  duration      : Duration,
  bytes_sent    : Int,
  client_token  : TokenId | NotGiven,
  user          : DataId  | NotGiven,
  tx_id         : DataId  | NotCommitted,
  error         : Text    | NoError,
}
```

Four things the declaration settles, three of them by omission:

- **The writing server is `origin_server`**, a virtual column typed `:> system.shards.Node` and
  read out of the row's own `DataId` ([schema/tables.md](schema/tables.md#basic-syntax)). A
  declared `server_id` would be a stored copy of those bytes, free to disagree — the exact
  duplication OQ-005 removed from `system.shards.LogSegment`.
- **Arrival time is `created_at - duration`.** A declared `received_at` would be a second clock
  reading for a fact the row already carries.
- **Neither token column is a foreign key.** A `LogData` row must not pin a credential row or a
  user row against deletion, which an inbound non-nullable reference would do. `user` is a bare
  `DataId` and resolves forward through a re-key like any other
  ([transaction-graph.md](transaction-graph.md#re-keying-is-recorded-on-the-node)). The log records
  a token's identifier and never its bearer value.
- **Two absence types, because the reason is the point.** `NotCommitted` says the transaction never
  landed; `NoError` says nothing failed. Both are ordinary `Null`-derived declarations
  ([schema/types.md](schema/types.md#absence-types)).

`error` is a rendered diagnostic, and this table is append-only and always written — which makes it
the highest-risk sink in the system for a value that should never have been persisted. A rejected
commit names the **path** that refused it, never the value that failed (see
[schema/README.md](schema/README.md#addressing-validations)), and a validation functor attached to a
`Secret` type has no channel to return a value at all
([schema/types.md](schema/types.md#secret-types)). The runtime erases error payloads originating
from `Secret` types as a backstop.

`DataId` values appearing in `path` are the 20-character Crockford base32 rendering; component rows
append dot-separated ordinals (`05KG3N0000ZQ8V4T1H7C.7`). See
[transaction-graph.md](transaction-graph.md#rendering).

Key properties:

- **Always written** — a failed, rejected, or errored transaction still produces a log row
- **Three role holders, geography relaxed** — a primary and two secondaries like any shard, under
  the batched durability class, and its secondaries may share a region or a rack. That relaxation
  is geographic rather than role count, and it is what keeps the bandwidth cheap
  ([distribution.md](distribution.md#two-durability-classes))
- **Retained by policy** — kept indefinitely unless a `retain` chain is declared for it. Silence
  means keep, and this table is high-volume enough that the omission is a decision rather than an
  oversight ([schema/aggregates.md](schema/aggregates.md#retain))
- **Auditable** — inspectable in the IDE; queryable with standard DataCode tools

This log is the foundation for observability: correlating `tx_id` with `system.graph.Transaction`
([transaction-graph.md](transaction-graph.md#systemgraphtransaction)) gives the full audit trail
from HTTP request through to committed mutations, and it is also how the acting token behind a
recorded transaction is recovered.
