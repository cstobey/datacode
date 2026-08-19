# Dynamic Loading

## The Problem

DataCode must be able to absorb schema changes at runtime — new tables, new types, new
functors — and immediately behave as if those changes were compiled into the system. This is
the single hardest technical challenge in the project.

The tension: Haskell's type safety comes from compile-time type checking. Runtime dynamic
loading inherently escapes the type system. The goal is to recover as much safety as
possible while retaining dynamism.

## Decision

**OQ-001 is answered: GADT DSL + `Data.Dynamic` hybrid.** Validated in
`spikes/dynamic-loading/output.txt`.

| Layer | Mechanism | Role |
|---|---|---|
| Functor representation | **GADT DSL** | Primary mechanism. Every functor is a value in a strongly-typed embedded DSL, interpreted by statically-typed Haskell |
| Type registry | **`Data.Dynamic`** | The registered type library the DSL references by name. `TypeRep`-based type checking is O(1) |
| Operational restarts | **Multi-daemon** | Needed only when compiled-in types must change; schema daemon restarts are coordinated by a supervisor |

**Zero runtime GHC dependency.** ~0µs functor apply latency.

This is the *Typed DSL* approach (Option A in the addendum) taken as the foundation, with
the multi-daemon architecture (Option C) covering the cases the DSL cannot absorb. The
runtime-Haskell escape hatch (Option E) is deferred, not adopted — see below.

### What the DSL must encode

All four functor kinds (see [schema/functors.md](schema/functors.md)):

| Kind | Spike status |
|---|---|
| Validation | ✓ Validated |
| Foreign key | ✓ Validated |
| Path constraint — data | ✓ Validated, for the equality shape only |
| Path constraint — access | ✓ Validated, for the equality shape only (same DSL construct; differs only in whether a term is the token) |
| Event | ✗ **Not validated.** Requires a DSL extension producing an `EventRef` — a queue-table row insert — rather than `Either Error a`. Surface syntax also undefined; see OQ-030 |

Collapsing data constraints and access control into a single path-constraint functor means
the DSL needs one construct where it previously appeared to need two.

**The spike validated equality, and the kind has since widened.** A path constraint's body may
now be a query rooted at `self`, asserted non-empty, or the negation of one (OQ-005), and the
spike encoded neither. Both are anchored traversals over declared `:>` edges rather than
arbitrary queries, so the construct they need is a bounded walk with a non-emptiness test —
plausibly reachable, but unvalidated. Add it to the list below until a spike says otherwise.

### Known ceilings

The DSL is a ceiling by construction. Four limits are already identified:

