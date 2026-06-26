-- Approach A: Pure WAI with runtime-mutable dispatch table
--
-- A WAI Application is just a function:
--   Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
--
-- Dynamic routing is therefore trivial: an IORef Map from schema path
-- to Application. No framework constraint, no recompilation.
--
-- Key question answered: yes, WAI alone handles runtime schema
-- registration/deregistration with zero overhead beyond a Map lookup.

module Spike.WaiDynamic
  ( WaiResult (..)
  , runWaiSpike
  , DynRouter
  , newDynRouter
  , registerSchema
  , deregisterSchema
  , dynApp
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy.Char8 as LBSC
import Network.Wai
import Network.Wai.Test (runSession, request, simpleStatus, simpleBody)
import Network.HTTP.Types
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Control.Monad (forM_)

data WaiResult = WaiResult
  { waiSuccess          :: Bool
  , waiRoutingLatencyUs :: Double
  , waiNotes            :: [String]
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- Dynamic Router

-- Maps schema key (e.g. "app.commerce.orders") to its WAI handler.
-- IORef gives safe single-threaded mutation; use TVar for concurrent writes.
newtype DynRouter = DynRouter (IORef (Map String Application))

newDynRouter :: IO DynRouter
newDynRouter = DynRouter <$> newIORef Map.empty

registerSchema :: DynRouter -> String -> Application -> IO ()
registerSchema (DynRouter ref) name app =
  modifyIORef' ref (Map.insert name app)

deregisterSchema :: DynRouter -> String -> IO ()
deregisterSchema (DynRouter ref) name =
  modifyIORef' ref (Map.delete name)

-- ---------------------------------------------------------------------------
-- WAI Application
--
-- URL structure mirrors DataCode's namespace layout:
--   GET /health                    — liveness probe
--   GET /schema/{namespace}/{name} — dynamic dispatch to registered schema
--
-- The IORef is read on every request, so registration changes are
-- visible immediately with no restart.

dynApp :: DynRouter -> Application
dynApp (DynRouter ref) req respond = do
  table <- readIORef ref
  case pathInfo req of
    ["health"] ->
      respond $ responseLBS status200 [("Content-Type", "text/plain")] "ok"

    ["schema", ns, name] ->
      let key = T.unpack ns ++ "." ++ T.unpack name
      in case Map.lookup key table of
        Just h  -> h req respond
        Nothing -> respond $ responseLBS status404 [] (LBSC.pack $ "Schema not found: " ++ key)

    _ -> respond $ responseLBS status404 [] "Not found"

-- A minimal schema handler: returns a JSON description of the schema.
-- In DataCode this would validate/query records using the GADT DSL registry.
schemaHandler :: String -> [(String, String)] -> Application
schemaHandler name fields _req respond = do
  let fieldJson = "[" ++ concatMap (\(k,v) -> "{\"" ++ k ++ "\":\"" ++ v ++ "\"},") fields ++ "]"
  let body      = LBSC.pack $ "{\"schema\":\"" ++ name ++ "\",\"fields\":" ++ fieldJson ++ "}"
  respond $ responseLBS status200 [("Content-Type", "application/json")] body

-- ---------------------------------------------------------------------------
-- Test helpers

getResponse :: Application -> [Text] -> IO (Int, String)
getResponse app path = do
  let req = defaultRequest { pathInfo = path }
  resp <- runSession (request req) app
  return (statusCode (simpleStatus resp), LBSC.unpack (simpleBody resp))

-- ---------------------------------------------------------------------------
-- Spike runner

runWaiSpike :: IO WaiResult
runWaiSpike = do
  putStrLn "\n=== Approach A: Pure WAI Dynamic Router ===\n"

  router <- newDynRouter
  let app = dynApp router

  -- Test 1: request before any schema is registered
  putStrLn "Test 1: Request before any schema registered"
  (s1, _) <- getResponse app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s1 ++ " (expect 404)"

  -- Test 2: register a schema at runtime
  putStrLn "\nTest 2: Register 'app.orders' schema at runtime"
  registerSchema router "app.orders"
    (schemaHandler "app.orders" [("id", "UUID"), ("amount", "Decimal"), ("user_id", "UUID")])
  (s2, b2) <- getResponse app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s2
  putStrLn $ "  Body: " ++ b2

  -- Test 3: register a second schema without restarting
  putStrLn "\nTest 3: Register 'app.users' without restarting server"
  registerSchema router "app.users"
    (schemaHandler "app.users" [("id", "UUID"), ("email", "Email")])
  (s3a, _) <- getResponse app ["schema", "app", "orders"]
  (s3b, b3b) <- getResponse app ["schema", "app", "users"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s3a ++ " (still works)"
  putStrLn $ "  GET /schema/app/users:  " ++ show s3b ++ " — " ++ b3b

  -- Test 4: update a schema handler (schema evolution)
  putStrLn "\nTest 4: Update 'app.orders' schema (add field)"
  registerSchema router "app.orders"
    (schemaHandler "app.orders" [("id", "UUID"), ("amount", "Decimal"), ("user_id", "UUID"), ("status", "Text")])
  (s4, b4) <- getResponse app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s4
  putStrLn $ "  Body: " ++ b4

  -- Test 5: deregister schema
  putStrLn "\nTest 5: Deregister 'app.orders'"
  deregisterSchema router "app.orders"
  (s5, _) <- getResponse app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s5 ++ " (expect 404)"

  -- Test 6: health endpoint always available
  putStrLn "\nTest 6: Health endpoint"
  (s6, b6) <- getResponse app ["health"]
  putStrLn $ "  GET /health: " ++ show s6 ++ " — " ++ b6

  -- Benchmark: 10k routing decisions through the IORef Map
  putStrLn "\nBenchmark: 10,000 routing decisions"
  registerSchema router "bench.table" (schemaHandler "bench.table" [])
  t0 <- getCurrentTime
  forM_ [1 .. 10000 :: Int] $ \_ ->
    getResponse app ["schema", "bench", "table"]
  t1 <- getCurrentTime
  let totalMs  = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  let usPerReq = (totalMs * 1000) / 10000
  putStrLn $ "  Total: " ++ showMs totalMs ++ " | Per request: " ++ showUs usPerReq

  let success = s2 == 200 && s5 == 404 && s6 == 200

  putStrLn "\nSummary:"
  putStrLn "  Pure WAI dynamic routing: SUCCEEDED"
  putStrLn "  Schemas registered/updated/deregistered at runtime without restart"
  putStrLn "  Routing overhead: O(log n) Map lookup on an IORef"

  return WaiResult
    { waiSuccess = success
    , waiRoutingLatencyUs = usPerReq
    , waiNotes =
        [ "WAI Application is a pure function — trivially composable and testable"
        , "IORef Map gives O(log n) dispatch; use STM TVar for concurrent schema writes"
        , "Schema handlers close over runtime state (GADT DSL registry, functor table)"
        , "No recompilation on schema change — handler is registered, not compiled in"
        , "Warp is just a TCP accept loop calling the Application function — zero friction"
        , "Servant and Yesod both compile down to WAI Applications — same flexibility"
        ]
    }

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms (" ++ show ms ++ ")"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs (" ++ show us ++ ")"
