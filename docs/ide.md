# Admin IDE

## CLI first, IDE second

The **CLI** (see [cli.md](cli.md)) is the primary interface during initial development and is the fallback for disaster recovery. It must exist before the IDE and must remain independently functional. The CLI is more cumbersome but always available.

The Admin IDE is the **advanced end-goal interface**. Once built, its schema (diagram layouts, sidebar state, theme config) ships in DataCode's initial schema load, so DataCode arrives with the IDE ready to use. The IDE is self-hosting — it manages its own configuration through DataCode's normal table machinery.

Every action in the IDE must also be expressible as a CLI command.

## Purpose

DataCode includes a built-in administrative IDE for managing the schema, connectors, access control, and system configuration. The IDE is itself a DataCode application — it runs against the DataCode schema using the same query and UI generation machinery as any other application. This means:

- The IDE schema lives in `system.ide.*`, and `system` is a namespace rather than a shard — each IDE table carries whichever replication trait fits it (see [namespaces.md](namespaces.md#relationship-to-shards))
- IDE configuration (which namespaces are visible, layout preferences, saved views) is stored in DataCode tables
- The IDE is rendered using DataCode's HTML rendering engine with a dedicated IDE theme
- The IDE reaches `system.*` because its `system.auth.Client` row says so — it registers as the `AdminIde` client kind — never because of the host it is served from. Schema-level reach is what a `Client` row decides; row-level filtering is what an assert decides (see [auth.md](auth.md#schema-level-access-and-bypass))
- The IDE can be accessed via browser (thin client) or the thick client application

## Components

### ER diagram view

The primary workspace. Displays tables as nodes and functors as edges in a graph layout.

**Node content**: Each table node shows:
- Table name (fully qualified or short, depending on zoom level)
- Field list (collapsed or expanded, configurable)
- Visibility level badge (`system`, `connector`, `internal`, `standard`, `featured` — the five levels of [namespaces.md](namespaces.md#schema-visibility-layers))
- Shard assignment indicator

**Edge types** (filterable by functor type):
- Foreign key functors → solid directed arrow
- Path constraint functors → dashed edges along the paths the body walks, one style per shape: double-headed for a data match, because an equality is symmetric; single-headed along the join chain for a presence query; the same edge struck through for an absence. The three shapes are [schema/constraints.md](schema/constraints.md#the-three-shapes)'s, and an equality-only edge cannot draw the two the kind was widened to cover
- Access asserts → the same edges, badged and toggled as one layer. An access assert *is* a path constraint whose body mentions `authed_user`, so the diagram reads the badge off the body rather than off a second kind of declaration (see [schema/constraints.md](schema/constraints.md#the-variety-is-decided-by-the-body))
- Type validation functors → not shown as edges (shown as field annotations)

**Auto-layout algorithms**:
- **Sugiyama (layered)**: default for hierarchical schemas — works well when foreign key chains form a clear hierarchy.
- **Force-directed**: for general graphs with many cycles — spreads nodes organically.
- **Manual positioning**: user can drag nodes; positions are saved in system tables per user per diagram view. Manual positions override auto-layout for moved nodes only.
- **Namespace clustering**: tables are visually grouped by namespace with a bounding box. Layout algorithms respect cluster boundaries.

Which engine computes a layout is [OQ-021](open-questions.md#oq-021-ide-graph-layout-library), and the candidates sit in one place, under [Technology](#technology). The canvas consumes node positions and does not care where they were computed.

**Zoom and pan**: Standard canvas interaction. At low zoom, only table names are visible. At medium zoom, field names appear. At high zoom, field types and functor annotations appear.

### Namespace sidebar

A collapsible tree panel on the left side. Shows the full namespace tree:

```
▾ app
  ▾ commerce
    ⊡ Order            [standard]
    ⊡ Customer         [standard]
    ⊡ OrderLine        [standard]
  ▾ reporting
    ⊡ MonthlySummary   [standard]
▾ connectors           (hidden by default, expandable)
  ▾ mariadb
    ▾ production
      ⊡ Order          [connector]
      ⊡ Customer       [connector]
▸ system               (hidden by default)
▸ reference
```

Namespace segments are lowercase and table names are `UpperCamelCase` and singular, connector shadow schemas included — the tree renders the declared name, and the convention is [schema/README.md](schema/README.md#capitalization)'s.

**Actions from sidebar**:
- Click a table → select it in the ER diagram (centers and highlights)
- Drag a table from sidebar → add it to the current diagram working set
- Right-click → set visibility, move to namespace, open table detail view
- Filter box at top of sidebar → fuzzy search across all table names

**Working set**: The ER diagram shows a subset of all tables (the "working set") rather than all tables simultaneously. The sidebar is the mechanism for adding/removing tables from the working set. This prevents the diagram from becoming unusably dense on large schemas.

### Filter layers

Toolbar overlays that toggle visibility of different functor types on the diagram:

| Filter | What it shows |
|---|---|
| Foreign keys | Relational arrows between tables |
| Path constraints | The paths an `assert` body walks — data match, presence, absence |
| Access asserts | The subset of those whose body mentions `authed_user` |
| Connector mappings | How DataCode tables map to connector shadow schemas |
| Schema visibility | Color-codes nodes by visibility level |

There is one access layer, not one per token type: an assert names exactly one token binding, `authed_user`, and there is no `authed_client` to color against.

Filters can be combined. The default view shows foreign keys only.

### Table detail panel

Opened by double-clicking a table node or clicking in the sidebar. Shows:
- All fields with types and validation functor annotations
- All functors involving this table
- Schema version history (links into the schema transaction graph)
- Connector mapping (if this table is backed by or linked to a connector shadow schema)
- PageRank weight (calculated importance score)
- Shard assignment
- Access summary — the grants that reach the table, and the asserts that narrow it with the access-classified ones marked (see [schema/constraints.md](schema/constraints.md#the-variety-is-decided-by-the-body))

### Functor editor

A structured form for defining and editing functors. Not a raw code editor — each functor kind has its own form layout (see [schema/functors.md](schema/functors.md)):

- **Validation**: field selector + DSL expression builder + error message template
- **Foreign key**: source table/field + target table/field + optional resolver config
- **Path constraint**: one form with three body shapes, matching [schema/constraints.md](schema/constraints.md#the-three-shapes) — a data match between two paths, a presence query rooted at `self`, or `not` of one for absence. The form never asks which variety is being written: the IDE reads the access badge off the body mentioning `authed_user`, which is the same structural test `bypass access` uses, and surfaces the commit-time reclassification message when an edit changes it (see [schema/constraints.md](schema/constraints.md#reclassification-is-reported)). Classifying by term position would misread the mixed conjunct and the disjunction, where the token appears in a non-leading term
- **Event**: producing table + queue selector + payload builder, in the two trigger modes the grammar has — `on <condition> emit <queue> { <payload> }` for a transition, and `every <interval> emit <queue> { <payload> } where <condition>` for a sampled trigger, whose interval field takes a literal, a row field, or a `Configuration` path. The queue's own `handler` is edited on the queue table, not here — the two ends are separate declarations. A trigger over a `Behavior` should show the solved crossing moment as a preview; that half is blocked on [OQ-034](open-questions.md#oq-034-behavior-triggered-event-scheduling)

Advanced users can toggle to a raw DSL text editor for the expression. The IDE previews the functor's effect on sample data before saving.

### Integrity panel

The review queue for nonconforming data, and the reason the mechanism is worth building —
detection without a place to look at the results is a slower failure.

- **Grouped by functor**, worst first: which rule is broken, by how many rows, since when.
  This reads a materialized view grouped by `functor`, so the panel loads at view-read cost
  rather than re-aggregating per visit
  (see [integrity.md](integrity.md#attachment-to-the-functor-is-logical-not-physical)).
- **Drill into a functor** to see affected rows, the schema node under which each violates,
  and whether the finding is `Derived`, `Observed`, or `Forced`.
- **Waive, acknowledge, or raise** a violation — ordinary mutations against
  `system.integrity.Violation`, so the panel is a view over a table rather than a special
  API.
- **Blast-radius preview** when editing a validation in the functor editor: before commit,
  the panel reports how many existing rows a proposed predicate would mark, which is what the
  mandatory-mode rule requires the author to see.

**Unified with the connector conflict queue.** A conflict is two systems disagreeing; a
violation is one system sending data that is invalid here. Both are "something is wrong with
the data and a person needs to decide" — an operator should not have to check two places to
find out what needs attention.

Because violations live in the shard holding the subject row, the panel's queries are
distributed and merged (see
[distribution.md](distribution.md#materialized-view-distribution)), and the panel reports
which shards contributed so partial results are never mistaken for clean ones.

### Connector management

A dedicated panel (separate from the ER diagram) for managing connectors:
- List of all configured connectors with status (connected, lagging, error)
- Per-connector sync lag, reported **per source**: a stored position is a set of rows, one per MariaDB `domain_id` or MySQL `source_uuid`, not a scalar (see [connectors.md](connectors.md))
- State verification results (last run, discrepancy count)
- Conflict queue (unresolved conflicts awaiting manual review) — the same queue the integrity panel shows, and the same rows `show connector conflicts` prints
- Configuration editor over `system.connectors.Connector`
- Schema mapping view (which connector shadow tables map to which app tables)

### Schema transaction graph browser

A simplified DAG view of the schema transaction history:
- Commit nodes with timestamp, description, and affected namespaces
- Diff between any two nodes (what changed)
- Ability to pin a query or view to a historical schema node
- Branch visualization for A/B schema variants

The browser reads `system.graph.Transaction`, so it is a view over a table rather than a special
API — the same self-hosting move that makes the integrity panel a query (see
[transaction-graph.md](transaction-graph.md)).

---

## Technology

The IDE is a DataCode application using a dedicated `ide` theme. The theme provides:

**Server-side (Haskell)**:
- Schema graph queries — standard DataCode query engine
- PageRank computation over the schema graph
- Graph layout, where the engine selected in [OQ-021](open-questions.md#oq-021-ide-graph-layout-library) runs on the server; the server then returns node positions as JSON

**Client-side (browser)**:
- The ER diagram canvas — node and edge rendering, zoom and pan
- The namespace tree sidebar
- Standard HTML/CSS for forms and panels

The IDE requires no JavaScript framework. It is server-rendered HTML enhanced with a canvas library for the diagram and whichever layout engine OQ-021 selects, and that dependency set is the whole of it. All state (diagram working set, node positions, filter settings) is stored in DataCode system tables and reloaded on page load.

**DataCode serves its own assets.** The canvas library, the layout engine and the IDE theme's stylesheet are `File` rows served by DataCode, never fetched from an external CDN — DataCode is the origin, which is why `File` carries a media type (see [schema/types.md](schema/types.md#files)).

**Graph layout libraries under consideration** — the choice is [OQ-021](open-questions.md#oq-021-ide-graph-layout-library), and this is the one place the candidates are listed:
- `graphviz` (external process) — mature, supports Sugiyama (dot layout), produces good hierarchical layouts. Haskell binding: `graphviz` on Hackage.
- `d3-dag` — client-side DAG layout in D3.js, reasonable for smaller graphs
- ELK.js (Eclipse Layout Kernel) — comprehensive graph layout algorithms including Sugiyama, runs in browser or as a service. Best option for large complex schemas.

**Recommendation**: Use ELK.js client-side for interactive layout (it handles large graphs well and runs in WebWorkers to avoid blocking the UI) with server-side `graphviz` as a fallback for non-interactive exports (SVG/PNG export of ER diagrams). It needs validation, so no other section names an engine.

---

## Schema visibility in the IDE

The IDE is the primary mechanism for managing schema visibility:

1. **Default view**: Shows only `standard` and `featured` tables in the namespace tree and ER diagram
2. **Connector schemas**: Collapsed under `connectors/` in sidebar, excluded from diagram by default. User explicitly adds connector tables to the working set to see them.
3. **System tables**: Hidden until the user enables system visibility, and enabling it shows only what the request may already reach — the client scope decides which tables are reachable at all, and the user's grants decide the rest (see [auth.md](auth.md#schema-level-access-and-bypass) and [namespaces.md](namespaces.md#namespace-access-control)). Visibility is a presentation hint, never an access control
4. **Visibility override**: Right-click any table → "Change visibility" → updates the schema graph node (recorded as a schema transaction)

The information density value (see [api-and-rendering.md](api-and-rendering.md#information-density-windowing)) also applies to the IDE — a high-density user sees more fields and annotations by default; a low-density user sees a cleaner, more abstract view.

---

## Open questions

- [OQ-021: IDE graph layout library](open-questions.md#oq-021-ide-graph-layout-library)
- [OQ-022: IDE bootstrapping](open-questions.md#oq-022-ide-bootstrapping) — the placement half is settled and stated in [Purpose](#purpose); what remains open is how the IDE renders when the only schema is `system.*`
- [OQ-023: IDE conflict resolution UI](open-questions.md#oq-023-ide-conflict-resolution-ui)

The bodies live in `open-questions.md`. Restating them here is what let this list drift a number out of step with the file it points at.
