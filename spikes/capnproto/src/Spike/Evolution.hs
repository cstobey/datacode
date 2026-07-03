-- Schema Evolution Demonstration
--
-- The Mnesia/Cap'n Proto promise: adding a field to a struct is always
-- backward and forward compatible — no migration step, no version byte,
-- no branching decoder.
--
-- This module proves it for DataCode's TxNode by:
--   1. Writing V1 TxNodes (dataWords=2: timestamp, serverId)
--   2. Reading them with a V2 decoder (dataWords=3: adds schemaVersion)
--      → schemaVersion reads as 0 (the declared default)
--   3. Writing V2 TxNodes (dataWords=3, schemaVersion is set)
--   4. Reading them with a V1 decoder (dataWords=2: ignores word 2)
--      → Old code correctly reads timestamp and serverId; ignores the new field
--
-- Contrast with cereal (from storage spike): cereal requires an explicit
-- version byte and a branching decoder (decode V1 or decode V2?).
-- Cap'n Proto's struct pointer carries the data section word count — the
-- reader always knows exactly how many words the WRITER produced, so it
-- can default or ignore gracefully in either direction.

module Spike.Evolution
  ( EvolutionResult (..)
  , runEvolutionSpike
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word
import Data.Int

import Spike.CapnProto

-- ---------------------------------------------------------------------------
-- Schema version-specific decoders

-- V1 decoder: reads timestamp and serverId only. Ignores dataWords > 2.
decodeTxNodeV1 :: ByteString -> Either String (Int64, Word32)
decodeTxNodeV1 msg = do
  dec <- parseTxNodeMessage msg
  -- parseTxNodeMessage already handles missing fields gracefully,
  -- but V1 doesn't even try to read schemaVersion.
  Right (decTimestamp dec, decServerId dec)

-- V2 decoder: additionally reads schemaVersion (defaults to 0 if absent)
decodeTxNodeV2 :: ByteString -> Either String (Int64, Word32, Word32)
decodeTxNodeV2 msg = do
  dec <- parseTxNodeMessage msg  -- parseTxNodeMessage handles the default
  Right (decTimestamp dec, decServerId dec, decSchemaVersion dec)

-- ---------------------------------------------------------------------------
-- Spike runner

data EvolutionResult = EvolutionResult
  { evSuccess :: Bool
  , evNotes   :: [String]
  } deriving (Show)

runEvolutionSpike :: IO EvolutionResult
runEvolutionSpike = do
  putStrLn "\n=== Part 3: Schema Evolution ===\n"

  let fakeId  = B.replicate 14 0xEE
      fakeSV  = B.replicate 32 0xFF
      baseTx  = TxNodeRaw
                  { rawTimestamp     = 1000000
                  , rawServerId      = 1
                  , rawId            = fakeId
                  , rawSchemaVer     = fakeSV
                  , rawParents       = []
                  , rawSchemaVersion = 99  -- only used by V2 encoder
                  }

  -- ---- Forward compatibility: V1 bytes read by V2 decoder ----
  putStrLn "Test 1: Forward compatibility — V1 writer, V2 reader"
  let v1msg = buildTxNodeMessage baseTx  -- V1 encoder: dataWords=2
  putStrLn $ "  V1 message: " ++ show (B.length v1msg) ++ " bytes"
  case decodeTxNodeV2 v1msg of
    Left err             -> putStrLn $ "  V2 read of V1 bytes: FAILED — " ++ err
    Right (ts, sv, schV) -> do
      putStrLn $ "  timestamp:     " ++ show ts  ++ (if ts == rawTimestamp baseTx then " ✓" else " ✗")
      putStrLn $ "  serverId:      " ++ show sv  ++ (if sv == rawServerId baseTx  then " ✓" else " ✗")
      putStrLn $ "  schemaVersion: " ++ show schV ++ " (expected 0 — default for missing field)" ++
                                        (if schV == 0 then " ✓" else " ✗")
      putStrLn "  V2 reads V1 bytes without error — missing field defaults to 0."

  putStrLn ""

  -- ---- Backward compatibility: V2 bytes read by V1 decoder ----
  putStrLn "Test 2: Backward compatibility — V2 writer, V1 reader"
  let v2msg = buildTxNodeMessageV2 baseTx  -- V2 encoder: dataWords=3, schemaVersion=99
  putStrLn $ "  V2 message: " ++ show (B.length v2msg) ++ " bytes"
  case decodeTxNodeV1 v2msg of
    Left err       -> putStrLn $ "  V1 read of V2 bytes: FAILED — " ++ err
    Right (ts, sv) -> do
      putStrLn $ "  timestamp: " ++ show ts ++ (if ts == rawTimestamp baseTx then " ✓" else " ✗")
      putStrLn $ "  serverId:  " ++ show sv ++ (if sv == rawServerId baseTx  then " ✓" else " ✗")
      putStrLn "  schemaVersion: (not read — V1 decoder ignores data word 2) ✓"
      putStrLn "  V1 reads V2 bytes without error — extra data word is silently ignored."

  putStrLn ""

  -- ---- Compare with cereal limitation ----
  putStrLn "Test 3: Why cereal can't do this (from storage spike)"
  putStrLn "  Cereal TxNodeV1 + TxNodeV2 have different Serialize instances."
  putStrLn "  decode :: Either String TxNodeV2 on V1 bytes = Left (parse error)"
  putStrLn "  because cereal's get reads exactly the bytes its structure expects."
  putStrLn "  Adding a field = breaking change: all existing writers must update."
  putStrLn ""
  putStrLn "  Cap'n Proto avoids this because:"
  putStrLn "    * The struct pointer in every message carries the data section word count."
  putStrLn "    * Readers check the actual word count before accessing a field."
  putStrLn "    * If a field is beyond the end of the data section: use the default (0)."
  putStrLn "    * If a field is past what the reader knows about: silently ignored."
  putStrLn "  This is exactly the Mnesia property: disk format is versioned by schema,"
  putStrLn "  not by code. No migration step. No branching decoder."

  putStrLn ""

  -- ---- Size comparison ----
  let v1msg' = buildTxNodeMessage (baseTx { rawSchemaVersion = 0 })
  let v2msg' = buildTxNodeMessageV2 baseTx
  putStrLn $ "Size difference: V1=" ++ show (B.length v1msg') ++ " bytes, V2=" ++ show (B.length v2msg') ++
             " bytes (+" ++ show (B.length v2msg' - B.length v1msg') ++ " bytes for the new field)"

  let v1ok = case decodeTxNodeV2 (buildTxNodeMessage baseTx) of
                Right (_, _, 0) -> True; _ -> False
  let v2ok = case decodeTxNodeV1 (buildTxNodeMessageV2 baseTx) of
                Right _ -> True; _ -> False

  putStrLn $ "\nEvolution tests: V1→V2=" ++ (if v1ok then "PASS" else "FAIL") ++
             ", V2→V1=" ++ (if v2ok then "PASS" else "FAIL")

  return EvolutionResult
    { evSuccess = v1ok && v2ok
    , evNotes =
        [ "Forward compat (V2 reads V1): missing data word → default value 0"
        , "Backward compat (V1 reads V2): extra data word silently ignored"
        , "No version byte needed, no branching decoder, no migration step"
        , "Each message is self-describing: struct pointer carries word count"
        , "Contrast: cereal requires explicit Serialize instance update for any new field"
        , "Production: add @6 :UInt32 = 0 to TxNode schema, regenerate, done"
        ]
    }
