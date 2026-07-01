-- Row Identifier Design
--
-- A RowId uniquely identifies a row version across the entire cluster.
-- Three options are evaluated:
--
--   A. Composite (ShardId, TxSeq, RowPos) — 14 bytes
--      Self-describing: you can find the physical record from the ID alone.
--      Big-endian encoding preserves LMDB sort order.
--
--   B. Content-addressed SHA-256 — 32 bytes
--      Globally unique, content-verified. Cannot sort by shard/time.
--      Better for inter-server integrity proofs than as a primary key.
--
--   C. Hybrid — logical UUID (primary key declared in schema) as the user-facing
--      identifier, physical RowId (Option A) as the internal version pointer.
--      The LMDB head index maps UUID → current RowId.
--
-- CHOSEN: Option A for the physical version ID (transaction log entries and
-- internal references). Option C for user-facing identifiers — the schema
-- declares a UUID primary key; LMDB maps that UUID to the current head RowId.
-- Option B is used for schema version hashes, not row IDs.

module Spike.RowId
  ( RowId (..)
  , encodeRowId
  , decodeRowId
  , rowIdBytes
  , txNodeId
  , showRowId
  , runRowIdSpike
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Serialize (Serialize, put, get, encode, decode)
import qualified Data.Serialize as S
import Data.Word
import Data.List (sort)

-- ---------------------------------------------------------------------------
-- Row Identifier

data RowId = RowId
  { ridShard  :: !Word32  -- shard index (4 bytes; supports ~4B shards)
  , ridTxSeq  :: !Word64  -- monotonic tx sequence within shard (8 bytes)
  , ridRowPos :: !Word16  -- row position within transaction (2 bytes; max 65535 rows/tx)
  } deriving (Eq, Ord, Show)

-- Cereal instance uses big-endian encoding throughout.
-- Big-endian is critical: LMDB sorts keys lexicographically, and
-- big-endian integer encoding makes lexicographic = numeric order.
-- This means a range scan over all rows in shard 1, tx 100–200
-- is a single contiguous LMDB range scan — no scatter-gather needed.
instance Serialize RowId where
  put RowId{..} = do
    S.putWord32be ridShard
    S.putWord64be ridTxSeq
    S.putWord16be ridRowPos
  get = RowId <$> S.getWord32be <*> S.getWord64be <*> S.getWord16be

rowIdBytes :: Int
rowIdBytes = 14  -- 4 + 8 + 2

encodeRowId :: RowId -> ByteString
encodeRowId = encode

decodeRowId :: ByteString -> Either String RowId
decodeRowId = decode

-- The RowId of a transaction node itself: rowPos = 0
txNodeId :: Word32 -> Word64 -> RowId
txNodeId shard txSeq = RowId shard txSeq 0

showRowId :: RowId -> String
showRowId RowId{..} =
  "shard:" ++ show ridShard ++
  "/tx:" ++ show ridTxSeq ++
  "/row:" ++ show ridRowPos

-- ---------------------------------------------------------------------------
-- Spike runner

runRowIdSpike :: IO ()
runRowIdSpike = do
  putStrLn "\n=== Part 1: Row Identifier Design ===\n"

  -- Demonstrate encoding and size
  let rid = RowId 1 42 3
  let encoded = encodeRowId rid
  putStrLn $ "RowId " ++ showRowId rid
  putStrLn $ "  Encoded: " ++ show (B.length encoded) ++ " bytes"
  putStrLn $ "  Hex: " ++ hexShow encoded

  -- Round-trip
  case decodeRowId encoded of
    Left err  -> putStrLn $ "  DECODE FAILED: " ++ err
    Right rid' -> putStrLn $ "  Round-trip: " ++ if rid == rid' then "OK" else "FAILED"

  -- Demonstrate that LMDB sort order = numeric order
  putStrLn "\nSort order test (LMDB lexicographic = numeric for big-endian):"
  let ids =
        [ RowId 0 1   0
        , RowId 0 1   1
        , RowId 0 2   0
        , RowId 1 1   0
        , RowId 0 100 0
        , RowId 0 99  999
        ]
  let encoded' = map (\r -> (encodeRowId r, r)) ids
  let sorted   = sort encoded'  -- sort by ByteString (LMDB's order)
  putStrLn "  Sorted by encoded bytes (LMDB order):"
  mapM_ (\(_, r) -> putStrLn $ "    " ++ showRowId r) sorted
  putStrLn "  Expected: shard order first, then txSeq, then rowPos"
  -- Verify: ByteString sort order matches Haskell's Ord instance
  let sortedRids    = map snd sorted
  let ordSortedRids = sort ids
  putStrLn $ "  Matches Haskell Ord: " ++ show (sortedRids == ordSortedRids)

  -- Demonstrate txNodeId convention
  putStrLn "\nTransaction node IDs (rowPos = 0 by convention):"
  let txIds = map (uncurry txNodeId) [(0,1), (0,2), (1,1), (1,100)]
  mapM_ (putStrLn . ("  " ++) . showRowId) txIds

  putStrLn "\nSummary:"
  putStrLn $ "  RowId size: " ++ show rowIdBytes ++ " bytes"
  putStrLn   "  Encoding: big-endian (LMDB range-scan compatible)"
  putStrLn   "  Shard:TxSeq:RowPos order supports cluster-level provenance"
  putStrLn   "  User-facing: schema-declared UUID primary key → current RowId (LMDB head index)"

-- Utility: show ByteString as hex
hexShow :: ByteString -> String
hexShow = concatMap (\b -> let h = showHex b in h) . B.unpack
  where
    showHex b =
      let hi = b `div` 16
          lo = b `mod` 16
      in [hexChar hi, hexChar lo, ' ']
    hexChar n
      | n < 10    = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)

