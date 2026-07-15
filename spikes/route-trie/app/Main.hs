-- DataCode Route Trie Spike
--
-- Answers OQ-029: what data structure should back DataCode's custom-API router?
-- The servant-warp spike (OQ-002) used an exact-key Map lookup, which breaks
-- when custom routes have path parameters like /orders/{id}/ship.
--
-- Three options evaluated:
--   A. Hand-rolled route trie    — O(depth × log fanout), correct precedence
--   B. Linear scan               — O(routes), correct but fails the 1µs target
--   C. wai-routes / path-piece   — architectural analysis; no code needed

module Main (main) where

import Spike.RouteTrie  (TrieResult (..), runTrieSpike)
import Spike.LinearScan (ScanResult (..), runLinearSpike)

main :: IO ()
main = do
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   DataCode: Route Trie Spike                             ║"
  putStrLn "║   OQ-029: Trie vs. dispatch table for pattern routing    ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

  trieResult <- runTrieSpike
  scanResult <- runLinearSpike

  putStrLn "\n╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   SUMMARY                                                ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝\n"

  putStrLn "Approach A — Route Trie"
  putStrLn $ "  Success: "        ++ show (trieSuccess trieResult)
  putStrLn $ "  Routes tested: "  ++ show (trieRouteCount trieResult)
  putStrLn $ "  Routing latency: " ++ showUs (trieLatencyUs trieResult)
  putStrLn   "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (trieNotes trieResult)

  putStrLn ""
  putStrLn "Approach B — Linear Scan"
  putStrLn $ "  Routes tested: "  ++ show (scanRouteCount scanResult)
  putStrLn $ "  Routing latency: " ++ showUs (scanLatencyUs scanResult) ++ " (10k routes)"
  putStrLn   "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (scanNotes scanResult)

  putStrLn ""
  putStrLn "Approach C — wai-routes / path-piece (architectural, no code)"
  putStrLn "  - wai-routes: Template Haskell compile-time routes — incompatible with"
  putStrLn "    DataCode's runtime-registered custom routes"
  putStrLn "  - path-piece: type class for parsing path segments, NOT a router —"
  putStrLn "    does not provide trie or dispatch logic"
  putStrLn "  - Neither library fits; both are compile-time solutions for a runtime problem"

  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   RECOMMENDATION (OQ-029)                                ║"
  putStrLn "╠══════════════════════════════════════════════════════════╣"
  putStrLn "║                                                          ║"
  putStrLn "║   Use the hand-rolled route trie (Approach A).           ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Integration with the servant-warp spike (OQ-002):      ║"
  putStrLn "║                                                          ║"
  putStrLn "║   The Servant Raw handler currently delegates to an       ║"
  putStrLn "║   IORef (Map String Application) keyed on schema name.   ║"
  putStrLn "║   Replace the Map with a RouteTrie Application:          ║"
  putStrLn "║                                                          ║"
  putStrLn "║     type RouteTable = IORef (RouteTrie Application)      ║"
  putStrLn "║                                                          ║"
  putStrLn "║   On every request the Raw handler:                      ║"
  putStrLn "║     1. Reads the IORef (or TVar for concurrent writes)   ║"
  putStrLn "║     2. Calls routeRequest (pathInfo req) trie            ║"
  putStrLn "║     3. Adds matchParams to request vault/headers         ║"
  putStrLn "║     4. Delegates to matchHandler                         ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Schema changes rebuild the trie and atomically swap    ║"
  putStrLn "║   the IORef — zero request interruption, no locking      ║"
  putStrLn "║   during reads (same pattern as the IORef Map today).    ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Conflict resolution (OQ-028): static segments always   ║"
  putStrLn "║   beat captures at the same depth. Exact-path conflicts  ║"
  putStrLn "║   (two routes with identical segment sequences) are a    ║"
  putStrLn "║   schema validation error at insert time — the trie's    ║"
  putStrLn "║   nodeHandler slot can only hold one handler.            ║"
  putStrLn "║                                                          ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

showUs :: Double -> String
showUs us = fmt ++ "µs/request (" ++ show us ++ ")"
  where
    fmt
      | us < 1    = "0." ++ show (round (us * 10) :: Int)
      | otherwise = show (round us :: Int)
