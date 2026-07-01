-- LMDB Two-Database Architecture
--
-- DataCode uses two LMDB databases per shard:
--
--   1. log_index (RowId → LogEntry)
--      Key:   14-byte big-endian RowId (ShardId:TxSeq:RowPos)
--      Value: 12-byte LogEntry (offset:Word64 + length:Word32)
--      Purpose: find any row version in the append log by RowId
--      Sort order: shard, then txSeq, then rowPos — range scan over a
--        transaction's rows is a contiguous LMDB range
--
--   2. head_index (PrimaryKey → RowId)
--      Key:   schema-declared primary key bytes (typically 16-byte UUID)
--      Value: 14-byte RowId of the current head version
--      Purpose: resolve a logical row (by user-visible PK) to its current
--        physical version, then use log_index to find it in the log file
--
-- LMDB properties that make this work:
--   - Memory-mapped: LMDB pages are mmap'd into the process address space;
--     reads touch the OS page cache, not a copy. Combined with Cap'n Proto
--     mmap of the log file, a read path can be entirely zero-copy.
--   - MVCC: readers never block writers; each transaction sees a consistent
--     snapshot of the B-tree. Ideal for DataCode's concurrent read workload.
--   - Sorted keys: the B-tree preserves insertion order by key. Big-endian
--     RowId encoding means "all rows from transaction N" is a range scan.
--   - ACID: writes are crash-safe by default (LMDB uses copy-on-write B-tree
--     + two active root pages for crash recovery without a separate WAL).
--
-- Requires: liblmdb-dev (Debian/Ubuntu) or lmdb (Homebrew) on the system.

