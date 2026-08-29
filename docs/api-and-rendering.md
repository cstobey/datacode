# API and rendering

DataCode serves several representations of the same data. Every one of them derives from the
same schema graph, so there is no second API definition to keep in step with it.
[api.md](api.md) owns routes, dispatch, and versioning; this file owns what a route returns and
how it is rendered.

## Representations are selected by `Accept`

| Media type | Audience | Format | Notes |
|---|---|---|---|
| `application/vnd.datacode+capnp` | Servers, thick clients | Cap'n Proto frames | Full replication fidelity: provenance, schema version, sequence numbers |
| `application/json` | Third-party integrations | JSON | Generated from the schema, the way GraphQL introspection generates its own |
| `text/html` | Thin clients (browsers) | HTML and CSS | Rule-based rendering from the schema graph |
| The value's own media type | Any client fetching a `File` | Octets | See [Serving a `File`](#serving-a-file) |

**Selection is on `Accept`, not on `Content-Type`.** `Content-Type` describes the body a client
sends, so a `GET`, which has no body, would select nothing (RFC 9110 §12.5.1). The earlier table
dispatched on `Content-Type` and listed `text/html` twice — once plain, once for browser SPAs —
which is not a function and cannot serve as a dispatch key.

**A browser SPA is a theme, not a fourth representation.** It receives `text/html` from a theme
whose components draw with D3, and those components then fetch `application/json` from the same
routes. That is one media type and two requests. Which visualizations a theme uses is a theme
decision (OQ-014).

