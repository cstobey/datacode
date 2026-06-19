# API and Rendering

## Content-Type Dispatch

DataCode's web layer serves different representations of the same data based on the HTTP `Content-Type` / `Accept` header. All representations are derived from the same schema graph — no separate API definition required.

| Content-Type | Audience | Format | Notes |
|---|---|---|---|
| `application/x-datacode` (TBD) | Servers, thick clients | Binary (TBD) | Full replication fidelity; carries provenance and schema version |
| `application/json` | Third-party integrations | JSON | Auto-generated; analogous to auto-generated GraphQL |
| `text/html` | Thin clients (browsers) | HTML + CSS | Rule-based rendering from schema graph |
| `text/html` + `application/json` | Browser SPAs | HTML + D3.js | Used for data visualization and interactive views |

The binary format for server-to-server and thick client communication is TBD. Candidates: Cap'n Proto, MessagePack, or a custom format. Key requirements: carries type provenance, schema version reference, and sequence numbers.

## JSON API (Third-Party Integration)

The JSON API is automatically generated from the schema, similar to how GraphQL introspection works:
- Each table becomes a resource endpoint
- Foreign key functors become nested objects or links (configurable)
- Access control functors are applied — the JSON response only contains what the token can see
- Field types are mapped to JSON types; `NOT_FOUND` / `Maybe` fields become nullable JSON (the only place JSON null appears)
- Mutations are typed by the schema — the request body must conform to the table's type

## HTML Rendering (Thin Clients)

Thin clients (web browsers) receive server-rendered HTML. Thick clients running locally can render the same HTML locally, in which case the server only sends replication data (delta sync), not rendered pages.

### Schema Linearization

The schema graph is linearized by **importance** — a numeric weight computed per data element using a PageRank-style algorithm over the schema graph:

- **Centrality**: how many other tables reference this table (in-degree)
- **Integration**: how many relationships this table participates in (total degree)
- PageRank is computed on the schema category (tables as nodes, foreign key functors as edges)
- The result is a ranked list of tables and fields ordered by structural importance to the schema

This ranking drives UI layout: more central data elements appear more prominently (earlier, larger, more detail).

### Information Density Windowing

Each user has a numeric **information density value** (an integer preference). The linearized schema is windowed by this value:
- Data elements with importance weight ≤ density value are shown
- Data elements above the threshold are hidden or collapsed
- Fields on the same table are kept together (the table is the atomic unit for windowing purposes)
- This allows the same schema to render as a simple summary view for casual users and a detailed view for power users

### Relationship Rendering (Weighted Cardinality)

One-to-one and one-to-many relationships are rendered based on **weighted cardinality**:
- `weight = f(element_count, element_size)` — a tunable function
- Low weight → compact controls (radio buttons, checkboxes, simple selects)
- High weight → full browsing interfaces (search-as-you-type, paginated tables, "shopping cart" style pickers)

Progression (approximate, to be refined):
1. Single radio button / checkbox (1 option)
2. Radio group / checkbox list (2–5 options)
3. Select dropdown (6–20 options)
4. Typeahead / autocomplete (20–200 options)
5. Searchable list with preview (200–2000 options)
6. Full browsing interface / "shopping cart" (2000+ options or large element size)

The thresholds and the cardinality weight function are tunable per application and overridable per field.

### Themes

A theme defines:
- A **CSS stylesheet** (global component library and style guide)
- **Render functions per type** — how each DataCode type is rendered to HTML (e.g., `Timestamp` might render as a relative time or an absolute date depending on theme)
- Optional view selection (via HTTP header or user preference) — multiple themes can coexist and be selected per request

Themes are stored as **reference data** in normal DataCode tables. They can be:
- Shipped with the DataCode system (default themes)
- Defined by the application layer
- Queried, extended, and modified through the normal schema interface

### HTML Generation Algorithm (Sketch)

```
1. Authenticate request; determine token capabilities
2. Load schema graph at current head
3. Compute PageRank weights over schema graph
4. Window schema by user's information density value
5. For each visible table (in PageRank order):
   a. Render fields using type's render function for active theme
   b. For each relationship: compute weighted cardinality; select rendering level
   c. Apply access control functors: hide fields/relationships the token cannot see
6. Apply theme CSS
7. Return rendered HTML
```

## Thick Client Local Rendering

A thick client holds a local replica of the schema and data (within its access scope). It can:
- Render HTML locally using the same algorithm as the server
- Only request data delta syncs from the server (not re-rendered pages)
- Cache materialized views locally for offline or low-latency operation
- Submit mutations to the primary server when connectivity allows

This means thick clients behave like local read replicas with write-forwarding, consuming the binary replication protocol rather than the JSON or HTML APIs.
