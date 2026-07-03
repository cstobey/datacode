module Main where

import System.IO        (hSetBuffering, stdout, BufferMode(..))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.FilePath  ((</>))

import Spike.CapnProto (CapnResult(..), runCapnProtoSpike)
import Spike.ZeroCopy  (ZeroCopyResult(..), runZeroCopySpike)
import Spike.Evolution (EvolutionResult(..), runEvolutionSpike)
import Spike.LmdbFixed (LmdbFixedResult(..), runLmdbFixedSpike)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering

  putStrLn "================================================"
  putStrLn "Cap'n Proto + LMDB Feasibility Spike (OQ-003 / OQ-004)"
  putStrLn "================================================"

  tmpDir <- getTemporaryDirectory
  let spikeDir = tmpDir </> "capnproto-spike"
  createDirectoryIfMissing True spikeDir

  let msgFile = spikeDir </> "txnode.capnp"
  let lmdbDir = spikeDir </> "lmdb"
  createDirectoryIfMissing True lmdbDir

  cap  <- runCapnProtoSpike
  zc   <- runZeroCopySpike msgFile
  ev   <- runEvolutionSpike
  lmdb <- runLmdbFixedSpike lmdbDir

  putStrLn "\n================================================"
  putStrLn "SUMMARY"
  putStrLn "================================================"
  putStrLn $ "Cap'n Proto encoding:   " ++ pass (capnSuccess cap)
  putStrLn $ "mmap zero-copy:         " ++ pass (zcSuccess zc)
  putStrLn $ "Schema evolution:       " ++ pass (evSuccess ev)
  putStrLn $ "LMDB threading fix:     " ++ pass (lmdbFixedSuccess lmdb)

  putStrLn ""
  putStrLn "Key latencies:"
  putStrLn $ "  Encode:          " ++ µs (capnEncodeLatencyUs cap)   ++ "/tx"
  putStrLn $ "  Full decode:     " ++ µs (capnDecodeLatencyUs cap)   ++ "/tx"
  putStrLn $ "  Zero-copy field: " ++ µs (capnZeroCopyLatencyUs cap) ++ "/tx"
  putStrLn $ "  LMDB write:      " ++ µs (lmdbFixedWriteLatencyUs lmdb)
  putStrLn $ "  LMDB read:       " ++ µs (lmdbFixedReadLatencyUs lmdb)
  putStrLn $ "  mmap zero-copy:  " ++ µs (zcMmapReadLatencyUs zc)

  putStrLn ""
  putStrLn "Architecture confirmed:"
  putStrLn "  UUID → head_index (LMDB) → RowId → log_index (LMDB) → (offset, len)"
  putStrLn "  → mmap[offset:len] → Cap'n Proto struct → pointer arithmetic"
  putStrLn ""
  putStrLn "Migration path: swap cereal Serialize instances for capnp-generated"
  putStrLn "Cerialize/Decerialize. Wire framing (length-prefix + segment) is identical."

  removePathForcibly spikeDir

pass :: Bool -> String
pass True  = "PASS"
pass False = "FAIL (see output above)"

µs :: Double -> String
µs d = show (round d :: Int) ++ "µs"
