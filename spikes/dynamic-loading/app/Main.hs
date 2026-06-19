module Main (main) where

import Spike.HintApproach       (runHintSpike, HintResult (..))
import Spike.GADTDSLApproach    (runDSLSpike,  DSLResult (..))
import Spike.DynamicTypesApproach (runDynSpike, DynResult (..))
import Spike.Benchmark          (runBenchmark)

main :: IO ()
main = do
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   DataCode Dynamic Loading Feasibility Spike             ║"
  putStrLn "║   Three approaches to runtime schema evolution           ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

  -- Run approach 1: hint / GHC interpreter
  -- This requires GHC to be on PATH. If hint is not installed or GHC is
  -- unavailable, this will print an error but not crash.
  hintResult <- runHintSpike

  -- Run approach 2: GADT DSL interpreter
  -- Pure Haskell, no GHC dependency at runtime.
  dslResult <- runDSLSpike

  -- Run approach 3: Data.Dynamic + Typeable
  -- Pre-compiled type library with dynamic wiring.
  dynResult <- runDynSpike

  -- Benchmark: apply-latency at scale (approaches 2 and 3 only)
  runBenchmark

  -- Summary
  putStrLn "\n╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   SUMMARY                                                ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝\n"

  putStrLn "Approach 1 — hint (GHC interpreter)"
  putStrLn $ "  Success: " ++ show (hrSuccess hintResult)
  putStrLn $ "  Load latency: " ++ show (round (hrLoadLatencyMs hintResult) :: Int) ++ "ms"
  putStrLn "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (hrNotes hintResult)

  putStrLn ""
  putStrLn "Approach 2 — GADT DSL Interpreter"
  putStrLn $ "  Success: " ++ show (dslSuccess dslResult)
  putStrLn $ "  Load latency: " ++ show (round (dslLoadLatencyMs dslResult) :: Int) ++ "ms (zero — pure construction)"
  putStrLn "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (dslNotes dslResult)

  putStrLn ""
  putStrLn "Approach 3 — Data.Dynamic + Typeable"
  putStrLn $ "  Success: " ++ show (dynSuccess dynResult)
  putStrLn $ "  Load latency: " ++ show (round (dynLoadLatencyMs dynResult) :: Int) ++ "ms"
  putStrLn "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (dynNotes dynResult)

  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   RECOMMENDATION (fill in after reading results above)   ║"
  putStrLn "╠══════════════════════════════════════════════════════════╣"
  putStrLn "║                                                          ║"
  putStrLn "║   Proposed architecture:                                 ║"
  putStrLn "║   1. GADT DSL (Approach 2) as the primary functor        ║"
  putStrLn "║      mechanism — covers all four functor types,          ║"
  putStrLn "║      zero runtime GHC dependency, excellent performance  ║"
  putStrLn "║                                                          ║"
  putStrLn "║   2. Data.Dynamic (Approach 3) as the type registry      ║"
  putStrLn "║      substrate — DSL refers to types by name;            ║"
  putStrLn "║      TypeRep handles runtime type checking               ║"
  putStrLn "║                                                          ║"
  putStrLn "║   3. hint (Approach 1) as an escape hatch for            ║"
  putStrLn "║      advanced user-defined functors — sandboxed,         ║"
  putStrLn "║      audited, compiled async into the type registry      ║"
  putStrLn "║                                                          ║"
  putStrLn "║   4. Multi-daemon for schema daemon restarts when        ║"
  putStrLn "║      compiled-in types need to change                    ║"
  putStrLn "║                                                          ║"
  putStrLn "║   OPEN: Is hint latency acceptable? Is sandbox           ║"
  putStrLn "║   sufficient? Record measurements and decide.            ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"
