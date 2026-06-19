# Dynamic Loading Feasibility Spike

Tests three approaches to runtime schema evolution in DataCode.

## What This Tests

**The core question**: Can DataCode absorb schema changes at runtime — new tables, new types, new functors — and immediately behave as if those changes were compiled in?

Three approaches:

| Approach | File | GHC at runtime? | New types at runtime? | Performance |
|---|---|---|---|---|
| 1. `hint` (GHC interpreter) | `HintApproach.hs` | Yes | Yes | Slow (compile step) |
| 2. GADT DSL interpreter | `GADTDSLApproach.hs` | No | No (DSL ceiling) | Excellent |
| 3. `Data.Dynamic` + Typeable | `DynamicTypesApproach.hs` | No | No (pre-compiled) | Excellent |

## Prerequisites

```
ghc >= 9.4
cabal >= 3.6

# Install hint (wraps the GHC API):
cabal install hint
```

GHC must be on your PATH for Approach 1 to work. Approaches 2 and 3 have no runtime GHC dependency.

## Run

```bash
cd spikes/dynamic-loading
cabal build
cabal run dynamic-loading-spike
```

## What to Measure

When you run the spike, record these numbers in the findings doc:

### Approach 1 (hint)
- [ ] Initial compilation latency (first `runInterpreter` call) in ms
- [ ] Subsequent compilation latency (same snippet, GHC warmed up) in ms
- [ ] Whether the sandboxing test (Test 4) correctly blocks `unsafePerformIO`
- [ ] Whether repeated compilations of the same snippet get faster (caching)

### Approach 2 (DSL)
- [ ] Per-record validation latency in µs (from benchmark)
- [ ] Whether all four functor types work as expected
- [ ] Whether the NOT_FOUND / Maybe tests pass correctly
- [ ] Whether the email format test (DSL ceiling test) is expressive enough

### Approach 3 (Dynamic)
- [ ] Per-record validation latency in µs (from benchmark)
- [ ] Whether the type mismatch test correctly rejects wrong types
- [ ] Whether the functor chain correctly fails at the first failure

## Key Decision Points

After running, answer:

1. **Is hint's compilation latency acceptable?**
   - < 100ms: usable as an escape hatch (async compilation, cached after first load)
   - 100ms–1s: marginal — only usable for infrequent schema changes
   - > 1s: probably too slow for interactive schema changes; must compile offline

2. **Does hint's sandboxing actually work?**
   - If Test 4 lets `unsafePerformIO` through: the sandbox is ineffective
   - If it correctly blocks: sandbox is usable but needs thorough adversarial testing

3. **Is the DSL ceiling acceptable?**
   - The DSL handles the four DataCode functor types well
   - It cannot express arbitrary Haskell (regex, complex string parsing, etc.)
   - Is that acceptable if hint provides an escape hatch?

4. **Is Approach 3 useful standalone?**
   - The Dynamic approach requires all types to be pre-compiled into DataCode
   - This means user-defined types (custom newtype Email, custom ADT) cannot be added without a DataCode release
   - Is it useful as the type registry that the DSL approach references?

## Expected Architecture Decision

Based on the spike results, the recommended architecture is:

```
schema author defines rule
        │
        ▼
[DSL expression?] ──yes──► GADT DSL interpreter (Approach 2)
        │                   └─ O(1) apply, no GHC, all 4 functor types
        │ no
        ▼
[within pre-compiled    ──yes──► Data.Dynamic wiring (Approach 3)
 type library?]                  └─ O(1) apply, type-checked by TypeRep
        │ no
        ▼
hint escape hatch (Approach 1)
└─ async compilation into type registry
└─ sandboxed: no IO, no FFI, pure only
└─ audited: stored in schema transaction graph
└─ cached: compiled once, reused until schema changes
```

Schema daemon restart (multi-daemon approach) is a fallback when compiled-in
types need to change — this requires a DataCode release, not a schema change.

## Files

```
dynamic-loading.cabal   — project definition
cabal.project           — workspace config
app/
  Main.hs               — orchestrates all approaches + benchmark + summary
src/Spike/
  HintApproach.hs       — Approach 1: GHC interpreter via hint
  GADTDSLApproach.hs    — Approach 2: typed DSL interpreter
  DynamicTypesApproach.hs — Approach 3: Data.Dynamic + Typeable
  Benchmark.hs          — latency comparison at 10,000 records
```
