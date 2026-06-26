-- DataCode Servant + Warp Dynamic Routing Spike
--
-- Answers OQ-002: Can Servant accommodate DataCode's runtime-dynamic schemas?
-- Informs OQ-013: Is Yesod worth evaluating for the data plane?

module Main (main) where

import Spike.WaiDynamic    (WaiResult (..), runWaiSpike)
import Spike.ServantHybrid (ServantResult (..), runServantSpike)

main :: IO ()
main = do
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   DataCode: Servant + Warp Dynamic Schema Spike          ║"
  putStrLn "║   OQ-002: Can Servant serve runtime-dynamic schemas?     ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

  waiResult     <- runWaiSpike
  servantResult <- runServantSpike

  putStrLn "\n╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   SUMMARY                                                ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝\n"

  putStrLn "Approach A — Pure WAI Dynamic Router"
  putStrLn $ "  Success: " ++ show (waiSuccess waiResult)
  putStrLn $ "  Routing latency: " ++ showUs (waiRoutingLatencyUs waiResult)
  putStrLn "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (waiNotes waiResult)

  putStrLn ""
  putStrLn "Approach B — Servant + WAI Hybrid"
  putStrLn $ "  Success: " ++ show (servantSuccess servantResult)
  putStrLn $ "  Routing latency: " ++ showUs (servantRoutingLatencyUs servantResult)
  putStrLn "  Key findings:"
  mapM_ (putStrLn . ("    - " ++)) (servantNotes servantResult)

  putStrLn ""
  putStrLn "Yesod analysis (OQ-013) — architectural, no code required:"
  putStrLn "  - Yesod compiles routes via Template Haskell at build time (same as Servant)"
  putStrLn "  - Dynamic dispatch requires the same WAI-level escape hatch in both"
  putStrLn "  - `yesod-core`'s `waiApp` produces a WAI Application — composable identically"
  putStrLn "  - Yesod adds: session management, auth, HTML form handling, shakespeare templates"
  putStrLn "  - DataCode data plane needs: none of the above"
  putStrLn "  - Yesod would add meaningful value only for the thin-client HTML rendering layer"
  putStrLn "    (OQ-013 already deferred to post-MVP — correct call)"
  putStrLn "  - Verdict: Yesod does NOT improve the answer to OQ-002"

  putStrLn ""
  putStrLn "╔══════════════════════════════════════════════════════════╗"
  putStrLn "║   RECOMMENDATION (OQ-002)                                ║"
  putStrLn "╠══════════════════════════════════════════════════════════╣"
  putStrLn "║                                                          ║"
  putStrLn "║   Use Servant + Warp. Yesod not needed for data plane.   ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Recommended API type:                                  ║"
  putStrLn "║                                                          ║"
  putStrLn "║   type API                                               ║"
  putStrLn "║     =    'health'  :> Get '[PlainText] Text              ║"
  putStrLn "║      :<|> 'schemas' :> Get '[JSON] [SchemaRef]           ║"
  putStrLn "║      :<|> 'schema'  :> Capture 'ns'   String            ║"
  putStrLn "║                    :> Capture 'name'  String            ║"
  putStrLn "║                    :> Raw                                ║"
  putStrLn "║                                                          ║"
  putStrLn "║   The Capture pair routes statically (URL structure is   ║"
  putStrLn "║   fixed in DataCode). Raw hands off to the IORef         ║"
  putStrLn "║   dispatch table populated by the schema daemon.         ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Admin endpoints use Servant's full machinery:          ║"
  putStrLn "║   type-safe clients, servant-swagger docs, etc.          ║"
  putStrLn "║                                                          ║"
  putStrLn "║   Schema handlers close over the GADT DSL registry       ║"
  putStrLn "║   and Dynamic type table from the previous spike.        ║"
  putStrLn "║                                                          ║"
  putStrLn "║   For concurrent schema writes: replace IORef with       ║"
  putStrLn "║   STM TVar — same pattern, safe under concurrent load.   ║"
  putStrLn "╚══════════════════════════════════════════════════════════╝"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs/request (" ++ show us ++ ")"