**Precedence.** A route registering a format functor
(`system.api.GeneratedRoute.format_ref`, [api.md](api.md#auto-generated-routes)) fixes the
representation, because the registration is the more specific statement. Where a route registers
none, `Accept` selects. Where neither yields an acceptable representation the answer is 406,
never a guess.

### The binary format is Cap'n Proto

Settled in OQ-003 with a recorded spike: Cap'n Proto in production, `cereal` during development,
under identical length-prefix framing. [storage.md](storage.md#wire-format-for-replication) owns
the frame and its evolution rules; this layer adds nothing to it. What this layer requires —
type provenance, a schema version reference, and sequence numbers — `TxNode` already carries.

MessagePack sat in the earlier candidate list and fails the test that ruled out Protobuf: the
deciding property is that a reader mmaps the bytes and reads fields at fixed offsets, and both
alternatives require a parse.

The media type is unregistered. `application/x-datacode` was the earlier spelling; RFC 6648
deprecates the `x-` prefix, and the vendor tree is where an unregistered type belongs.

### Serving a `File`

A route projecting a single `File` field streams the octets instead of encoding them:

- `Content-Type` is the `iana` column of `body.media_type`
  ([types.md](schema/types.md#virtual-columns)) — what the octets were written as, never sniffed
  from the bytes.
- `Content-Length` is `body.length`. `ETag` is `body.digest`, a strong validator because the
  digest is taken over the octets as written.
- `Range` resolves to a bounded contiguous scan over the chunk `ordinal`. Ranging is transport,
  which is why the query language has no byte-range operator.

This is the one response mode with no query result behind it, and it is what "DataCode is the
origin" costs: DataCode serves its own CSS, fonts, and scripts rather than an external CDN, so
it needs a mode that answers with octets and a media type. That requirement is why a `File`
carries a media type at all ([types.md](schema/types.md#files)). Above the inline read cap
`body.bytes` reads `TooLarge` in a query, and this route is the only path to those octets.

## JSON API

The JSON representation is generated from the schema:

- Each table becomes a resource endpoint.
- Foreign key functors become nested objects or links, configurable per route.
- Mutations are typed by the schema: the request body must conform to the table's type.
- A row failing an access assert is serialized like any other row, with every field — including
  the key — carrying `Redacted`. Nothing is omitted, because redaction is row-scoped and
  shape-preserving; [constraints.md](schema/constraints.md#redaction-scope) owns the rule and the
  argument that omission would let a scan enumerate the identities of rows the requester may not
  read.
- A table outside the client token's schema-level reach is the one omission case, and it is a
  different decision: it has no endpoint at all, resolved before any row is read
  ([auth.md](auth.md#schema-level-access-and-bypass)).

### Absence is encoded, not collapsed

[types.md](schema/types.md#absence-types) owns the `Null` family. This is how the family crosses
the JSON boundary, and carrying it across is the point of having it — a third-party client is the
one reader who cannot go and look at why a value is missing.

- **Outbound**, a `Null`-derived value serializes as `{"$absent": "<Variant>"}`:
  `{"$absent": "Redacted"}`, `{"$absent": "NotGiven"}`, `{"$absent": "TooLarge"}`.
- The tag has to be structural. A bare `"Redacted"` was rejected because it is also a legal value
  of an ordinary `Text` field. `$` cannot begin a DataCode identifier, so the key collides with no
  generated field name.
- **`JsonNull` is the exception, in both directions.** A JSON `null` inside a document decodes to
  `JsonNull` ([documents.md](schema/documents.md)) and serializes back as `null`, which is what
  round-trips. That is the only place JSON `null` appears in a DataCode response.
- **Inbound**, a client writes an absence variant in the same tagged form, and the variant must be
  named in the field's declared type. Omitting the field is not a way to say which absence is
  meant — `phone : Phone | NotGiven | NotFound` offers two — so an omitted field takes the field's
  default, or the write is rejected.

The earlier text mapped "`NOT_FOUND` / `Maybe` fields" to nullable JSON. Each part of that was
load-bearing and wrong: the type is spelled `NotFound`; `Maybe` is the construct the model
rejects, and appears only at the Haskell function boundary
([category-model.md](category-model.md#absent-values)); and one `null` for every variant discards
the reason for absence at the boundary least able to recover it.

## HTML rendering

Thin clients receive server-rendered HTML. A thick client runs the same algorithm locally against
its replica, in which case the server ships replication deltas rather than rendered pages.

### Schema linearization

The renderer lays the schema out in order of **structural importance**, a score computed per
table by PageRank over the schema graph.

- **The graph is the declared `:>` edges** — one directed edge per foreign key field, from the
  referencing table to the referenced one. Not "the schema category": a category has all
  composites, so a walk over it is ill-posed. The generating graph is what the declarations
  carry.
- **PageRank, not degree.** A reference from a heavily referenced table counts for more than one
  from a leaf, which is the whole reason to run the fixed point rather than count edges.
  In-degree (how many tables reference this one) and total degree (how many relationships it
  participates in) are useful diagnostics in the IDE and are **not** inputs to the score; the
  earlier text presented them as its two components, which describes a different and much weaker
  metric.
- **Dangling nodes redistribute uniformly.** A table with no outbound foreign key — most code
  tables — absorbs rank and passes none on, so without the redistribution the mass leaks out of
  the walk and every score decays toward zero. Stating the rule is what makes two implementations
  agree.
- **The computation is deterministic**: a fixed iteration count rather than a convergence
  epsilon, a canonical tie-break by fully qualified name, and parameters from one `Configuration`
  row. Determinism is not a nicety. Extent clustering breaks its ties with this score
  ([storage.md](storage.md#clustering-order)), so two replicas that disagree lay rows out
  differently. OQ-010 owns the damping factor, the iteration count, and per-edge-kind weights.
- **It runs at schema commit, not per request.** The score is a function of the schema graph, so
  it changes only when the graph does.
- **`featured` enters as the restart distribution**, so marking a table featured lifts the tables
  it depends on too ([namespaces.md](namespaces.md#schema-visibility-layers)). A post-rank
  multiplier was rejected: it lifts the marked table alone, so a featured `Order` outranks the
  `Customer` it links to, and the result is a rank plus a fudge rather than a fixed point.
- **Visibility filters the laid-out list; it does not change the score.** One score serves both
  consumers, and the IDE's default view is a filter over it.

`Reference` tables rank high — everything points at them — and they are still not laid out as
page sections. A code table renders as the *control* on the field that references it, which is
what the weighted-cardinality rule below already does, so the rank that pools in lookup tables
lands where it is useful. Two alternatives were rejected: reversing the edges so rank flows from
referent to dependent, which moves the mass onto link tables (`OrderLine` above `Order`, `Order`
above `Customer`) and is a different wrong answer; and dropping `Reference` tables from the walk,
which produces a second score when extent clustering needs the same one.

### Information density windowing

Each user carries an **information density value**, a positive integer that cuts the ranked list.

- **The cut is on rank position, not on the score.** Number the tables from 1 by descending
  score; a table is shown when its rank is at most the density value. A PageRank score is a
  probability, so an integer threshold over the score is two-valued in practice.
- **Higher density shows more.** The earlier rule showed elements whose weight was at most the
  density value, which revealed the least central tables and hid the most — the opposite of
  "more central data elements appear more prominently".
- **The table is the atomic unit.** A table is inside the window or outside it, and every field
  of a shown table is shown. Windowing a field out would render a row with holes in it, and a
  reader could not tell a suppressed field from an absent value — the distinction the `Null`
  family exists to carry.
- **A `:>` field whose target is outside the window renders as the target's label**, not as an
  expanded control or a nested section. That is the whole of density's effect on fields, and it
  is what lets one schema render as a summary for a casual user and in full for a power user.

### Relationship rendering (weighted cardinality)

One-to-one and one-to-many relationships render by **weighted cardinality**:

- `weight = f(element_count, element_size)` — a tunable function.
- Low weight gives compact controls: radio buttons, checkboxes, simple selects.
- High weight gives full browsing interfaces: search-as-you-type, paginated tables, shopping-cart
  style pickers.

Progression, approximate and to be refined (OQ-016):

1. Single radio button or checkbox — 1 option
2. Radio group or checkbox list — 2–5 options
3. Select dropdown — 6–20 options
4. Typeahead or autocomplete — 20–200 options
5. Searchable list with preview — 200–2000 options
6. Full browsing interface — 2000+ options, or a large element size

The thresholds and the weight function are tunable per application and overridable per field.

### Selecting a theme and a density

Both are client preferences the server may decline to honour, so both ride the `Prefer` header
(RFC 7240): `Prefer: theme=plain, density=3`.

A private header and an invented `Accept` parameter were both rejected: `text/html` registers
only `charset`, so a `theme=` parameter on it is a spec violation dressed as negotiation, and
`Prefer` already means "honour this if you can".

Resolution is most-specific-first: the request's `Prefer`, then the user's stored preference,
then the deployment default in `system.config`. The response reports what it applied in
`Preference-Applied` and carries `Vary: Accept, Prefer`. Two users of one URL get two pages, and
a cache that does not know that serves one of them the other's page.

### Themes

A theme is a row in a `Reference` table, so a theme is code: versioned by schema node, replicated
everywhere, diffable per path, and old versions stay queryable.

```
table system.ui.Theme : Reference {
  name       : Text unique,
  stylesheet : Text
}

table system.ui.TypeRender : Reference {
  theme     :> Theme,
  type_name : Text,
  render    : Renderer,
  unique renderFor { theme, type_name }
}
```

- **The key is `{ theme, type_name }`.** Two themes each define a renderer for `Amount`, which is
  what the theme-swap claim below depends on. Keyed by `type_name` alone — the earlier shape —
  the second theme has nowhere to go.
- **`render` holds one signature**, `Renderer`, which is `Moment -> Doc -> Read Html`
  ([functions.md](schema/functions.md#function-types)). A field has a type, so every function in
  the column shares it: the renderer takes a `Doc` and dispatches inside. A signature indexed by
  `type_name` would need a dependent type the language does not have.
- **`type_name` is the key space `app.ui.Template.subject` uses**
  ([templates.md](schema/templates.md#a-template-is-a-reference-row)), which is what makes a
  template admissible as a render function.
- **`stylesheet` is `Text`, not `File`.** A `File` field is rejected on a `Reference` table —
  an unbounded payload replicated to every server on a schema commit
  ([types.md](schema/types.md#restrictions-on-a-file-field)) — and a stylesheet is code in the
  same sense a template body is. Fonts, images, and scripts are `File` rows on an ordinary table,
  served by DataCode as the origin.

A render function is a **function-valued column on a `Reference` table**, which is what makes
"themes are stored as reference data" work without storing uncompiled data: inserting a
`Reference` row is a schema transaction, so the function compiles, is versioned by schema node,
and replicates everywhere. See
[functions.md](schema/functions.md#functions-as-column-values).

Themes ship with DataCode, are defined by the application layer, or both, and are queried,
extended, and modified through the ordinary schema interface. Lookup for one value goes: the
active theme's row for the type, then the default theme's row, then the type's built-in
rendering. A theme overrides what it cares about and inherits the rest.

**Templates and render functions are one mechanism.** A [template](schema/templates.md) is text
with holes; a hole with no `using` clause falls through to the active theme's render function for
the row's type. That is why a theme swap changes every rendered value on every page with no
template edited, and why the template language needs no formatting filters — the functions in a
hole are the functions in the schema. Absence renders for the same reason: `Redacted` reaches a
hole as a value of the field's read type, not as a gap
([templates.md](schema/templates.md#absence-renders-because-absence-is-a-type)).

**Rendering a `Timestamp` as "3 hours ago" is a function of the observation moment**, and no
functor may read a clock. The moment is the renderer's first argument, supplied from the query's
sample moment ([queries.md](schema/queries.md#every-query-has-a-sample-moment)); a renderer that
ignores it is constant in that argument and costs nothing. Under the earlier `Amount -> Read Html`
shape the flagship theming example was the one thing the effect ladder made unwritable.

**UI hints are advisory.** A trait declares hints as `ui { template = "card", density = "compact" }`
([traits.md](schema/traits.md#ui-template-hints)). A theme that does not recognize a key ignores
it: a hint never fails a schema commit and never fails a render, because it is a request to a
theme that may not exist yet. Which keys a theme is obliged to honour is not yet settled.

Composition stays here rather than in the templates: the renderer walks the schema by PageRank
weight and windows it by information density, and templates are the per-type fragments it
composes. A template needs no partials, inheritance, or blocks as a consequence.

### The rendering algorithm

1. Authenticate the request and resolve the token's schema-level reach
   ([constraints.md](schema/constraints.md#schema-level-access-and-bypass)).
2. Resolve the query's commit node and sample moment
   ([queries.md](schema/queries.md#every-query-has-a-sample-moment)). Everything below reads that
   pair, so one page is one consistent observation.
3. Read the PageRank scores stored for that schema node. They were computed at schema commit.
4. Window the reachable tables by the request's density value.
5. For each table in rank order, render each row's fields with the active theme's render function,
   and each relationship at the level its weighted cardinality selects.
6. Emit the theme stylesheet and return the page.

Access control does not appear as a step, and its absence is the point. Rows failing an access
assert arrive from the query layer with every field already `Redacted`, so the renderer renders an
absence variant like any other value. The earlier step 5c hid fields the token could not see,
which is per-field omission — the behaviour
[constraints.md](schema/constraints.md#redaction-scope) considered and rejected.

## Thick client local rendering

A thick client holds a local replica of the schema and of the rows the server has released to it.
It renders HTML locally with the algorithm above, requests deltas rather than pages, and forwards
mutations to the shard primary when connectivity allows. It consumes the Cap'n Proto replication
frames, not the JSON or HTML representations.

**The server is the sole enforcement point.** A replica contains only rows the server already
released, and re-applying asserts on the client is a rendering convenience, never a control — a
modified client reads everything in its own replica, so anything it must not read must never have
been shipped. Which asserts were evaluated, and at which moment, is a property of the release, not
of the render.

- **A revocation invalidates the replica.** A grant withdrawn while the client is offline cannot
  be enforced retroactively over bytes the client already holds, so the client re-authenticates
  and re-syncs before it renders again, and stale scope is the failure mode to design against
  rather than deny.
- **A client-held materialized view is pegged**, like any other, to a commit node and a sample
  moment ([storage.md](storage.md#materialization)). It is refreshed when an invalidation names a
  table it reads, and discarded when its peg is pruned; the client recomputes from the current
  head instead.
- **The push carries an invalidation, never a payload**
  ([distribution.md](distribution.md#what-gets-pushed-depends-on-who-is-listening)). The client
  re-reads through the ordinary query path, where its access asserts are evaluated by the code
  that already evaluates them. Pushing payloads would put an access decision on the write path,
  which exists nowhere else in the design.
