-- Benchmark: compare apply-latency across all three approaches at scale
-- Simulates a realistic commit workload: N records, each validated by M functors.

module Spike.Benchmark
  ( runBenchmark
  , BenchResult (..)
  ) where

import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Control.Monad (forM_, replicateM)
import Data.Dynamic (toDyn)

import Spike.GADTDSLApproach
  ( SchemaVal (..), FunctorExpr (..), Expr (..), applyFunctor )
import Spike.DynamicTypesApproach
  ( registerFunctor, applyDynFunctor, DynFunctor, FunctorKind (..) )

data BenchResult = BenchResult
  { brApproach       :: String
  , brRecordCount    :: Int
  , brFunctorCount   :: Int
  , brTotalMs        :: Double
  , brPerRecordUs    :: Double   -- microseconds per record
  } deriving (Show)

-- Number of records to validate in each benchmark run
recordCount :: Int
recordCount = 10000

-- ---------------------------------------------------------------------------
-- DSL Approach Benchmark

benchDSL :: IO BenchResult
benchDSL = do
  -- Build the functors once (represents schema load time, not per-commit cost)
  let functors =
        [ FValidate "PositiveAmount" "amount"
            (EGt (EVar "amount") (ELitInt 0))
            (ELitText "Amount must be positive")
        , FValidate "EmailContainsAt" "email"
            (EContains (EVar "email") (ELitText "@"))
            (ELitText "Invalid email")
        , FValidate "NonEmptyName" "name"
            (EGt (ELength (EVar "name")) (ELitInt 0))
            (ELitText "Name must not be empty")
        ]

  -- Generate test records
  let records = take recordCount $ cycle
        [ [("amount", SInt 42),  ("email", SText "a@b.com"), ("name", SText "Alice")]
        , [("amount", SInt 100), ("email", SText "c@d.org"), ("name", SText "Bob")]
        , [("amount", SInt 7),   ("email", SText "e@f.net"), ("name", SText "Carol")]
        ]

  (totalMs, _) <- timed $ do
    forM_ records $ \ctx ->
      let results = map (applyFunctor ctx) functors
      in results `seq` return ()

  let perRecordUs = (totalMs * 1000) / fromIntegral recordCount
  return $ BenchResult "GADT DSL" recordCount (length functors) totalMs perRecordUs

-- ---------------------------------------------------------------------------
-- Dynamic/Typeable Approach Benchmark

newtype BenchAmount = BenchAmount Int deriving (Show, Eq)

benchDynamic :: IO BenchResult
benchDynamic = do
  -- Build functors once
  let validateAmount (BenchAmount n)
        | n > 0    = Right (BenchAmount n)
        | otherwise = Left "Amount must be positive"

  let amountFunctor = registerFunctor "PositiveAmount" Validation validateAmount

  let functors = [amountFunctor]

  -- Generate test values
  let values = take recordCount $ cycle
        [ toDyn (BenchAmount 42)
        , toDyn (BenchAmount 100)
        , toDyn (BenchAmount 7)
        ]

  (totalMs, _) <- timed $ do
    forM_ values $ \dyn ->
      let result = applyDynFunctor amountFunctor dyn
      in result `seq` return ()

  let perRecordUs = (totalMs * 1000) / fromIntegral recordCount
  return $ BenchResult "Data.Dynamic" recordCount (length functors) totalMs perRecordUs

-- ---------------------------------------------------------------------------
-- Runner

runBenchmark :: IO ()
runBenchmark = do
  putStrLn "\n=== Benchmark: Apply Latency at Scale ===\n"
  putStrLn $ "Records per run: " ++ show recordCount
  putStrLn ""

  dslResult <- benchDSL
  dynResult <- benchDynamic

  let results = [dslResult, dynResult]

  putStrLn $ padRight 20 "Approach"
          ++ padRight 10 "Records"
          ++ padRight 10 "Functors"
          ++ padRight 12 "Total(ms)"
          ++ "Per-record(µs)"
  putStrLn $ replicate 65 '-'

  forM_ results $ \r ->
    putStrLn $ padRight 20 (brApproach r)
            ++ padRight 10 (show (brRecordCount r))
            ++ padRight 10 (show (brFunctorCount r))
            ++ padRight 12 (showMs (brTotalMs r))
            ++ showUs (brPerRecordUs r)

  putStrLn ""
  putStrLn "Note: hint approach not included in benchmark — compilation latency"
  putStrLn "      makes per-record comparison meaningless. See Test 5 in hint output"
  putStrLn "      for compilation-time measurements."

  putStrLn "\nInterpretation guide:"
  putStrLn "  < 1µs/record   : excellent — no concern at any realistic scale"
  putStrLn "  1-10µs/record  : good — fine for OLTP, check at very high volume"
  putStrLn "  10-100µs/record: marginal — will dominate at >100k writes/sec"
  putStrLn "  > 100µs/record : problematic — bottleneck"

padRight :: Int -> String -> String
padRight n s = take n (s ++ repeat ' ')

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs (" ++ show us ++ ")"

timed :: IO a -> IO (Double, a)
timed action = do
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  let ms = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  return (ms, result)
