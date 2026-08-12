# Open Questions and Deferred Decisions

Questions that need answers before or during implementation. Grouped by urgency.

## Must Resolve Before Writing Core Code

### OQ-001: Dynamic Loading Mechanism ✓ ANSWERED
**Answer**: GADT DSL + Data.Dynamic hybrid. See `spikes/dynamic-loading/output.txt`.
- **GADT DSL** (Approach 2): primary functor mechanism. All four functor kinds must be encodable: validation, foreign key, path equivalence (in both its data-constraint and access-control varieties), and event (the event functor enqueues a work item rather than executing immediately — see `events.md`). Spike validated the first three; the event functor requires a DSL extension that produces an `EventRef` (queue table row insert) instead of `Either Error a`. Zero runtime GHC dependency. ~0µs apply latency. Ceiling: regex and recursive types require DSL extensions; user-defined functions require new DSL constructors.
- **Data.Dynamic** (Approach 3): type registry substrate. TypeRep-based type checking is O(1). Serves as the "registered type library" that the DSL references by name.
- **hint** (Approach 1): failed to compile in the spike — GHC not on PATH or hint version mismatch. Revisit as an escape hatch for advanced user-defined functors; compile async and sandbox the result.
- **Multi-daemon**: needed when compiled-in types must change (requires server restart to load new Haskell modules); the schema daemon restarts are coordinated by a supervisor.

### OQ-002: Servant + Dynamic Schema ✓ ANSWERED
**Answer**: Servant + Warp works. The pattern is `"schema" :> Capture "ns" String :> Capture "name" String :> Raw`. Servant handles the static URL structure; the `Raw` endpoint delegates to an IORef-backed WAI dispatch table for runtime-dynamic routing. No Yesod needed for the data plane. See `spikes/servant-warp/output.txt`.

### OQ-003: Binary Replication Format ✓ ANSWERED
**Answer**: Cap'n Proto for production; cereal during initial development. See `spikes/capnproto/output.txt`.
- **cereal** (used in storage spike): same length-prefix framing as Cap'n Proto, no external toolchain, identical structural design. Ceiling: schema evolution requires an explicit version byte and branching decoder — adding a field to `TxNode` breaks old decoders without code.
- **Cap'n Proto confirmed** (capnproto spike): wire format implemented and validated. Encode/decode round-trip passes all fields including parent locator lists. Encode and full decode both sub-µs (timer resolution of 10k-iteration benchmark insufficient to distinguish; confirmed < 1µs/tx).
- **mmap zero-copy confirmed**: 112-byte TxNode message written to disk, mmap'd back, fields read at fixed byte offsets (e.g. timestamp at message byte 16) with no decode pass. The OS page cache backs the ByteString — no heap allocation.
- **Schema evolution confirmed**: V1 message (dataWords=2) read by V2 decoder → new field defaults to 0. V2 message (dataWords=3) read by V1 decoder → extra data word silently ignored. No version byte, no branching decoder, no migration step. V1=112 bytes, V2=120 bytes (+8 bytes for one new field).
- **Protobuf is NOT a substitute**: Protobuf requires full parsing; Cap'n Proto mmaps the bytes directly.
- **Migration path**: use `cereal` in `Serialize` instances during development; swap to capnp-generated `Cerialize`/`Decerialize` instances before production. Wire framing is identical — only the payload encoding changes. Requires `capnp` C++ tool at compile time (`apt install capnproto`).

