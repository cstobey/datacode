# Dynamic Loading

## The Problem

DataCode must absorb schema changes at runtime — new tables, new types, new functors —
and immediately behave as if those changes were compiled in. This is the single hardest
technical challenge in the project.

The tension: Haskell's type safety comes from compile-time type checking, and runtime
dynamic loading inherently escapes the type system. The goal is to recover as much
safety as possible while retaining dynamism.

## Decision

**OQ-001 is answered in two halves, because there are two questions.**

| Question | Answer |
|---|---|
| How is a functor represented, and how does a new business rule take effect with no restart? | **Effect-indexed GADT DSL** + `Data.Dynamic` type registry. Validated in `spikes/functor-dsl/output.txt` |
| How does *compiled-in* Haskell change without downtime? | **Generation pool behind a stable router**, governed per host. See [Process Topology](#process-topology) |

The two are not competing. The first is the semantics of a schema change; the second is
the deployment mechanism for the three things that genuinely need compiled Haskell —
handlers, primitive types, and the interpreter itself. **A schema change never touches
the second**, which is what makes zero-downtime schema evolution structural rather than
carefully engineered.

### Why functors are interpreted and not compiled

Generating Haskell per schema version and compiling it was considered seriously and
rejected on three counts. The performance argument for compiling is empty: the spike
measures interpretation at 0.07–0.8 µs per functor application against an 11 µs LMDB
read (`spikes/storage/output.txt`), so functor evaluation is one to two orders of
magnitude below the storage floor and is dominated by lookups the engine performs
anyway.

- **Transparency.** Four consumers need the functor's *structure*, not its behaviour:
  the query optimizer, static access analysis, `evolution.md`'s coercion-path
  derivation, and the IDE's ER diagram. Compiled code answers none of these questions.
  `spikes/functor-dsl` implements the analyses as pure walks over the term to show what
  is being bought — assert-variety classification, the `bypass access` exemption set,
  anchoring, shard-crossing detection, revalidation sets, filter placement,
  call-graph acyclicity, and the `every`-was-unnecessary classifier.
- **Replay.** `enforce forward` compares against the predicate *as it was*, and
  re-deriving a `Derived` violation needs the predicate as of the violation. A DSL term
  is a content-addressed node in the graph; a retired binary is not, so compiling would
  mean retaining every historical binary.
- **The commit path.** Compilation is an external call, so by the effect ladder it
  cannot happen inside a commit. A schema change would become commit-then-build, and
  the REPL's `:commit` (`cli.md`) would be followed by waiting on GHC.

**What compiling would *not* have cost, contrary to a first reading.** The schema graph
is one DAG and all branches are simultaneously present in it, so a compiled artifact
would hold the schema at every live named ref — one binary whose size is
O(named refs × schema), not one binary per version. And historical `at` reads need only
the historical row *shape*, which is graph data, plus **current** access rules (see
OQ-027), so arbitrary-moment sampling would have cost the compiled path nothing. The
three reasons above stand on their own; this one does not.

### The DSL is indexed by effect

Every term is `Pure`, `Read`, or `Tx` — a validation, an assert, a behavior, a template
hole, and an `every` interval are `Read`; a field default and a sequence allocation are
`Tx` — and **nothing in the DSL is `Effect`**, because effectful code is compiled-in
Haskell living outside it.

That is the shape "no arbitrary IO" now takes: not a rejected signature, but an absent
constructor. The spike makes it literal — `data Eff = Pure | Read | Tx` has no `Effect`
rung, so `Term '[] 'Effect Int` fails with *"Not in scope: data constructor Effect"*,
and there is no `Sub 'Tx 'Read` instance, so `Lift` has no downward direction. See
[schema/functions.md](schema/functions.md#the-effect-ladder).

### What the DSL encodes

All four functor kinds (see [schema/functors.md](schema/functors.md)), each now
exercised rather than asserted:

| Kind | Status |
|---|---|
| Validation | ✓ Validated, including `=~` with all three admissible right operands |
| Foreign key | ✓ Validated, including the head rule for a `Null`-derived alternative |
| Path constraint — data | ✓ Validated in all three shapes: expression, presence, absence |
| Path constraint — access | ✓ Validated; the variety is read off the body, and the `bypass access` set is computed |
| Event | ✓ Validated, **both** trigger forms, producing an `EventRef` rather than `Either Error a` |

Also encoded and exercised: typed absence and outer-join guards; the
`Duration`/`Period`/`Grain` split with units as values and both calendar additions;
behaviors as `Moment -> a`, sampled in past and future; function-typed columns with a
static signature and an acyclicity check; template holes where cardinality is the
control flow; `let … in`, `is`/`is not`, the virtual columns, `next`, and `Component`
construction.

### Known ceilings

Three remain, and the list is shorter than it was:

- **Recursive types** require a DSL extension. Unchanged.
- **A closed-form crossing solver** for behavior-triggered conditions (OQ-034). The
  *classifier* that decides whether the solver could have closed a condition is
  implemented in the spike, because the `every`-was-unnecessary warning needs it; the
  solver is not.
- **Mergeable sketch types** (t-digest, HyperLogLog) for `percentile` in a multi-step
  retention chain (OQ-034).

Three former ceilings are closed. **Regex** is a primitive, with provenance carried in
the effect index — a `StringLit` or `Reference` pattern is `Pure` and interned at schema
commit, a `Configuration` pattern is `Read` and cached on the config row version, and
nothing had to state that difference because the index derives it. **Anchored subqueries
with a non-emptiness test** are the `Exists`/`Not Exists` pair over a query whose only
root constructor is `self`. **User-defined functions** split in two: handlers escaped
the ceiling on their merits (below), and functors are terms in a context of their
parameters — no Haskell closure, so a function stays inspectable.

## Process Topology

Four processes per host. The **governor** is per host and holds no data authority:
cluster role assignment stays with the range tree (`distribution.md`).

| Process | Count | Restarts when |
|---|---|---|
| **Router** | one | never, for a schema or handler change |
| **Data workers** | several, generation-tagged | a new build lands |
| **Handler workers** | several, generation-tagged, separate pool | a new build lands |
| **Governor** | one | host maintenance |

The router holds the route trie (OQ-029) and the generation table, and resolves version
tokens (OQ-026). Data workers serve every live ref, with functors interpreted, so a
schema commit repoints the router and needs no swap at all.

### Handler workers are a separate pool

The decisive asymmetry: **the data plane serves N refs; the handler pool serves exactly
one.** There is no such thing as processing an event queue "at a branch" — a queue is
processed at HEAD. Different versioning requirements, therefore a separate and
independently shippable artifact. Three further reasons:

- Handlers are the only place arbitrary Haskell runs, so the only place a crash, leak,
  or hang originates in operator code. Isolation keeps a bad handler off the data plane.
- It makes the `Effect` boundary a **process** boundary and not only a type boundary.
  The missing lift is the load-bearing invariant in the design; having the OS enforce it
  too is cheap defense in depth.
- `Effect`'s capabilities come from a `Configuration` row — reachable hosts,
  credentials, timeouts. A separate process lets that be enforced at the OS level
  (network namespace, distinct service account) rather than by convention.

### Generation swap

The router opens generation *N+1*, stops routing new work to *N*, drains *N* to a
bounded deadline, and kills it. Recycling on a `Configuration` interval with a
per-server override is deliberate: it keeps the swap path exercised so it is never cold
at deploy time.

**Write authority handover needs no new mechanism.** LMDB's writer lock is
cross-process and enforced by the OS, so the incoming generation opens the environment
and blocks on the lock while the outgoing one finishes its in-flight transaction and
releases. The stall is one batched transaction. Reads never stall — LMDB is MVCC and
multi-process, so readers never block writers.

Two obligations the drain deadline exists for. A long-lived LMDB read transaction pins
the free list and grows the file, so a draining worker must be killed rather than waited
on indefinitely. And a worker killed mid-prepare leaves an unresolved prepared node,
which a rolling swap makes routine rather than exceptional — recoverable, since a
prepared node is invisible to validation and excludes nothing (OQ-006), but the
recovery path is now on the common path and must be treated as such.

### Build-then-merge

Adding a handler *is* a schema commit: `system.events.Handler` is a `Reference` table,
so `handler foo.bar` compile-checks against the compiled-in registry. That commit
cannot complete before the build exists, and the graph already has the shape for it.

1. The schema commit appends the node. Durable, replicated, recorded.
2. The build is a queued `Effect` — observable and retryable like any other queue row.
3. On success the merge node lands and the ref advances.
4. On failure the node stays **unmerged and inert**, and the failure is a queue row
   carrying the compiler output.

"Live" is defined by ref position, and refs are data, so there is never a window in
which the graph and the enforced schema disagree. A failed build needs no rollback in a
system where nothing is destroyed — it is the same invisibility that makes an unmerged
schema branch and a prepared node inert (OQ-027).

**DataCode does not build a build farm.** A generation is an artifact; registering one
is a queue row. Whether the artifact was produced on that host or elsewhere is an
operational choice, and content-addressing the generation registry on
`(schema node, DataCode version, GHC version, arch)` makes cross-host sharing a cache
lookup later rather than a redesign. Running GHC on a data node has a real cost worth
recording: it is memory-hungry and will evict the page cache that the zero-copy read
path depends on.

## Constraints on Dynamic Code

- **No arbitrary IO** — functors are `Read` or `Tx`, enforced by an absent constructor
  rather than a signature check. A signature check does not close `traverse` over an
  effectful function inside a validation, or one hidden behind a type alias; an
  unconstructible type does. External side effects go through the event queue, whose
  handlers run in `Effect` (see [events.md](events.md#handlers))
- **No FFI** — prevents sandbox escape
- **Transparent** — all behavior must be inspectable by the runtime for optimization and
  access-control analysis. This is the invariant that decides functors are interpreted
- **Versioned** — every loaded code unit references a schema graph node

## Feasibility Studies

| Spike | Status |
|---|---|
| Effect-indexed GADT DSL, all four kinds, full current syntax | ✓ Done — `spikes/functor-dsl/output.txt` |
| Structural analyses over DSL terms | ✓ Done — same spike, section 8 |
| `Data.Dynamic` type registry | ✓ Done — O(1) `TypeRep` checking confirmed |
| `Text.Regex.TDFA` as the `=~` engine | ⬚ **Not run** — cannot be installed in this sandbox. The primitive's shape, provenance restriction, and cache are validated; the engine is not |
| Servant + dynamic dispatch | ✓ Done — OQ-002; see [tech-stack.md](tech-stack.md) |
| Generation swap latency | ⬚ **Not run** — what is the write stall at LMDB writer-lock handover under load, and what drain deadline avoids free-list growth? |
| Build latency for a handler generation | ⬚ **Not run** — 30 s is the accepted budget; measure against a realistic handler set |
| Closed-form crossing solver | ⬚ Not run — OQ-034 |
| `hint` for runtime Haskell | ✗ **Abandoned.** Superseded rather than deferred: the case that wanted arbitrary Haskell is handlers, and handlers get it from the generation pool without a runtime GHC dependency or a sandbox problem |

---

# Addendum: Options Considered

The chosen approach is A for functors plus C for compiled-in Haskell. B and E are
**abandoned**, not deferred — the generation pool covers what they existed to cover.
D was reconsidered at length and rejected on transparency, replay, and the commit path.

## Option A: Custom DSL with Typed Interpreter — **CHOSEN (functors)**

**Model**: project-m36, DDlog, Datalog engines

A strongly-typed DataCode schema DSL interpreted at runtime. The interpreter is
statically typed Haskell; only the schema expression language is dynamic.

- **Pro**: type-safe interpreter; no GHC dependency at runtime; well-understood pattern
- **Pro**: a proper GADT propagates type safety into schema expressions — and, indexed
  by effect, makes the effect ladder a typing property
- **Pro**: transparent, which four separate consumers require
- **Pro**: a term is a graph node, so every live ref and every historical predicate is
  simultaneously available at no cost
- **Con**: the DSL is a ceiling — three limits remain, listed above
- **Verdict**: Adopted, and validated over the full current syntax rather than a subset

## Option B: `hint` / GHC API (Runtime Haskell Evaluation) — abandoned

- **Con**: constrained to `IO`; requires GHC in-process on every server; arbitrary code
  execution needs a sandbox; compilation latency on the schema-change path
- **Spike result**: failed to compile in `spikes/dynamic-loading` — GHC not on PATH or a
  version mismatch. Never evaluated on the merits
- **Verdict**: Abandoned. The demand was arbitrary Haskell for integrations, and
  handlers now get that from a separate compiled pool — no in-process GHC, and no
  sandbox problem, because the code is built ahead of time rather than evaluated

## Option C: Multi-Daemon Architecture — **CHOSEN (compiled-in Haskell)**

**Model**: Erlang hot-code-loading; microkernel architecture

Adopted and substantially revised. The earlier form was "the schema daemon restarts on
schema changes, in-flight queries drain", which conceded "must design for zero-downtime
restarts" and left the supervisor unspecified. Both are now closed:

- Schema changes need **no restart at all**, because the GADT DSL absorbs them
- Compiled-in changes go through generation swap behind a stable router, with the LMDB
  writer lock as the handover primitive and per-host governance

See [Process Topology](#process-topology).

## Option D: GHC Plugins / Dynamic Linking — reconsidered, not pursued

Compile schema modules as shared libraries and load them via GHC's dynamic linker; or,
in the form reconsidered here, generate Haskell per schema version and swap whole worker
processes.

- **Pro**: removes the DSL ceiling entirely; real compiled performance
- **Pro**: one binary covers all live refs, so the concurrency cost is smaller than it
  first appears
- **Con**: destroys transparency, which four consumers require
- **Con**: replay needs retired predicates, so every historical binary must be retained
- **Con**: puts GHC on the commit path, making a schema change commit-then-build
- **Con**: no performance case — interpretation is far below the storage floor
- **Verdict**: Not pursued for functors. The generation-pool half of the idea *was*
  adopted, for compiled-in Haskell, where it is the right answer

## Option E: Typed DSL + Escape Hatch — abandoned as originally framed

A typed DSL covering most cases, with a controlled escape hatch to runtime-evaluated
Haskell for advanced user-defined functors.

- **Verdict**: Abandoned. The escape hatch was for arbitrary user Haskell, and the
  requirement it served — integrations — is met by compiled-in handlers. If the
  interpreter ever becomes a measured bottleneck (it is not), the remedy is a code
  generator from DSL terms into the next generation, HEAD only, with non-HEAD refs
  falling back to the interpreter and observational equivalence with the interpreter as
  the invariant under test. That is an optimization with a defined shape, not an
  expressiveness escape hatch
