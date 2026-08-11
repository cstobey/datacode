# Admin IDE

## CLI First, IDE Second

The **CLI** (see `cli.md`) is the primary interface during initial development and is the fallback for disaster recovery. It must exist before the IDE and must remain independently functional. The CLI is more cumbersome but always available.

The Admin IDE is the **advanced end-goal interface**. Once built, its schema (diagram layouts, sidebar state, theme config) is included in the initial system shard load so DataCode ships with the IDE ready to use. The IDE is self-hosting — it manages its own configuration through DataCode's normal table machinery.

Every action in the IDE must also be expressible as a CLI command.

## Purpose

DataCode includes a built-in administrative IDE for managing the schema, connectors, access control, and system configuration. The IDE is itself a DataCode application — it runs against the DataCode schema using the same query and UI generation machinery as any other application. This means:

- The IDE schema is stored in the `system` namespace
- IDE configuration (which namespaces are visible, layout preferences, saved views) is stored in DataCode tables
- The IDE is rendered using DataCode's HTML rendering engine with a dedicated IDE theme
- The IDE can be accessed via browser (thin client) or the thick client application

## Components

### ER Diagram View

The primary workspace. Displays tables as nodes and functors as edges in a graph layout.

**Node content**: Each table node shows:
- Table name (fully qualified or short, depending on zoom level)
- Field list (collapsed or expanded, configurable)
- Visibility level badge (`connector`, `internal`, `standard`, `featured`)
- Shard assignment indicator

**Edge types** (filterable by functor type):
- Foreign key functors → solid directed arrow
- Path equivalence constraint functors → double-headed dashed line
- Access control functors → colored overlay (separate filter layer)
- Type validation functors → not shown as edges (shown as field annotations)

**Auto-layout algorithms**:
- **Sugiyama (layered)**: default for hierarchical schemas — works well when foreign key chains form a clear hierarchy. Library: likely `graphviz` layout engine via process call, or a Haskell port of the algorithm.
- **Force-directed**: for general graphs with many cycles — spreads nodes organically. D3.js `d3-force` can handle this client-side.
- **Manual positioning**: user can drag nodes; positions are saved in system tables per user per diagram view. Manual positions override auto-layout for moved nodes only.
- **Namespace clustering**: tables are visually grouped by namespace with a bounding box. Layout algorithms respect cluster boundaries.

**Zoom and pan**: Standard canvas interaction. At low zoom, only table names are visible. At medium zoom, field names appear. At high zoom, field types and functor annotations appear.

### Namespace Sidebar

A collapsible tree panel on the left side. Shows the full namespace tree:

```
▾ app
  ▾ commerce
    ⊡ orders           [standard]
    ⊡ customers        [standard]
    ⊡ order_lines      [standard]
  ▾ reporting
    ⊡ monthly_summary  [standard]
▾ connectors           (hidden by default, expandable)
  ▾ mariadb
    ▾ production
      ⊡ orders         [connector]
      ⊡ customers      [connector]
▸ system               (admin only)
▸ reference
```

**Actions from sidebar**:
- Click a table → select it in the ER diagram (centers and highlights)
- Drag a table from sidebar → add it to the current diagram working set
- Right-click → set visibility, move to namespace, open table detail view
- Filter box at top of sidebar → fuzzy search across all table names

**Working set**: The ER diagram shows a subset of all tables (the "working set") rather than all tables simultaneously. The sidebar is the mechanism for adding/removing tables from the working set. This prevents the diagram from becoming unusably dense on large schemas.

### Filter Layers

Toolbar overlays that toggle visibility of different functor types on the diagram:

| Filter | What it shows |
|---|---|
| Foreign keys | Relational arrows between tables |
| Path equivalence | Commutative diagram constraints (business rules) |
| Access control | Which tokens can traverse which paths (color-coded by token type) |
| Connector mappings | How DataCode tables map to connector shadow schemas |
| Schema visibility | Color-codes nodes by visibility level |

Filters can be combined. The default view shows foreign keys only.

### Table Detail Panel

Opened by double-clicking a table node or clicking in the sidebar. Shows:
- All fields with types and validation functor annotations
- All functors involving this table
- Schema version history (links into the schema transaction graph)
- Connector mapping (if this table is backed by or linked to a connector shadow schema)
- PageRank weight (calculated importance score)
- Shard assignment
- Access control summary (which token types can read/write which fields)

### Functor Editor

A structured form for defining and editing functors. Not a raw code editor — each functor kind has its own form layout (see `schema/functors.md`):

