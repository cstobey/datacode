# Functor DSL Spike — OQ-001 revisit

Supersedes the DSL half of [`../dynamic-loading`](../dynamic-loading). Read
[`output.txt`](output.txt) rather than rebuilding.

## Why this exists

`spikes/dynamic-loading` recorded "GADT DSL — all four functor types encodable" and
OQ-001 was answered on that basis. Re-reading the code, the evidence was weaker than
the claim in three ways:

1. **`Expr` was a plain ADT, not a GADT.** The module says so itself. So every type
   error surfaced at *eval* time as `ValidationError "… type mismatch"`, which is the
   exact failure mode a GADT exists to prevent. "Type safety propagates into schema
   expressions" was never tested.
2. **Two of the three wrong answers in its recorded run were that defect leaking.**
   `Just -5` reported `EConcat: type mismatch` instead of the validation message,
   because the error expression concatenated `Text` with `Int` and the `do` block let
   the eval failure mask the real violation. And `user@example.com` was reported as an
   *invalid* email, because `EContains` compared against `tails'` — suffixes, not
   infixes.
3. **Test 5 claimed to compose all four functors and composed two**
   (`allFunctors = [vFunctor, acFunctor]`).

Meanwhile the language acquired a great deal that the spike never sized: `=~` as a real
operator, both event trigger forms, anchored presence/absence subqueries, the
`Duration`/`Period`/`Grain` split, behaviors, function-typed columns, template holes,
and the effect ladder.

## What this spike is

A real GADT, indexed by three things:

| Index | Rules out |
|---|---|
| `ctx :: [Type]` | a variable naming a slot the context lacks, or naming one at the wrong type |
| `e :: Eff` | a `Tx` term in a `Read` position — and `Eff` has **no** `Effect` rung, which *is* the missing `Effect a -> Tx a` lift |
| `a :: Type` | every cross-type operand error, including the old spike's actual bug |

Section 1 of `output.txt` lists eleven terms that fail to compile. **Every GHC error
quoted there was produced by compiling the term**, not written by hand. Section 1 also
lists what typing does *not* catch — anchoring, filter placement, call-graph
acyclicity, the bypassed-conjunct warning — each of which is a structural check in
`Spike.Analysis` instead, exercised in section 8.

## Layout

| Module | Contents |
|---|---|
| `Spike.Core` | the effect ladder, type witnesses, the `Term` GADT, queries, the four functor kinds |
| `Spike.Eval` | the interpreter, the store, the regex primitive, calendar arithmetic |
| `Spike.Schema` | the demo schema as DSL terms, annotated with the surface syntax each encodes |
| `Spike.Analysis` | the structural analyses the transparency invariant promises |

## Two honest limits

- **The regex engine is a stand-in.** `Text.Regex.TDFA` is the settled production
  choice, and it cannot be installed here — the sandbox denies writes to cabal's
  package store, so no new Hackage dependency can be built. What is validated is the
  *primitive's* shape: provenance carried in the effect index, a compiled-pattern cache
  keyed on the Configuration row version, and a malformed pattern failing at the point
  its provenance implies. Not the engine.
- **The store is a `Map`, not the storage engine.** Latency figures in section 11 are
  interpretation cost against an in-memory map, which is the right comparison for
  "how much does the interpreter add" and not a throughput claim.

## Build

```
cabal build && $(cabal list-bin functor-dsl-spike) > output.txt
```

`cabal` exits non-zero after a successful build because `$HOME` is read-only — read the
compiler output, not the exit code. Dependencies are `base`, `containers`, `text`, and
`time`, all in the global package DB, so nothing needs fetching.
