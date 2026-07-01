-- DataCode Storage Format Spike
-- OQ-003: Binary format — Cap'n Proto vs cereal
-- OQ-004: Storage engine — append log + LMDB
-- Row identifier design

module Main (main) where

import System.IO (hSetBuffering, stdout, BufferMode(..))
import System.Directory (createDirectoryIfMissing, removeFile, doesFileExist)
import System.FilePath ((</>))
import Control.Exception (try, SomeException)

import Spike.RowId    (runRowIdSpike)
import Spike.TxLog    (TxLogResult(..), runTxLogSpike)
import Spike.LmdbIndex (LmdbResult(..), runLmdbSpike)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering

  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   DataCode Storage Format Spike                          ║"
  putStrLn "║   OQ-003: binary format  |  OQ-004: storage engine       ║"
  putStrLn "║   Plus: row identifier design                            ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

  -- Set up temp paths
  let tmpDir  = "/tmp/datacode-storage-spike"
  let logPath = tmpDir </> "transactions.log"
  let dbPath  = tmpDir </> "lmdb"

  createDirectoryIfMissing True tmpDir
  createDirectoryIfMissing True dbPath

  -- Clean up any previous log file
  logExists <- doesFileExist logPath
  if logExists then removeFile logPath else return ()

  -- Run all three parts
  runRowIdSpike

  txResult   <- runTxLogSpike logPath
  lmdbResult <- runLmdbSpike dbPath

  -- Summary
  putStrLn "\n╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   SUMMARY                                                ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝\n"

  putStrLn "Row Identifier (chosen: composite 14-byte RowId)"
  putStrLn "  ShardId:Word32 + TxSeq:Word64 + RowPos:Word16"
  putStrLn "  Big-endian encoding: LMDB lexicographic order = numeric order"
  putStrLn "  User-facing: UUID primary key → head_index → current RowId"

  putStrLn ""
  putStrLn "Binary Transaction Log (cereal)"
  putStrLn $ "  Success: " ++ show (logSuccess txResult)
  putStrLn $ "  Encode: " ++ showUs (logEncodeLatencyUs txResult) ++ "/tx"
  putStrLn $ "  Decode: " ++ showUs (logDecodeLatencyUs txResult) ++ "/tx"
  putStrLn   "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (logNotes txResult)

  putStrLn ""
  putStrLn "LMDB Index"
  putStrLn $ "  Success: " ++ show (lmdbSuccess lmdbResult)
  putStrLn $ "  Write: " ++ showUs (lmdbWriteLatencyUs lmdbResult) ++ "/entry"
  putStrLn $ "  Read:  " ++ showUs (lmdbReadLatencyUs  lmdbResult) ++ "/entry"
  putStrLn   "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (lmdbNotes lmdbResult)

  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   RECOMMENDATIONS                                        ║"
  putStrLn "╠══════════════════════════════════════════════════════════╣"
  putStrLn "║                                                          ║"
  putStrLn "║   OQ-003 (binary format): Use Cap'n Proto for production ║"
  putStrLn "║   Use cereal during initial development — same API, swap ║"
  putStrLn "║   Serialize instances later. Cap'n Proto adds:           ║"
  putStrLn "║     * Automatic schema evolution (no version bytes)      ║"
  putStrLn "║     * Zero-copy mmap: disk format IS the in-memory repr  ║"
  putStrLn "║     * Standard wire format for server-to-server replic.  ║"
  putStrLn "║   Build cost: capnp C++ tool required at compile time.   ║"
  putStrLn "║   Protobuf is NOT a substitute — it requires full parse. ║"
  putStrLn "║                                                          ║"
  putStrLn "║   OQ-004 (storage): Confirmed hybrid architecture:       ║"
  putStrLn "║     * Append-only log file (Cap'n Proto frames on disk)  ║"
  putStrLn "║       — the transaction graph, immutable, sequentially   ║"
  putStrLn "║         written, mmap-readable without deserialization   ║"
  putStrLn "║     * LMDB log_index: RowId → log file offset           ║"
  putStrLn "║       — random access to any version by RowId            ║"
  putStrLn "║     * LMDB head_index: UUID PK → current RowId          ║"
  putStrLn "║       — resolves logical row to current physical version  ║"
  putStrLn "║     * Materialized views: separate LMDB database, same   ║"
  putStrLn "║       key structure, rebuilt from transaction log        ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Full read path (zero-copy with Cap'n Proto + LMDB):   ║"
  putStrLn "║     UUID → head_index → RowId                           ║"
  putStrLn "║          → log_index  → (file_offset, length)           ║"
  putStrLn "║          → mmap[offset:length] → Cap'n Proto message    ║"
  putStrLn "║          → field access via pointer arithmetic (no copy) ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs"