- **Regex** requires a DSL extension (or a registered primitive). This one is no longer
  hypothetical: `=~` is a `CmpOp` and may appear in any constraint body
  ([schema/railroad.md](schema/railroad.md#functions-and-expressions)), so the primitive is
  needed rather than merely anticipated. Its right operand is restricted to a literal, a
  `Reference` path, or a `Configuration` path, which is what keeps the pattern a constant the
  DSL can hold rather than an arbitrary expression it would have to evaluate.
- **Anchored subquery with a non-emptiness test** — the presence and absence shapes above
- **Recursive types** require a DSL extension
- **User-defined functions** require new DSL constructors — they cannot be arbitrary Haskell

Hitting any of these is the trigger to revisit the addendum below.

### `hint` status

`hint` (Option B) **failed to compile in the spike** — GHC not on PATH, or a version
mismatch. It is not ruled out on the merits; it was not evaluated. Revisit it as an escape
hatch for advanced user-defined functors if and when the GADT DSL's ceiling is actually hit.
Any adoption must compile asynchronously and sandbox the result.

## Constraints on Dynamic Code

Regardless of the mechanism, dynamically loaded code must obey:

- **No arbitrary IO** — functors must be pure or use a restricted effect set. Enforced at schema commit: an `a -> IO b` signature is rejected outright (see [schema/functions.md](schema/functions.md)); external side effects go through the event queue instead (see [events.md](events.md))
- **No FFI** — prevents sandbox escape
- **Transparent** — all behavior must be inspectable by the runtime for optimization and access control analysis
- **Versioned** — every loaded code unit references a schema graph node; the runtime knows which version of each functor is active

## Feasibility Studies

| Spike | Status |
|---|---|
| GADT DSL for all functor kinds | ✓ Done — every kind validated except the event functor |
| `Data.Dynamic` type registry | ✓ Done — O(1) `TypeRep` checking confirmed |
| `hint` for user-defined functors | ✗ Did not run — failed to compile (GHC not on PATH / version mismatch) |
| Servant + dynamic dispatch | ✓ Done — OQ-002 answered; see [tech-stack.md](tech-stack.md) |
| GHC dynamic linking | ⬚ Not run — only needed if the DSL ceiling is hit |
| Multi-daemon restart latency | ⬚ Not run — what is the minimum downtime for a schema daemon restart with in-flight query draining? Is sub-100ms achievable? |

---

# Addendum: Options Considered

Retained in full. The chosen approach is A as the foundation plus C for operational
reliability; B, D, and E remain live if the GADT DSL's ceilings (regex, recursive types,
user-defined functions) turn out to bind in practice.

## Option A: Custom DSL with Typed Interpreter — **CHOSEN (foundation)**

**Model**: project-m36, DDlog, Datalog engines

Define a strongly-typed DataCode schema DSL that is interpreted at runtime. The interpreter
is statically typed Haskell; only the schema expression language is dynamic.

- **Pro**: Type-safe interpreter; no GHC dependency at runtime; well-understood pattern
- **Pro**: Can embed the DSL as a proper GADT — type safety propagates into schema expressions
- **Con**: The DSL is a ceiling — any capability not in the DSL requires a runtime update
- **Con**: User-defined functions (custom validation functors) cannot be arbitrary Haskell; they must be DSL expressions
- **Verdict**: Adopted. Sufficient for all built-in functor kinds. Insufficient alone for arbitrary user-defined functors, which is an accepted limitation for now

## Option B: `hint` / GHC API (Runtime Haskell Evaluation) — deferred

**Model**: GHCi, some plugin systems

Use the `hint` library (or GHC API directly) to compile and evaluate Haskell expressions at
runtime.

- **Pro**: Full Haskell expressiveness for user-defined types and functors
- **Pro**: project-m36 has explored this path — prior art exists
- **Con**: `hint` is constrained to `IO`; extracting pure values requires careful design
- **Con**: Requires GHC to be present on every DataCode server (runtime dependency)
- **Con**: Security surface — arbitrary code execution is a serious concern; must sandbox
- **Con**: Compilation latency on schema changes (seconds, not milliseconds)
- **Con**: Type checking is still compile-time within each evaluated snippet — inter-snippet type checking is lost
- **Spike result**: Failed to compile — GHC not on PATH or version mismatch. Not evaluated on the merits
- **Verdict**: Deferred. The escape hatch of last resort if the DSL ceiling binds

## Option C: Multi-Daemon Architecture — **CHOSEN (operational layer)**

**Model**: Erlang hot-code-loading; microkernel architecture

Separate the runtime into multiple daemons:

- **Schema daemon**: manages the schema graph and query optimizer; reboots on schema changes
- **Data daemon(s)**: manage actual data storage and query execution; do not need to reboot on schema changes
- **Query broker**: routes queries to the appropriate daemon; remains stable

Schema changes trigger a graceful restart of the schema daemon only. In-flight queries drain
before the restart.

- **Pro**: Each daemon is statically compiled; full Haskell type safety within each
- **Pro**: Bounded restart scope — only the schema daemon restarts
- **Pro**: Well-understood operational model
- **Con**: Schema daemon restart is still a brief interruption; must design for zero-downtime restarts
- **Con**: Inter-daemon communication requires a stable wire protocol that can carry dynamic types
- **Con**: Complexity of coordinating multiple daemons
- **Verdict**: Adopted, but narrowed. Because the GADT DSL absorbs ordinary schema changes with no restart, the multi-daemon path is needed only when *compiled-in types* change. Supervisor design is still open

## Option D: GHC Plugins / Dynamic Linking — not pursued

Compile schema modules as shared libraries (`.so` / `.dylib`) and load them via GHC's
dynamic linker.

- **Pro**: Full Haskell type safety within each module; real compiled performance
- **Pro**: No GHC needed at runtime — just a linker
- **Con**: Requires a build system on the schema change path (compilation step before loading)
- **Con**: Dynamic linking in GHC has historically been fragile; symbol conflicts, ABI issues
- **Con**: Still need a compiled GHC toolchain for schema changes
- **Verdict**: Not pursued. The GADT DSL removed the need. Requires investigation if revisited; GHC's dynamic linker has improved in recent versions

## Option E: Typed DSL + Escape Hatch — deferred

A hybrid: define a typed DSL (Option A) that covers 90% of use cases, with a controlled
escape hatch to runtime-evaluated Haskell (Option B) for advanced user-defined functors.

The escape hatch would:

- Be sandboxed (no IO, no FFI, pure computation only — enforced by type)
- Be compiled asynchronously (background compilation queue)
- Fall back to the DSL interpreter until compilation completes
- Be audited and stored in the schema transaction graph

- **Verdict**: Still likely the right long-term architecture. Deferred rather than rejected —
  Option A is in place, and the escape hatch is added incrementally if and when user-defined
  functors demand it
