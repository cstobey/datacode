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
rejected on three counts. The performance argument for compiling is empty on the paths
that dominate: the spike measures interpretation at 0.07–0.8 µs per functor application
(`spikes/functor-dsl/output.txt`) against an 11 µs LMDB read
(`spikes/capnproto/output.txt`, which is where that figure was recorded — the storage
spike's LMDB section panicked on the bound-thread bug and produced no number). For a
point read, and for per-row validation at commit, functor evaluation is one to two
orders of magnitude below the storage cost and is dominated by lookups the engine
performs anyway.

**That is a claim about point operations, not about scans.** The 11 µs is a cold random
point read through two LMDB lookups, not a floor. A range scan over mmap'd rows costs a
small fraction of it per row — the zero-copy field read was below the spike's timer
resolution — while an access assert still runs per row, so at 0.15 µs per path-constraint
application a 10 M-row scan pays about 1.5 s of interpretation. There, interpretation is
the dominant per-row cost rather than the noise. The recorded contingency for that case
is the code generator in Option E below — HEAD only, with the interpreter as the fallback
— not a redesign: the three arguments that follow do not rest on the performance number.

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

Every term is `Pure`, `Read`, or `Tx`, and **nothing in the DSL is `Effect`**, because
effectful code is compiled-in Haskell living outside it. Which rung each position admits
is [schema/functions.md](schema/functions.md#the-effect-ladder)'s to say.

That is the shape "no arbitrary IO" now takes: not a rejected signature, but an absent
constructor. The spike makes it literal — `data Eff = Pure | Read | Tx` has no `Effect`
rung, so `Term '[] 'Effect Int` fails with *"Not in scope: data constructor Effect"*,
and there is no `Sub 'Tx 'Read` instance, so `Lift` has no downward direction.

**A position's rung is a ceiling, not the index a term carries.** The effect is inferred
from the body and checked against the position, so the `Tx` cell for field defaults says
that position admits `Tx`, not that every default is one. A sequence allocation is `Tx`
because it allocates. A field default is indexed by its body, which is what lets
[schema/evolution.md](schema/evolution.md#redeclare-a-table) require `Pure` of a default
on a field added to a populated table without moving anything on the ladder.

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

Three former ceilings are closed:

- **Regex** is a primitive, with provenance carried in the effect index — a `StringLit`
  or `Reference` pattern is `Pure` and interned at schema commit, a `Configuration`
  pattern is `Read` and cached on the config row version, and nothing had to state that
  difference because the index derives it. What bounds the cost is that provenance
  restriction plus a commit-time pattern budget, **not** the engine: the old
  justification — "a DFA engine makes a pathological pattern cost no more than a linear
  scan" — is false, because TDFA builds its DFA lazily and caches states. The
  restriction, its replacement justification, and the normative engine properties are in
  [schema/railroad.md](schema/railroad.md#functions-and-expressions).
- **Anchored subqueries with a non-emptiness test** are the `Exists`/`Not Exists` pair
  over a query whose only root constructor is `self`.
- **User-defined functions** split in two: handlers escaped the ceiling on their merits
  (below), and functors are terms in a context of their parameters — no Haskell closure,
  so a function stays inspectable.

## Process Topology

Five processes per host. The **governor** is per host and holds no data authority:
cluster role assignment stays with the range tree (`distribution.md`).

| Process | Count | Restarts when |
|---|---|---|
| **Router** | one | never, for a schema or handler change |
| **Data workers** | several, generation-tagged | a new build lands |
| **Handler workers** | several, generation-tagged, separate pool | a new build lands |
| **Scheduler** | one, generation-tagged with the handler pool | a new build lands |
| **Governor** | one | host maintenance |

The router holds the route trie (OQ-029) and the generation table
([The generation registry](#the-generation-registry)), and resolves version tokens
(OQ-026). Data workers serve every live ref, with functors interpreted, so a schema
commit repoints the router and needs no swap at all.

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
  credentials, timeouts. A separate process lets the coarse half of that be enforced at
  the OS level (network namespace, distinct service account) rather than by convention.
  Which half is fixed per generation and which stays hot is
  [events.md](events.md#handlers)'s to state, because the row is declared there.

**The consequence for branches is a schema-commit rule.** A request served at a non-HEAD
ref commits under that ref's schema, so it can emit into a queue table that exists only
on the branch, or into one whose payload shape differs there. The scheduler, processing
at HEAD, then meets a row against a table that is absent or does not match.

> An `EventDecl` whose queue table is absent at HEAD, or whose payload does not typecheck
> against HEAD's version of that table, is a schema-commit error on every ref the router
> may serve.

A branch that wants a new queue merges the queue table first and the emitter second —
the same ordering build-then-merge imposes on a handler. The alternative was stamping
each queue row with the ref that produced it and having the scheduler skip rows whose ref
is not an ancestor of HEAD. That is rejected: it makes queue depth a per-branch quantity
and defers the failure to dispatch time on a branch nobody is watching.

### The scheduler ticks on the primary

The scheduler is its own process, not a thread in the governor: it dispatches into the
handler pool and swaps with it, while the governor holds no data authority at all.
[events.md](events.md#scheduler-architecture) owns its selection loop, backoff, and
retry. What the topology has to add is **cardinality**, because a `Configuration` table
replicates to every server and both worked `every` examples sit on one.

> A row's `every` declarations tick on the **shard primary for that row**, and nowhere
> else.

So a `Configuration` row ticks exactly once cluster-wide even though every server holds a
copy. Nothing new enforces that: the primary already linearizes writes to the row, which
is what makes the atomic advance to an `InFlight` disposition exclude double-dispatch
across hosts. The LMDB write lock could not have carried it — that lock is per
environment, so it is a per-host answer to a cluster-wide question.

Read the other way, the rule says a host schedules for the shards it is primary for. So
elevation moves the tick along with write authority, and a demoted primary stops ticking
as a consequence rather than through a separate handover.

### Generation swap

The router opens generation *N+1*, stops routing new work to *N*, drains *N* to a
bounded deadline, and kills it. Recycling on `system.runtime.GenerationPolicy`'s
interval, with its per-server override, is deliberate: it keeps the swap path exercised
so it is never cold at deploy time.

**Write authority handover needs no new mechanism.** The router stops routing writes to
*N*, and LMDB's writer lock — cross-process and enforced by the OS — serializes *N*'s
last in-flight transaction against *N+1*'s first: the incoming generation opens the
environment and blocks until the outgoing one releases. The stall is one batched
transaction. Reads never stall, because LMDB is MVCC and multi-process, so readers never
block writers.

Attribute the two halves correctly: the **router** is what confers authority, because a
mutex serializes and does not fence. The lock removes the need for a handover protocol
once authority has already moved.

Four obligations follow. The drain deadline exists for the first two; the other two are
what a deliberate kill costs at the storage layer:

- **A long-lived read transaction pins the free list** and grows the file, so a draining
  worker must be killed rather than waited on indefinitely.
- **A worker killed mid-prepare leaves an unresolved prepared node**, which a rolling
  swap makes routine rather than exceptional — recoverable, since a prepared node is
  invisible to validation and excludes nothing (OQ-006), but the recovery path is now on
  the common path and must be treated as such.
- **A killed writer may die holding the lock.** Recovery is the robust-mutex path
  (`EOWNERDEAD`): the next opener finds the environment marked inconsistent, rolls back
  the abandoned write transaction, and continues. Without it the environment is
  unopenable and the swap has traded a stall for an outage.
- **A killed reader leaves a stale reader-table slot**, which pins the free list exactly
  as a live reader does. The incoming generation runs a reader check on open and reclaims
  slots whose owning process is gone.

Two storage decisions the swap depends on, both of them
[storage.md](storage.md#two-complementary-structures-per-shard)'s to state: a shard's two
LMDB databases share **one environment**, which is what makes the writer lock shard-scoped
rather than server-wide; and the map size grows on a declared procedure, so `MDB_MAP_FULL`
is a handled condition rather than a crash the swap inherits.

### The generation registry

The schema is data, so a generation is a row like every other operational concern —
routes, handlers, durability policy, shard nodes. Generations had been the one piece of
operational state carried in prose alone, which left the drain deadline and the recycle
interval that the swap protocol depends on with nowhere to live.

```
table system.runtime.Generation : Reference, Extensible {
  artifact_digest    : Bytes unique,
  datacode_version   : Text,
  ghc_version        : Text,
  handler_source_rev : Text,
  arch               : Text,
  built_at           : Timestamp,
  exports            :> ExportedHandler : Component { handler :> system.events.Handler },
  unique buildInputs { datacode_version, ghc_version, handler_source_rev, arch }
}

table system.runtime.GenerationPolicy : Configuration {
  server         :> system.shards.Node unique,
  recycle_after  : Duration = 24 hour,
  drain_deadline : Duration = 30 second
}
```

Each trait is read off the rule in
[schema/traits.md](schema/traits.md#when-a-reference-table-is-warranted). A generation
`Reference` row records a fact originating outside the schema graph — an artifact exists
and exports these handlers — which is the same reason `system.events.Handler` is
`Reference`; `Extensible` because the build handler appends the row, not a schema author.
The recycle interval and the drain deadline are operator judgement, which is
`Configuration`, keyed by server so the per-server override is the key rather than a
second table.

Three details in the declaration carry decisions:

- **`exports` is the merge-time check's input.** A `:>` field to a `Component` target
  holds all of that generation's export rows, so the check reads one range scan.
- **`buildInputs` is the input address**, which makes the cross-host cache lookup below a
  key lookup. It is also where non-reproducibility surfaces: a second artifact claiming
  the same inputs is rejected rather than quietly shadowing the first.
- **`built_at` is declared** because the virtual `created_at` is when the row was
  registered on this cluster, which is not when the artifact was produced.

Registering a generation is two writes, both of them in build-then-merge below — the
queue row that carried the build, and the `Generation` row the build handler inserts on
success, which is a schema transaction because the table is `Reference`.

### Build-then-merge

Adding a handler *is* a schema commit: `system.events.Handler` is a `Reference` table, so
`handler app.billing.sync` resolves against a row rather than against a string. That
commit cannot complete before the build exists, and the graph already has the shape for
it.

1. The schema commit appends the node. Durable, replicated, recorded.
2. The build is a queued `Effect` — observable and retryable like any other queue row.
3. On success the merge node lands and the ref advances.
4. On failure the node stays **unmerged and inert**, and the failure is a queue row
   carrying the compiler output.

**Two checks, at two times.** Collapsing them into "compile-checks against the
compiled-in registry" hides the second one, which is the one that reaches Haskell:

- **At schema commit**, `handler <QName>` resolves against a `system.events.Handler`
  row. That is name resolution inside the schema graph, so a typo in the *row* satisfies
  it and the bridge to compiled code is still unchecked.
- **At merge**, the governor compares the artifact's `exports` against every `Handler`
  row reachable at the node being merged, and refuses the merge if any is missing. A
  build that succeeds and omits a handler therefore fails exactly like a build that does
  not compile: step 4, with the missing names in the queue row instead of compiler
  output. The check cannot move earlier — at step 1 the artifact does not exist yet.

"Live" is defined by ref position, and refs are data, so there is never a window in
which the graph and the enforced schema disagree. A failed build needs no rollback in a
system where nothing is destroyed — it is the same invisibility that makes an unmerged
schema branch and a prepared node inert (OQ-027).

**DataCode does not build a build farm.** A generation is an artifact; registering one is
a row insert plus a queue row. Whether the artifact was produced on that host or elsewhere
is an operational choice, and **input-addressing** the generation registry on
`(DataCode version, GHC version, handler source revision, arch)` makes cross-host sharing
a cache lookup later rather than a redesign. Two corrections to the first form of that
sentence, which said "content-addressing on `(schema node, DataCode version, GHC version,
arch)`":

- **The key is the build's inputs, not a hash of the artifact's bytes.** So cross-host
  sharing rests on the build being reproducible, which is an operational obligation
  rather than something GHC gives for free. `artifact_digest` is the content hash, and it
  is for integrity.
- **The schema node is not in the key.** A generation holds handlers, primitive types,
  and the interpreter, none of which a schema commit touches, so keying on the schema node
  would force a rebuild per commit and defeat the cache the sentence exists to enable.

Running GHC on a data node has a real cost worth recording: it is memory-hungry and will
evict the page cache that the zero-copy read path depends on.

## Constraints on DSL Terms

- **No arbitrary IO** — functors are `Pure`, `Read`, or `Tx`, enforced by an absent
  constructor rather than a signature check. A signature check does not close `traverse`
  over an effectful function inside a validation, or one hidden behind a type alias; an
  unconstructible type does. External side effects go through the event queue, whose
  handlers run in `Effect` (see [events.md](events.md#handlers))
- **No FFI in the DSL** — there is no FFI constructor, so there is nothing to forbid. FFI
  *inside a handler* is admissible and expected, since an LDAP or TLS binding is FFI; it
  is bounded by the handler pool's OS-level capability grant, not by a rule in the term
  language. The bullet read "prevents sandbox escape" until this pass, which survived from
  the `hint` design, where user Haskell was evaluated in-process and there was a sandbox
  to escape
- **Transparent** — all behavior must be inspectable by the runtime for optimization and
  access-control analysis. This is the invariant that decides functors are interpreted
- **Versioned** — every loaded code unit references a schema graph node

## Feasibility Studies

| Spike | Status |
|---|---|
| Effect-indexed GADT DSL, all four kinds, full current syntax | ✓ Done — `spikes/functor-dsl/output.txt` |
| Structural analyses over DSL terms | ✓ Done — same spike, section 8 |
| `Data.Dynamic` type registry | ✓ Done — O(1) `TypeRep` checking confirmed |
| `Text.Regex.TDFA` as the `=~` engine | ⬚ **Not run** — the spike validates the primitive's shape, provenance restriction, and cache against a stand-in matcher. What is unmeasured is the engine: the pattern budget that has to reject a pathological pattern, and the ASCII and multiline behaviour [schema/railroad.md](schema/railroad.md#functions-and-expressions) makes normative |
| Servant + dynamic dispatch | ✓ Done — OQ-002; see [tech-stack.md](tech-stack.md) |
| Generation swap latency | ⬚ **Not run** — what is the write stall at LMDB writer-lock handover under load, what drain deadline avoids free-list growth, and what does a killed writer or reader leave behind? |
| Build latency for a handler generation | ⬚ **Not run** — 30 s is the accepted budget; measure against a realistic handler set |
| Interpretation cost over a scan | ⬚ **Not run** — the 0.07–0.8 µs figure is per application against a `Map` store. Measure per-row assert application over a range scan, which is the one path where interpretation is the dominant per-row cost |
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
- Compiled-in changes go through generation swap behind a stable router, which is what
  moves write authority, with the LMDB writer lock serializing the two generations across
  the handover and per-host governance

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
- **Con**: no performance case on the paths that dominate — interpretation is far below
  the cost of a point read, and the scan case has a cheaper answer (Option E)
- **Verdict**: Not pursued for functors. The generation-pool half of the idea *was*
  adopted, for compiled-in Haskell, where it is the right answer

## Option E: Typed DSL + Escape Hatch — abandoned as originally framed

A typed DSL covering most cases, with a controlled escape hatch to runtime-evaluated
Haskell for advanced user-defined functors.

- **Verdict**: Abandoned. The escape hatch was for arbitrary user Haskell, and the
  requirement it served — integrations — is met by compiled-in handlers. If the
  interpreter becomes a measured bottleneck — the scan case above is the candidate, and
  it is extrapolated rather than measured — the remedy is a code generator from DSL terms
  into the next generation, HEAD only, with non-HEAD refs falling back to the interpreter
  and observational equivalence with the interpreter as the invariant under test. That is
  an optimization with a defined shape, not an expressiveness escape hatch