- **Validation**: field selector + DSL expression builder + error message template
- **Foreign key**: source table/field + target table/field + optional resolver config
- **Path equivalence — data constraint**: two path selectors through the schema graph + description
- **Path equivalence — access control**: token type selector + path condition builder. Same underlying functor as the data-constraint variety; the form differs only in that the left term is a token path
- **Event**: queue table selector + handler functor selector + trigger condition. Blocked on the event functor surface syntax, which is not yet defined

Advanced users can toggle to a raw DSL text editor for the expression. The IDE previews the functor's effect on sample data before saving.

### Integrity Panel

The review queue for nonconforming data, and the reason the mechanism is worth building —
detection without a place to look at the results is just a slower failure.

- **Grouped by functor**, worst first: which rule is broken, by how many rows, since when.
  This reads a materialized view grouped by `functor`, so the panel loads at view-read cost
  rather than re-aggregating per visit
  (see [integrity.md](integrity.md#attachment-to-the-functor-is-logical-not-physical)).
- **Drill into a functor** to see affected rows, the schema node under which each violates,
  and whether the finding is `Derived`, `Observed`, or `Forced`.
- **Waive, acknowledge, or raise** a violation — ordinary mutations against
  `system.integrity.violations`, so the panel is a view over a table rather than a special
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

### Connector Management

A dedicated panel (separate from the ER diagram) for managing connectors:
- List of all configured connectors with status (connected, lagging, error)
- Per-connector sync lag indicator (how far behind the connector log is)
- State verification results (last run, discrepancy count)
- Conflict queue (unresolved conflicts awaiting manual review)
- Configuration editor (maps to the `system.connectors` table)
- Schema mapping view (which connector shadow tables map to which app tables)

### Schema Transaction Graph Browser

A simplified DAG view of the schema transaction history:
- Commit nodes with timestamp, description, and affected namespaces
- Diff between any two nodes (what changed)
- Ability to pin a query or view to a historical schema node
- Branch visualization for A/B schema variants

---

## Technology

The IDE is a DataCode application using a dedicated `ide` theme. The theme provides:

**Server-side (Haskell)**:
- Graph layout computation (Sugiyama) — runs on the server, returns node positions as JSON
- Schema graph queries — standard DataCode query engine
- PageRank computation over schema graph

**Client-side (browser)**:
- D3.js for the ER diagram canvas (force-directed layout, node/edge rendering, zoom/pan)
- D3.js for the namespace tree sidebar
- Standard HTML/CSS for forms and panels

The IDE does not require any JavaScript framework beyond D3.js — it is server-rendered HTML enhanced with D3.js for the diagram canvas specifically. All state (diagram working set, node positions, filter settings) is stored in DataCode system tables and reloaded on page load.

**Graph layout libraries under consideration**:
- `graphviz` (external process) — mature, supports Sugiyama (dot layout), produces good hierarchical layouts. Haskell binding: `graphviz` on Hackage.
- `d3-dag` — client-side DAG layout in D3.js, reasonable for smaller graphs
- ELK.js (Eclipse Layout Kernel) — comprehensive graph layout algorithms including Sugiyama, runs in browser or as a service. Best option for large complex schemas.

**Recommendation**: Use ELK.js client-side for interactive layout (it handles large graphs well and runs in WebWorkers to avoid blocking the UI) with server-side `graphviz` as a fallback for non-interactive exports (SVG/PNG export of ER diagrams).

---

## Schema Visibility in the IDE

The IDE is the primary mechanism for managing schema visibility:

1. **Default view**: Shows only `standard` and `featured` tables in the namespace tree and ER diagram
2. **Connector schemas**: Collapsed under `connectors/` in sidebar, excluded from diagram by default. User explicitly adds connector tables to the working set to see them.
3. **System tables**: Hidden unless the user has a system token and explicitly enables system namespace visibility
4. **Visibility override**: Right-click any table → "Change visibility" → updates the schema graph node (recorded as a schema transaction)

The information density value (see api-and-rendering.md) also applies to the IDE — a high-density user sees more fields and annotations by default; a low-density user sees a cleaner, more abstract view.

---

## Open Questions

- **OQ-021**: What graph layout library is used for the ER diagram? ELK.js (client-side) vs. `graphviz` (server-side) vs. D3.js force-directed?
- **OQ-022**: Is the IDE a separate DataCode application (its own shard, its own namespace) or deeply integrated into the server itself? Separate is cleaner for upgrades; integrated avoids bootstrapping issues.
- **OQ-023**: The IDE needs to be usable before any application schema is defined (bootstrapping). How does the IDE render when the only schema is the `system` namespace?
- **OQ-024**: Conflict resolution UI — what does the manual conflict review interface look like? Side-by-side diff? Time-ordered log view?
