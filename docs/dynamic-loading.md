# Dynamic Loading

## The Problem

DataCode must be able to absorb schema changes at runtime — new tables, new types, new functors — and immediately behave as if those changes were compiled into the system. This is the single hardest technical challenge in the project.

The tension: Haskell's type safety comes from compile-time type checking. Runtime dynamic loading inherently escapes the type system. The goal is to recover as much safety as possible while retaining dynamism.

## Approaches Under Consideration

### Option A: Custom DSL with Typed Interpreter
**Model**: project-m36, DDlog, Datalog engines

Define a strongly-typed DataCode schema DSL that is interpreted at runtime. The interpreter is statically typed Haskell; only the schema expression language is dynamic.

- **Pro**: Type-safe interpreter; no GHC dependency at runtime; well-understood pattern
- **Pro**: Can embed the DSL as a proper GADT — type safety propagates into schema expressions
- **Con**: The DSL is a ceiling — any capability not in the DSL requires a runtime update
- **Con**: User-defined functions (custom validation functors) cannot be arbitrary Haskell; they must be DSL expressions
- **Verdict**: Probably necessary as a foundation, but insufficient alone for user-defined functors

### Option B: `hint` / GHC API (Runtime Haskell Evaluation)
**Model**: GHCi, some plugins systems

Use the `hint` library (or GHC API directly) to compile and evaluate Haskell expressions at runtime.

- **Pro**: Full Haskell expressiveness for user-defined types and functors
- **Pro**: project-m36 has explored this path — prior art exists
- **Con**: `hint` is constrained to `IO`; extracting pure values requires careful design
- **Con**: Requires GHC to be present on every DataCode server (runtime dependency)
- **Con**: Security surface — arbitrary code execution is a serious concern; must sandbox
- **Con**: Compilation latency on schema changes (seconds, not milliseconds)
- **Con**: Type checking is still compile-time within each evaluated snippet — inter-snippet type checking is lost
- **Feasibility**: Partial — likely usable for user-defined functors but requires extensive sandboxing and a compilation queue

### Option C: Multi-Daemon Architecture
**Model**: Erlang hot-code-loading; microkernel architecture

Separate the runtime into multiple daemons:
- **Schema daemon**: manages the schema graph and query optimizer; reboots on schema changes
- **Data daemon(s)**: manage actual data storage and query execution; do not need to reboot on schema changes
- **Query broker**: routes queries to the appropriate daemon; remains stable

Schema changes trigger a graceful restart of the schema daemon only. In-flight queries drain before the restart.

- **Pro**: Each daemon is statically compiled; full Haskell type safety within each
- **Pro**: Bounded restart scope — only the schema daemon restarts
- **Pro**: Well-understood operational model
- **Con**: Schema daemon restart is still a brief interruption; must design for zero-downtime restarts
- **Con**: Inter-daemon communication requires a stable wire protocol that can carry dynamic types
- **Con**: Complexity of coordinating multiple daemons
- **Verdict**: Most pragmatic option for production reliability; not ideal but workable

### Option D: GHC Plugins / Dynamic Linking
Compile schema modules as shared libraries (`.so` / `.dylib`) and load them via GHC's dynamic linker.

- **Pro**: Full Haskell type safety within each module; real compiled performance
- **Pro**: No GHC needed at runtime — just a linker
- **Con**: Requires a build system on the schema change path (compilation step before loading)
- **Con**: Dynamic linking in GHC has historically been fragile; symbol conflicts, ABI issues
- **Con**: Still need a compiled GHC toolchain for schema changes
- **Feasibility**: Requires investigation; GHC's dynamic linker has improved in recent versions

### Option E: Typed DSL + Escape Hatch
A hybrid: define a typed DSL (Option A) that covers 90% of use cases, with a controlled escape hatch to runtime-evaluated Haskell (Option B) for advanced user-defined functors.

The escape hatch would:
- Be sandboxed (no IO, no FFI, pure computation only — enforced by type)
- Be compiled asynchronously (background compilation queue)
- Fall back to the DSL interpreter until compilation completes
- Be audited and stored in the schema transaction graph

- **Verdict**: Likely the right long-term architecture; start with Option A, add the escape hatch incrementally

## Recommended Approach (Tentative)

1. **Start with a typed DSL interpreter (Option A)** for all built-in functor types and schema operations. This gives a working system with full type safety.
2. **Use multi-daemon architecture (Option C)** for operational reliability during schema changes.
3. **Spike Option B and D** to determine if runtime-evaluated Haskell is viable for user-defined functors. This is a required feasibility study before committing to Option E.

## Feasibility Studies Required

- [ ] **Spike: `hint` for user-defined functors** — Can we evaluate a schema functor as a `hint` expression, extract a pure function, and apply it safely? What is compilation latency? What sandboxing is available?
- [ ] **Spike: GHC dynamic linking** — Can we compile a schema module to a shared library and hot-load it into a running DataCode process without symbol conflicts?
- [ ] **Spike: Multi-daemon restart latency** — What is the minimum downtime for a schema daemon restart with in-flight query draining? Is sub-100ms achievable?
- [ ] **Spike: Servant + dynamic dispatch** — Can a Servant-defined API serve dynamic schema endpoints? (See `tech-stack.md`)

## Constraints on Dynamic Code

Regardless of the mechanism chosen, dynamically loaded code must obey:
- **No arbitrary IO** — functors must be pure or use a restricted effect set
- **No FFI** — prevents sandboxing escape
- **Transparent** — all behavior must be inspectable by the runtime for optimization and access control analysis
- **Versioned** — every loaded code unit references a schema graph node; the runtime knows which version of each functor is active