### OQ-004: Storage Engine ✓ ANSWERED
**Answer**: Hybrid architecture confirmed. See `spikes/storage/output.txt` and `spikes/capnproto/output.txt`.
- **Append-only log** (Cap'n Proto frames on disk): the transaction graph. Immutable, sequentially written, mmap-readable without deserialization. Random access by `LogEntry { offset :: Word64, length :: Word32 }` is O(1) seek+read.
- **LMDB `log_index`** (`PhysicalLocator → LogEntry`): finds any row version in the append log by locator. Keys are 14-byte big-endian locators; big-endian encoding means a range scan over all rows in a transaction is a single contiguous LMDB range.
- **LMDB `head_index`** (`DataId → current PhysicalLocator`): resolves the user-visible primary key to the current head version.
- **Full zero-copy read path**: `DataId → head_index → PhysicalLocator → log_index → (file_offset, len) → mmap[offset:len] → Cap'n Proto → pointer arithmetic`.
- **Naming note**: the spike code calls the physical address `RowId`. It is `PhysicalLocator` in the design docs — `RowId` read as "the id of a row", which is what `DataId` is, and the collision was the source of recurring confusion. See `transaction-graph.md`.
- **LMDB threading fix confirmed**: requires `-threaded` in ghc-options AND wrapping the LMDB session in `runInBoundThread` (session-level, not per-operation). The `lmdb` Haskell package calls `isCurrentThreadBound` before acquiring its write lock; without `-threaded`, this always returns False. See `spikes/capnproto/src/Spike/LmdbFixed.hs`.
- **LMDB latency**: read 11µs/op, write 1,107µs/op. Write latency is high because LMDB calls `fdatasync()` on every transaction commit by default (durability guarantee). **This is not a problem** — DataCode batches multiple mutations into a single transaction. At 10–100 mutations/tx, the per-mutation cost is 11–110µs, which is acceptable. Single-mutation micro-benchmarks are not representative of production write patterns.
- **Production LMDB pattern**: dedicate one OS-bound thread (via `forkOS`) for all LMDB writes, with a `TQueue` for serialization. Readers are concurrent (LMDB MVCC — readers never block writers).

### OQ-026: API Version Token Format ✓ ANSWERED
**Answer**: Three interchangeable version token types, all valid as the `{version}` segment in `/v{version}/...` API paths:

- **Graph node hash prefix** (canonical default): content-addressed, always deterministic. The underlying identity of every schema node. Guaranteed unambiguous across servers, shard splits, and merges.
- **Tag**: a fixed-point alias for a specific graph node. Tags do not move after creation. Techs attach tags to commits as part of a transaction; tags are the expected primary UX for human-readable version pinning (e.g. `v2.1.0`, `stable-2026-q2`).
- **Branch name**: a moving alias that always resolves to the current HEAD of a named branch (e.g. `main`, `experiment-checkout`). Advances automatically as new commits land on that branch.

All three resolve to the same thing at dispatch time: token → schema graph node hash → routes registered at that node. The hash prefix is the lowest-level escape hatch that works even when no tag or branch name has been declared.

**No-version behavior**: Requests without a version token are routed to the `main` branch HEAD by default. The server can also route unversioned requests across A/B test branches at a configurable rate; routing decisions persist via session affinity so the same client consistently receives the same branch across requests.

**Promoting a version going forward**: A well-known alias URL (e.g. `/vcurrent/`) redirects to whichever tag or branch is currently designated. The `/versions` discovery endpoint lists all live tokens and marks the promoted one. Together these allow operators to tell existing clients "use this tag from now on" without requiring client code changes.

**Policy**: All branches must be named — anonymous DAG forks are not permitted. The `main` branch cannot be deleted. See the Branch and Tag lifecycle documentation in `transaction-graph.md`.

### OQ-027: API Functor Type and Transaction Semantics ✓ ANSWERED

- **Typing**: No separate API functor type. Field types are referenced directly from the schema everywhere they are used — the schema IS the type system. Auto-generated routes are fully typed by the table definition.
- **Transaction semantics**: Reads and writes share the same transaction graph snapshot. The primary server linearizes and executes transactions one at a time. Cross-shard transactions require all shard primaries to agree: a cross-server lock is taken on a `transaction_id` across the involved shards and held until all operations complete. Consequence: the system should group related shards on the same server, and should prefer placing the primary close to the users making requests.
- **Error signaling**: The transaction is atomic — it either fully commits or fully fails. On failure, only the HTTP request log is written (to a per-server system shard that always succeeds independently). The error is returned to the client. 500s should be avoided; all known failure modes return 4xx.
- **Event functors**: Internal events (e.g., index updates, view refresh) resolve within the transaction as they occur. External side effects (email, webhooks, etc.) are never executed inline — they are written to a queue table and processed asynchronously by the event scheduler functor. No external calls from within a transaction.

### OQ-028: Route Conflict Resolution ✓ ANSWERED

- **Custom routes shadow auto-generated at the same path.** The most useful behavior — registering a custom route at `/records/app.commerce.Order/{id}` clearly intends to override the generated handler.
- **Reserved `raw/` prefix**: `/v{N}/raw/<table-path>` is always auto-generated; custom routes starting with `raw/` are rejected at insert time. This guarantees the auto-generated handler is always reachable.
- **Path validation**: custom routes under `/records/` must reference an existing table/view; phantom overrides are rejected at insert time.
- **Version semantics**: custom routes are schema objects in the transaction graph — no routing-mode flag on branches or tags needed. A version token resolves to a schema node, and the routes at that node (generated + any custom overrides) follow naturally.
- **Version ref uniqueness**: branches and tags share `system.VersionRef` with a `VersionRef` ADT (`Branch DataId | Tag DataId`). The `Tag` variant's immutability is enforced by a validation functor. No discriminator column — the type encodes the rule.

### OQ-029: Route Trie vs. Dispatch Table Implementation ✓ ANSWERED
**Answer**: Hand-rolled route trie. See `spikes/route-trie/output.txt`.
- **Route trie confirmed**: 0.2µs/request at 10k registered routes — well under the 1µs target. O(depth × log fanout), independent of total route count.
- **Linear scan ruled out**: 1µs at 100 routes, 13µs at 1k routes, 132µs at 10k routes. Scales O(n) — fails the target beyond a handful of custom routes.
- **wai-routes ruled out**: uses Template Haskell compile-time route tables — incompatible with DataCode's runtime-registered custom routes.
- **path-piece ruled out**: a type class for parsing individual path segments, not a router.
- **Precedence**: static segments always beat captures at the same depth — correct, deterministic, matches every mainstream router.
- **Integration**: replace `IORef (Map String Application)` in the Servant `Raw` handler with `IORef (RouteTrie Application)`. Schema changes rebuild the trie and atomically swap the IORef — zero request interruption.
- **Conflict resolution** (answers OQ-028 partially): exact-path conflicts are a schema validation error at insert time. The trie's `nodeHandler` slot can only hold one handler; inserting a duplicate pattern is rejected.

## Must Resolve During Core Development

### OQ-005: Schema DSL Syntax ✓ ANSWERED
**Answer**: Designed. See `docs/schema/` (normative syntax reference, one file per topic),
`docs/schema/railroad.md` (full EBNF + railroad diagrams), `docs/cli.md` (REPL and admin
commands), `docs/auth.md` (ACL model), and `docs/category-model.md` (the categorical
rationale). The decision record is the bullet list below plus OQ-030 and OQ-031.

Key decisions:
- **Tables**: `table Name : Trait1, Trait2 { field : Type = default, order by field }` — DataId PK implicit
- **Types**: `type Email : Text where isValidEmail` — colon = "is a kind of"; sum types `A | B`; absence types `type X : Null`
- **Validation**: `where <predicate>` as a trailing clause on a type or field declaration. Replaces the earlier tentative `{ validate: ... }` block. **One `where` per declaration**, Haskell-style: the body is a single predicate inline, or an indented block of predicates that are implicitly conjoined. No repeated `where`, no `and` between block entries.
- **Validation addressing**: a field's `where` is addressed by the field's path (`app.commerce.Customer.email`), which is also the name of its computed field type — no separate naming syntax. `assert` must be named because it spans two paths and has no single field path to inherit. Origin addresses survive trait inheritance, so a merged field enforces `A.name`, `B.name`, and its own predicates, each individually addressable.
- **Termination**: inside a body, declarations are `,`-separated and closed by `}`; the separator may be leading or trailing (leading-comma style keeps block `where` readable), and a comma before `}` is allowed. At top level there is no separator — a declaration ends at the next token in column 0. Continuation in both cases is by indentation (offside rule), which is what delimits a block `where`.
- **References**: `:>` declares a foreign key (`customer :> Customer`). `:` requires a type on the right, `:>` requires a table or view; using the wrong one is a compile-time error. Replaces the earlier two-token `: -> Customer`.
- **Head rule**: in an alternation only the first variant decides the token, so `customer :> Customer | MissingCustomer` and `phone : Phone | NotGiven` both typecheck against a single `Null` root — no separate reference-absence hierarchy.
- **Clause order**: `field ( ":" | ":>" ) Type [rename from / from] [unique] [= default] [where pred]`. The default precedes `where` so an `=` inside a predicate is never ambiguous.
- **Inline sub-tables**: `address :> Address { ... }` — sugar for a sibling table plus an FK; there is no embedded product-in-row.
- **Traits**: abstract base types (`trait` keyword); tables extend via `:` syntax; replication traits (`Reference`, `UserData`, `LogData`, `Configuration`) are regular traits
- **Joins**: `><` bowtie operator; outer join = `Order >< Customer | MissingCustomer` (guard semantics — the same rule as a nullable `:>` field)
- **Constraints/ACL**: unified `assert name { expr }` keyword; `assert access { user.field == row.field }` for ACL. `where` is unnamed and field-scoped; `assert` is named and row-scoped.
- **Functor kinds reduced to four**: data constraints and access control are the *same* functor (path equivalence), differing only in whether the left path term is a data path or the requesting token. That difference determines when it runs (commit vs. read+write) and what a read failure does (`Redacted` rather than abort).
- **Schema evolution**: redeclare table body; system diffs; `rename from` hint; same-name hides old type; `deprecate`/`prune` for removal
- **Scope**: top-level = global (stored in schema); `let` = local inside function bodies; REPL = transaction model (`:commit`/`:rollback`)
- **Equality**: `=` is binding only (field default, function definition, sum-type declaration, `let`, row construction and update), `==` is comparison, `is` is constructor match ignoring payload. Follows Haskell. Resolves the earlier doubling where `=` also meant exact value equality.
- **Operator spelling** follows Haskell: `==`, `/=`, `&&`, `||`, `not`, `True`, `False`. No `!=`, `and`, or `or` (OQ-031).
- **Candidate keys are mandatory** on every table not carrying `LogData`, `Component`, or `Keyless`; `DataId` does not satisfy the rule, since counting the surrogate would make it vacuous. Default-on with a `Keyless` waiver rather than opt-in, matching enforcement modes where the strict setting is the default and weakening it is an explicit recorded act — and the opposite polarity from `Extensible`, because extensibility is a capability you choose while keylessness is a defect you admit. The exemption is not "logs are special": *occurrences have no identity beyond their occurrence, entities do*, which is why queue tables carry `LogData` too. Replaces the previous state where `unique` existed but nothing required it, leaving "default ordering: unique key ascending" undefined on keyless tables.
- **A key on a shard-local table must be rooted** — its FK chain must reach the shard root, transitively is fine, and FKs to `Reference`/`Configuration` do not participate. Consequence: **the key declaration is also the sharding declaration.** A `UserData` table whose key contains no same-family FK *is* a shard root; one whose key does is a dependent. No separate keyword, and it cannot drift, because adding an FK changes nothing unless it is put in the key. Where a key reaches two roots, the first FK decides — the same head rule that governs `:>`. The root table's own key is cluster-wide, but that index is the shard directory the router already needs, so it costs nothing; every other key is checked within one shard. Requires shards to be **row-rooted** (each `Customer` row roots a shard), which `shardOf :: DataId 'Row -> Maybe (DataId 'Shard)` and `split shard … at key` already implied but no document stated. See `transaction-graph.md`.
- **Continuous time**: `Behavior a ≅ Moment -> a` as a field type, for values that change with no write — accruing interest, countdowns, decaying limits. Nothing is stored; the value is computed from the row at the moment of observation. Exactly one parameter, always `Moment`, because two behaviors compose pointwise only over a shared domain and the scheduler can solve a crossing only over a domain it knows. `Moment` is distinct from `Timestamp` (stored, in a row) and is deliberately not called `CurrentTime`, since historical queries sample the past and the scheduler samples the future. `unique`, `indexed`, `order by`, and `where` are all rejected on a behavior, and behaviors are read-only. Reuse is via traits, not via a behavior-carrying type, because a behavior closes over sibling fields and only a trait can require them. A behavior is **not** a fifth functor kind — the four kinds each enforce something and a behavior is a projection.
- **Units are validation, not algebra.** `Duration`'s canonical unit is the millisecond; conversions are stdlib functions (`days`, `hours`, …) written at the use site, so `rate * days (t - opened_at)` says what `rate` means without a dimensional type system. Domain types narrow value sets; arithmetic operates on the underlying primitive. Dimensional typing was rejected as too large an addition for the benefit, and because it collides with functor transparency and the GADT DSL's ceiling (OQ-001).
- **Retention and rollups**: `aggregate <Name> = <query>` declares what to compute; `retain <Table> as <Name>` declares a chain of resolutions and how long each is kept. A chain never reshapes, which is why the aggregate is named once on the header — a differing step is unrepresentable rather than rejected. Terminals are `forever` (keep) and `drop` (discard); `never` was rejected because in a construct full of durations it reads as "never delete". Ordered `where`/`otherwise` branches partition a table, first match wins, as in a Haskell guard — one block rather than N statements, because order is load-bearing and separate statements have no reliable order. Chain aggregates must declare an associative merge with an identity (`count`/`sum`/`min`/`max` do; `avg` is silently rewritten to `(sum, count)`; `percentile` cannot and is rejected past one step) — phrased as a rule about merges rather than a whitelist so sketch types drop in later. `bucket_start` is injected into every generated level and `grain` is a virtual column, so `RequestRollup where grain == hour` selects a level with no new query syntax; the aggregate's plain name is the union view over all levels, making transparent querying the default and reaching into one level the marked case. **Pruning `LogData` is only ever a consequence of a chain** — there is no manual prune, and a table with no chain is never pruned, which is what closes OQ-032 structurally. A rollup is two appends (aggregate rows, then a prune node), never a rewrite of the transaction being summarized. Rollup levels are consequently real tables, not materialized views: a materialized view is recomputable from its source by definition, and here the source is gone.
- **View keys are derived, never declared.** A `unique` declaration in a view body is rejected. Every view has a key — a table is a set of tuples, so at worst the whole tuple is one — which makes *existence* the wrong question and **meaningful** (a proper subset identifying an entity) versus **degenerate** (all attributes) the right one. Propagation: `where` preserves; projection preserves iff every key column survives, else degenerates; `group` yields the group columns exactly, and exactly rather than approximately because DataCode's `group` nests instead of aggregating away; a `:>` join yields the referencing side's key alone and is lossless, with FK fields substituting to the referent's key so the key survives the FK column being projected away; a non-key join yields the union; a union of relations needs a discriminator that may not exist; an outer join degenerates when a key column comes from the outer side, for the same reason a declared key may not contain a `Null`-derived variant. Degeneracy is a **warning, not an error** — reporting views legitimately have no entity identity — but never silent, because a view claiming an identity it lacks would be trusted by merge reconciliation. Two things depend on the answer: a meaningful key admits **incremental refresh** (upsert by key) where a degenerate one admits only full recomputation; and an incrementally-maintainable view is a **candidate to replace its sources** — the general form of a retention chain superseding its raw table — while a degenerate one pins them, so `deprecate` on a source with a degraded dependent view is rejected until the view is altered or deprecated.
- **Capitalization** follows Haskell: types, traits, tables, views, and sum-type variants are `UpperCamelCase` and singular (a table is a type — `table T : Trait` uses the same `:` that `type A : B` does, and a row is an `Order`, not an `Orders`); fields are `lower_snake_case`; functions, predicates, and constraint names are `lowerCamelCase`; namespace segments are `lowercase`. The field/function split is deliberate — a field names stored data and reads as a column, a function is code and reads as Haskell. Capitalization is style checked by the linter, not grammar: `Ident` admits either case everywhere and position decides what a name is.
- **Guiding principle**: where a choice is otherwise balanced, pick the spelling a Haskell reader would expect. DataCode's operators may carry narrower meanings than Haskell's — `where` constrains rather than binds — but the shape should be familiar.
- **Open**: migration functor syntax (`evolution.md`); pagination config; UI template hints (`schema/traits.md`); package import scope (`schema/functions.md`); ACL token field access — what `user` exposes beyond `user.id` (`auth.md`)

### OQ-030: Event Functor Syntax ✓ ANSWERED
**Answer**: `on <condition> emit <queue> { <payload> }` on the producing table, and
`handler <FunctorRef>` on the queue table. Replaces the `assert event { <FunctorRef> }`
placeholder. See `events.md` and `schema/functors.md`.

Each of the three defects in the placeholder is addressed by a different part of the answer:

- **Not an assertion** → `on … emit` is its own statement. `assert` states an invariant that
  can abort a commit; an event registration declares a deferred effect that can abort nothing.
  The name `event` is no longer special to `assert`.
- **No trigger condition** → the `on` expression, with one uniform rule: **an event fires on a
  `False` → `True` transition of its condition, never on the condition merely being true.**
  For stored fields the transition is observed across the write; for a `Behavior` it is
  solved for. This is why no `becomes` keyword was needed — transition semantics are the
  default, and a keyword restating the default is not worth reserving.
- **No queue binding or retry policy** → `emit` names the queue. Retry policy stays in
  `system.events.Queue` deliberately: it is an operational property of the destination that
  changes over time, and tuning it should not require redeclaring a table. Same separation as
  enforcement modes.

It also splits producer from consumer, which the placeholder conflated: `on … emit` is the
producing table's declaration, `handler` is the queue's.

Three keywords added: `on`, `emit`, `handler`. Queue tables carry `LogData` — a queue item is
an occurrence, and two identical enqueues are two distinct work items.

**`repair … into <queue>` is settled with it.** `into` names an ordinary queue table, the same
binding `emit` makes. The two keep different spellings because the statements have different
shapes: `emit` takes a payload literal, while a repair's payload is fixed — it is the
violating row.

**Not answered here**: behavior-triggered conditions require the scheduler to *solve* for a
crossing moment rather than observe a transition, which is new machinery. See OQ-034. Event
functors over stored fields are implementable as specified; over behaviors they are not yet.

### OQ-031: Record Literals and Operator Spelling ✓ ANSWERED
**Answer**: Both resolved in favour of Haskell spelling.

**(a) Record literals use `=`.** Row construction and row update take `field = value`, as in Haskell record syntax. This removes the construction/update split that previously had construction on `:` and update on `=`:

```
app.commerce.Order { customer = customerId, total = 99.99 }   -- construction
Order where id == "uuid-..." { status = Shipped }             -- update
order { total = order.total * (1 - discount) }                -- update in a function body
```

Every brace-delimited key-value form follows: connector config (`add connector … { host = "…" }`) and UI hints (`ui { template = "card" }`) construct rows in system tables, so they take `=` too. `:` is left free to mean only "is a kind of".

Consequence for parsing: a brace block in query position is a projection when its items are bare paths and a row update when they are `field = value` bindings — one token of lookahead past the identifier.

**(b) Operator spelling follows Haskell.**

| Was | Now |
|---|---|
| `!=` | `/=` |
| `and` | `&&` |
| `or` | `\|\|` |

`and` and `or` are no longer reserved words. They were never Haskell operators — they are list functions (`and :: [Bool] -> Bool`) — so the old spelling misled a Haskell reader. `not`, `True`, and `False` were already correct; the reserved-word list had `true`/`false` lowercase and has been fixed.

New lexing note: `|` and `||` share a prefix, and `|` is already heavily loaded (sum types, unions, outer-join guards). Maximal munch resolves it, but a missing space turns a type alternation into a boolean expression. See `schema/railroad.md`.

### OQ-032: Retention of Observational Violations ✓ ANSWERED
**Answer**: Retention is declared by **predicate**, not by age alone, using the ordered branch
form of `retain` (`schema/aggregates.md`). See `integrity.md`.

```
retain system.integrity.Violation
  where origin is Derived && state is Repaired
    for 90 days
    , drop
  otherwise
    forever
```

`Derived` violations are queries over the transaction graph and recomputable; once `Repaired`,
the repair is visible in the subject row's own history, so dropping a closed one loses nothing.
`Observed` (transient witness), `Forced` (operator judgement, not re-derivable), and anything
`Waived` (the waiver and its reason are the audit trail) all fall to `otherwise forever`.

**The constraint is met structurally rather than by policy.** "Prune the log shard" can no
longer destroy audit evidence because it is no longer an operation: log data is discarded only
as a consequence of a declared `retain` chain, and a `LogData` table with no chain is never
pruned. Silence means keep.

This also replaced the framing in the question. `LogData` was described as "prunable" in a way
that read as "pruned on a schedule"; it means *may be discarded if a policy says so*. None of
the three options considered was taken — the table is not split, nothing is promoted to
`Configuration`, and no per-row detail is summarized away — because a predicate branch
expresses the actual rule directly.

### OQ-033: Document Key Interning Cap
**Question**: What is the default key-cardinality cap for a `Doc indexed` field, and how is a
spill surfaced?

Interned document keys are schema objects replicated to every server, so unbounded key
cardinality from an external source is a cluster-wide problem, not a local one — a payload
using UUIDs as object keys would grow a `Reference` table on every node
(`schema/documents.md`). Above the cap, keys spill to a shard-local data table; the cap is
what makes that boundary safe.

**Needs**: an empirical default, and a policy for what happens as a field approaches it.
Spilling silently makes the field quietly slower and larger; refusing to spill makes ingest
fail, which is exactly the outcome `monitor` mode exists to avoid.

**Notes**: should be tunable per field and overridable per connector, in the same spirit as
OQ-009's rendering thresholds. Validate against real webhook payloads (Stripe, GitHub) and
real application log context before fixing a number.

### OQ-034: Behavior-Triggered Event Scheduling
**Question**: How does the scheduler handle an `on` condition whose subject is a `Behavior`?

A condition over stored fields is decided at commit and costs the scheduler nothing. A
condition over a behavior has no write to observe, so the scheduler must compute *when* the
condition will first hold and arrange to wake then (`events.md`). Three sub-questions, all
open:

**Solving.** The crossing moment must be derivable in closed form, which is what restricts
behaviors to an analyzable class (constant, linear, piecewise-linear, exponential decay are
the obvious candidates). The class, the solver per class, and the encoding of both in the
GADT DSL are unspecified. Note this compounds OQ-001: the event functor is the one kind the
dynamic-loading spike never validated, and a crossing solver is strictly harder than the
`EventRef` production that spike would have tested.

**Re-solving on write.** A behavior closes over stored fields, so writing the row changes the
function and moves the crossing. Every pending wake-up derived from a behavior on that row
must be recomputed at commit — and an item already enqueued may have been enqueued for a
crossing that no longer happens. Whether such an item is withdrawn, or dispatched with its
condition re-checked at fire time, is undecided.

**Missed crossings.** If a server is down across a crossing moment, the event can fire late or
be skipped. "The trial expired" wants to fire late; "the rate-limit window opened" may not.
The policy, and whether it belongs per queue or per trigger, is undecided.

**Constraint**: whatever is chosen must not reintroduce polling, since eliminating the
hand-rolled `scheduled_at ≤ now` timer is most of the point of solving for crossings at all.

**Aggregate encoding belongs here too.** A retention chain (`schema/aggregates.md`) needs the
same kind of machinery from the other direction: an aggregate admissible in a multi-step chain
must declare an associative merge with an identity, and that merge has to be encodable in the
GADT DSL alongside the crossing solver. Open with it:

- How a merge is declared and checked. `count`/`sum`/`min`/`max` are obvious; the rule is
  written as "must declare a merge" specifically so a mergeable sketch type (t-digest for
  percentiles, HyperLogLog for distinct counts) can be added later without changing it. What
  that type looks like is unspecified.
- `avg` is rewritten to `(sum, count)` and divided on read. Whether that rewrite is a general
  mechanism (an aggregate declaring a different stored form from its read form) or a
  one-off is undecided; a general mechanism is what a sketch type would need.
- Whether the closed-form solver for behavior crossings and the fold for aggregates share a
  representation. Both are "compute something in closed form over a restricted function
  class", and building them twice would be a mistake worth avoiding deliberately rather than
  by accident.

**Blocks**: `on` conditions over behaviors; mergeable sketch types, and therefore `percentile`
in a chain of more than one step. Conditions over stored fields and chains built from
`count`/`sum`/`min`/`max`/`avg` are unaffected and implementable as specified.

### OQ-006: Failure Detection and Primary Elevation
**Question**: How does the cluster detect a failed primary and who initiates elevation of a secondary?
**Options**: Heartbeat with timeout, lease-based (primary must renew a lease), or external witness node.
**Constraint**: Must not split-brain — two secondaries must not both believe they are primary.
**Additional failure mode (from OQ-027)**: Cross-shard transactions take a distributed lock across all involved shard primaries and hold it until all operations complete. If any participating primary dies mid-lock, the recovery protocol must detect the partial lock and either complete or roll back the transaction. This is effectively a two-phase commit recovery problem — the failure detection mechanism chosen here must also handle lock-holder crash recovery, not just primary elevation for normal reads and writes.

### OQ-007: Shard Split Trigger
**Question**: Are shard splits automatic (threshold-triggered) or operator-initiated (with threshold warnings)?
**Tradeoff**: Automatic splits are convenient but can cause disruption; manual splits are safer but require operator attention.

### OQ-008: Client Token Provisioning
**Question**: How are client tokens issued and distributed to thick client deployments?
**Notes**: Client tokens are long-lived and represent an application's identity. Must be rotatable without disrupting users.

### OQ-009: Weighted Cardinality Algorithm
**Question**: What is the exact function `f(element_count, element_size)` that determines relationship rendering level?
**Notes**: Thresholds and weights should be tunable per application and overridable per field. The initial defaults need empirical validation.
**Action**: Design algorithm; validate with real schema examples before first UI implementation.

### OQ-010: PageRank Parameters for Schema Linearization
**Question**: What are the damping factor, convergence criteria, and edge weighting rules for schema PageRank?
**Notes**: Edge types (foreign key, path equivalence) may warrant different weights. Should be tunable.

## Can Defer to Post-MVP

### OQ-011: FIDO2/WebAuthn for Long-Lived Credentials
**Question**: Should the identity provider support hardware security keys?
**Notes**: Strong security improvement but significant implementation complexity. Not required for initial deployment.

### OQ-012: Analytical Query Distribution Protocol
**Question**: How exactly are distributed materialized view computations coordinated between neighboring servers?
**Notes**: The BitTorrent-style propagation model handles transaction replication; the analytical distribution model is a separate protocol.

### OQ-013: Yesod Evaluation ✓ ANSWERED
**Answer**: Yesod not needed for the data plane. Defer to thin-client HTML layer, which is post-MVP.
- The Servant + Warp spike (OQ-002) confirmed that Servant's type-safe routing, combined with a WAI IORef dispatch table, covers all DataCode data plane needs at 1µs/request overhead.
- Yesod would add session management and HTML templating that are irrelevant to a JSON/binary API server.
- Revisit Yesod only if the thin-client HTML layer warrants it — after the data plane is shipping.

### OQ-014: D3.js Integration
**Question**: How does the HTML rendering engine decide when to use D3.js visualizations vs. plain HTML?
**Notes**: Likely a theme-level decision (some themes include D3 components). Needs more design once base HTML rendering is working.

### OQ-015: Service Accounts
**Question**: Should there be a distinct "service account" token type for machine-to-machine calls (not associated with a human user)?
**Notes**: The current model requires a user token on every request. Service-to-service calls may need a different model.

### OQ-016: The Progression of Relationship Rendering Levels
**Question**: What is the full progression from radio buttons through "shopping cart" for relationship rendering?
**Notes**: Chris indicated he can provide the full list later.
**Action**: Get the full list and incorporate into `api-and-rendering.md`.

---

## Connector and Ingestion Questions

### OQ-017: PostgreSQL Logical Replication ✗ NOT DOING
**Decision**: Deprioritized for v1. The company primarily uses MariaDB/MySQL, which is the required replication source. `postgresql-replicant` is abandoned; a fork or rewrite is not worth the investment now. Revisit post-v1 if there is demand.

### OQ-018: Redis CDC Approach ✗ NOT DOING
**Decision**: Deprioritized for v1. No viable transparent Haskell library; Redis Streams requires source changes; sidecar adds operational complexity. Not worth it for v1. Revisit post-v1 if needed.

### OQ-019: Connector Daemon Architecture
**Question**: Is the connector daemon a separate process (separate daemon alongside the schema and data daemons) or a thread pool within the main DataCode server process?
**Notes**: Separate process allows independent restart; same process is simpler. Connector failures should not crash the main server.
**Action**: Decide during core architecture design; likely a separate supervised process.

### OQ-020: Webhook Endpoint Security
**Question**: How does DataCode authenticate incoming webhooks from external services (e.g., Stripe signature verification)?
**Notes**: Each API has its own webhook authentication mechanism (HMAC, shared secret, JWT). This needs to be configurable per connector without code changes.
**Action**: Design a webhook authentication plugin interface; configuration stored in system tables.

### OQ-021: IDE Graph Layout Library
**Question**: ELK.js (client-side WebWorker), `graphviz` (server-side process), or D3.js force-directed for ER diagram layout?
**Notes**: ELK.js handles large graphs well and supports Sugiyama layout. `graphviz` is more mature but requires a server-side process. D3.js force-directed is simpler but produces less readable hierarchical layouts.
**Recommendation**: ELK.js for interactive layout + `graphviz` for static export. Needs validation.

### OQ-022: IDE Bootstrapping
**Question**: Is the IDE a separate DataCode application (its own namespace/shard) or deeply integrated into the server?
**Tradeoff**: Separate is cleaner for upgrades and lets the IDE be updated independently. Integrated avoids the bootstrapping problem (the IDE needs to work before any application schema exists).
**Notes**: The IDE must work when the only schema is `system.*` — it must not depend on application schema to render.

### OQ-023: IDE Conflict Resolution UI
**Question**: What does the manual conflict resolution interface look like?
**Notes**: When functor-based and timestamp-based resolution both fail, an operator must review. The UI needs to show: both versions of the conflicting record, the mutation history from both transaction logs, and a way to choose or merge.
**Action**: Design after the connector sync protocol is implemented.

### OQ-024: Namespace Access Control Inheritance
**Question**: Does granting access to a namespace automatically grant access to all child namespaces and tables, or must each level be granted explicitly?
**Notes**: Implicit inheritance is more convenient; explicit grants are more secure. A default-deny model with explicit grants is safer for production, but more verbose for initial setup.

### OQ-025: Connector Schema Change Propagation
**Question**: When an external schema changes (new column added to MariaDB table), how does DataCode notify users whose application schema (`app.*`) references that connector table?
**Notes**: The shadow schema is updated automatically. But if `app.commerce.Order` is a view over the connector table and a new field appears in the connector, does it automatically appear in the view, or must the user explicitly add it?
**Action**: Design the schema change notification and propagation rules; likely a configurable policy per view.