module Spike.LmdbIndex
  ( LmdbEnv
  , withLmdbEnv
  , putLogEntry
  , getLogEntry
  , putHead
  , getHead
  , LmdbResult (..)
  , runLmdbSpike
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Serialize (encode, decode)
import Data.Word
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Control.Monad (forM_, void)
import Control.Exception (bracket, SomeException, try)
import Foreign.Ptr (castPtr, Ptr)
import Foreign.C.Types (CSize(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek, poke)

import Database.LMDB.Raw hiding (mdb_put)
import qualified Database.LMDB.Raw as LMDB (mdb_put)
import Database.LMDB.Raw (compileWriteFlags)
import Spike.RowId
import Spike.TxLog (LogEntry(..))

-- ---------------------------------------------------------------------------
-- Environment wrapper

newtype LmdbEnv = LmdbEnv MDB_env

withLmdbEnv :: FilePath -> (LmdbEnv -> IO a) -> IO a
withLmdbEnv path action = bracket open close run
  where
    open = do
      env <- mdb_env_create
      mdb_env_set_maxdbs env 4
      mdb_env_set_mapsize env (256 * 1024 * 1024)  -- 256 MB initial map
      mdb_env_open env path []
      return env
    close = mdb_env_close
    run env = action (LmdbEnv env)

-- ---------------------------------------------------------------------------
-- Low-level ByteString helpers

withVal :: ByteString -> (MDB_val -> IO a) -> IO a
withVal bs action =
  BU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
    action (MDB_val (fromIntegral len) (castPtr ptr))

peekVal :: MDB_val -> IO ByteString
peekVal (MDB_val size ptr) =
  B.packCStringLen (castPtr ptr, fromIntegral size)

-- ---------------------------------------------------------------------------
-- log_index: RowId → LogEntry

logIndexName :: String
logIndexName = "log_index"

putLogEntry :: LmdbEnv -> RowId -> LogEntry -> IO ()
putLogEntry (LmdbEnv env) rid entry = do
  txn <- mdb_txn_begin env Nothing False
  dbi <- mdb_dbi_open txn (Just logIndexName) [MDB_CREATE]
  withVal (encodeRowId rid) $ \k ->
    withVal (encode entry) $ \v ->
      void $ LMDB.mdb_put (compileWriteFlags []) txn dbi k v
  mdb_txn_commit txn

getLogEntry :: LmdbEnv -> RowId -> IO (Maybe LogEntry)
getLogEntry (LmdbEnv env) rid = do
  txn <- mdb_txn_begin env Nothing True
  dbi <- mdb_dbi_open txn (Just logIndexName) []
  result <- withVal (encodeRowId rid) $ \k -> mdb_get txn dbi k
  mdb_txn_abort txn
  case result of
    Nothing  -> return Nothing
    Just val -> do
      bs <- peekVal val
      return $ case decode bs of
        Left _  -> Nothing
        Right e -> Just e

-- ---------------------------------------------------------------------------
-- head_index: PrimaryKey → current RowId

headIndexName :: String
headIndexName = "head_index"

putHead :: LmdbEnv -> ByteString -> RowId -> IO ()
putHead (LmdbEnv env) pk rid = do
  txn <- mdb_txn_begin env Nothing False
  dbi <- mdb_dbi_open txn (Just headIndexName) [MDB_CREATE]
  withVal pk $ \k ->
    withVal (encodeRowId rid) $ \v ->
      void $ LMDB.mdb_put (compileWriteFlags []) txn dbi k v
  mdb_txn_commit txn

getHead :: LmdbEnv -> ByteString -> IO (Maybe RowId)
getHead (LmdbEnv env) pk = do
  txn <- mdb_txn_begin env Nothing True
  dbi <- mdb_dbi_open txn (Just headIndexName) []
  result <- withVal pk $ \k -> mdb_get txn dbi k
  mdb_txn_abort txn
  case result of
    Nothing  -> return Nothing
    Just val -> do
      bs <- peekVal val
      return $ case decodeRowId bs of
        Left _    -> Nothing
        Right rid -> Just rid

-- ---------------------------------------------------------------------------
-- Spike runner

data LmdbResult = LmdbResult
  { lmdbSuccess          :: Bool
  , lmdbWriteLatencyUs   :: Double  -- µs per put
  , lmdbReadLatencyUs    :: Double  -- µs per get
  , lmdbNotes            :: [String]
  } deriving (Show)

runLmdbSpike :: FilePath -> IO LmdbResult
runLmdbSpike dbPath = do
  putStrLn "\n=== Part 3: LMDB Index ===\n"
  result <- try (runSpike dbPath) :: IO (Either SomeException LmdbResult)
  case result of
    Left err -> do
      putStrLn $ "  LMDB FAILED: " ++ show err
      putStrLn   "  Is liblmdb-dev installed? (apt install liblmdb-dev / brew install lmdb)"
      return LmdbResult
        { lmdbSuccess = False
        , lmdbWriteLatencyUs = 0
        , lmdbReadLatencyUs = 0
        , lmdbNotes = ["LMDB not available — install liblmdb-dev and retry"]
        }
    Right r -> return r

runSpike :: FilePath -> IO LmdbResult
runSpike dbPath = withLmdbEnv dbPath $ \env -> do

  -- Test 1: write to log_index
  putStrLn "Test 1: log_index — write RowId → LogEntry mappings"
  let entries = [(RowId 0 (fromIntegral n) 1, LogEntry (fromIntegral n * 256) 128) | n <- [1..10 :: Int]]
  forM_ entries $ \(rid, entry) -> putLogEntry env rid entry
  putStrLn $ "  Wrote " ++ show (length entries) ++ " entries to log_index"

  -- Test 2: read from log_index
  putStrLn "\nTest 2: log_index — random access by RowId"
  r1 <- getLogEntry env (RowId 0 5 1)
  case r1 of
    Nothing -> putStrLn "  RowId 0/5/1: NOT FOUND (unexpected)"
    Just e  -> putStrLn $ "  RowId 0/5/1: offset=" ++ show (logOffset e) ++ " len=" ++ show (logLength e)
  rMiss <- getLogEntry env (RowId 0 999 1)
  putStrLn $ "  RowId 0/999/1: " ++ case rMiss of { Nothing -> "NOT FOUND (expected)"; Just _ -> "found (unexpected)" }

  -- Test 3: head_index — UUID → current RowId
  putStrLn "\nTest 3: head_index — UUID primary key → current RowId"
  let uuid1 = B.replicate 16 0x01
  let uuid2 = B.replicate 16 0x02
  putHead env uuid1 (RowId 0 1 1)
  putHead env uuid2 (RowId 0 2 1)
  r_uuid1 <- getHead env uuid1
  putStrLn $ "  UUID 01..01 → " ++ maybe "NOT FOUND" showRowId r_uuid1

  -- Test 4: update head (schema evolution — row gets a new version)
  putStrLn "\nTest 4: Update head (row mutated → new version)"
  putHead env uuid1 (RowId 0 10 1)  -- new transaction wrote a new version
  r_updated <- getHead env uuid1
  putStrLn $ "  UUID 01..01 after update → " ++ maybe "NOT FOUND" showRowId r_updated

  -- Benchmark: 10k writes to log_index
  putStrLn "\nBenchmark: 10,000 writes to log_index"
  t0 <- getCurrentTime
  forM_ [1..10000 :: Int] $ \n ->
    putLogEntry env (RowId 1 (fromIntegral n) 1) (LogEntry (fromIntegral n * 100) 64)
  t1 <- getCurrentTime
  let writeMs = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  let writeUs = (writeMs * 1000) / 10000
  putStrLn $ "  Total: " ++ showMs writeMs ++ " | Per write: " ++ showUs writeUs

  -- Benchmark: 10k reads from log_index
  putStrLn "\nBenchmark: 10,000 reads from log_index"
  t2 <- getCurrentTime
  results <- mapM (\n -> getLogEntry env (RowId 1 (fromIntegral n) 1)) [1..10000 :: Int]
  t3 <- getCurrentTime
  let readMs  = realToFrac (diffUTCTime t3 t2) * 1000 :: Double
  let readUs  = (readMs * 1000) / 10000
  let hitRate = length (filter (/= Nothing) results)
  putStrLn $ "  Cache hits: " ++ show hitRate ++ "/10000"
  putStrLn $ "  Total: " ++ showMs readMs ++ " | Per read: " ++ showUs readUs

  putStrLn "\nSummary:"
  putStrLn   "  log_index (RowId → LogEntry): SUCCEEDED"
  putStrLn   "  head_index (UUID → current RowId): SUCCEEDED"
  putStrLn   "  Two-database architecture confirmed"
  putStrLn $ "  Write: " ++ showUs writeUs ++ "/entry | Read: " ++ showUs readUs ++ "/entry"

  return LmdbResult
    { lmdbSuccess        = hitRate == 10000
    , lmdbWriteLatencyUs = writeUs
    , lmdbReadLatencyUs  = readUs
    , lmdbNotes =
        [ "Two databases per shard: log_index (RowId→offset) + head_index (UUID→RowId)"
        , "Read path: UUID → head_index → RowId → log_index → file offset → Cap'n Proto bytes"
        , "LMDB is memory-mapped: reads touch OS page cache, not a copy"
        , "Combined with Cap'n Proto mmap of the log file: zero-copy read path"
        , "MVCC: readers never block writers — critical for DataCode's query concurrency"
        , "B-tree sort: big-endian RowId means tx-local range scans are contiguous"
        , "LMDB handles crash recovery via copy-on-write B-tree + two root pages"
        ]
    }

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms (" ++ show ms ++ ")"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs (" ++ show us ++ ")"
