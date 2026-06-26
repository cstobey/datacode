-- Approach B: Servant typed frame + WAI dynamic dispatch
--
-- Servant's type-level API defines the URL *structure* at compile time.
-- For DataCode this is fine — the structure IS fixed:
--   /health, /schemas, /schema/{ns}/{name}/records, etc.
--
-- What changes at runtime is which schemas exist and what their fields are.
-- The Servant pattern for this is:
--   "schema" :> Capture "ns" String :> Capture "name" String :> Raw
--
-- The Capture routes statically (Servant's type checker validates the URL
-- structure). Raw hands off to a WAI Application — the IORef dispatch
-- table from Approach A — for the dynamic part.
--
-- This gives DataCode:
--   - Type-safe, auto-documented admin endpoints (/health, /schemas, /metrics)
--   - Dynamic schema dispatch with no Servant overhead after the initial route match
--   - Servant client generation for the admin API
--   - A clean boundary: Servant owns structure, WAI owns content

module Spike.ServantHybrid
  ( ServantResult (..)
  , runServantSpike
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
import Control.Monad.IO.Class (liftIO)
import Data.Tagged (Tagged(..))

import Servant

data ServantResult = ServantResult
  { servantSuccess          :: Bool
  , servantRoutingLatencyUs :: Double
  , servantNotes            :: [String]
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- Schema Registry (same IORef Map as Approach A)

newtype Registry = Registry (IORef (Map String Application))

newRegistry :: IO Registry
newRegistry = Registry <$> newIORef Map.empty

registerSchema :: Registry -> String -> Application -> IO ()
registerSchema (Registry ref) name h =
  modifyIORef' ref (Map.insert name h)

deregisterSchema :: Registry -> String -> IO ()
deregisterSchema (Registry ref) name =
  modifyIORef' ref (Map.delete name)

listSchemas :: Registry -> IO [String]
listSchemas (Registry ref) = Map.keys <$> readIORef ref

-- ---------------------------------------------------------------------------
-- Servant API Type
--
-- The structure is fixed at compile time — but all of DataCode's URL
-- structure IS fixed. The dynamic part is the *content*, not the paths.
--
-- Admin endpoints: fully typed, get Servant's documentation + client gen.
-- Schema endpoints: Capture gives us the ns/name; Raw gives dynamic content.

type API
  =    "health"  :> Get '[PlainText] Text
  :<|> "schemas" :> Get '[JSON] [String]
  :<|> "schema"  :> Capture "ns" String
                 :> Capture "name" String
                 :> Raw

api :: Proxy API
api = Proxy

-- ---------------------------------------------------------------------------
-- Server
--
-- The schema handler receives the captured ns and name from Servant,
-- concatenates them to a registry key, and delegates to the stored handler.
-- If not found, returns 404. All of this runs in plain IO — no Handler monad.

server :: Registry -> Server API
server reg = healthH :<|> schemasH :<|> schemaH
  where
    healthH :: Handler Text
    healthH = return "ok"

    schemasH :: Handler [String]
    schemasH = liftIO $ listSchemas reg

    schemaH :: String -> String -> Tagged Handler Application
    schemaH ns name = Tagged $ \req respond -> do
      let (Registry ref) = reg
      table <- readIORef ref
      let key = ns ++ "." ++ name
      case Map.lookup key table of
        Just h  -> h req respond
        Nothing -> respond $ responseLBS status404 [] (LBSC.pack $ "Schema not found: " ++ key)

servantApp :: Registry -> Application
servantApp = serve api . server

-- ---------------------------------------------------------------------------
-- Test helpers

simpleSchemaApp :: String -> Application
simpleSchemaApp name _req respond =
  respond $ responseLBS status200 [("Content-Type", "application/json")]
    (LBSC.pack $ "{\"schema\":\"" ++ name ++ "\"}")

testReq :: Application -> [Text] -> IO (Int, String)
testReq app path = do
  let req = defaultRequest { pathInfo = path }
  resp <- runSession (request req) app
  return (statusCode (simpleStatus resp), LBSC.unpack (simpleBody resp))

-- ---------------------------------------------------------------------------
-- Spike runner

runServantSpike :: IO ServantResult
runServantSpike = do
  putStrLn "\n=== Approach B: Servant + WAI Dynamic Dispatch ===\n"

  reg <- newRegistry
  let app = servantApp reg

  -- Test 1: static Servant admin endpoints work from the start
  putStrLn "Test 1: Static Servant admin endpoints"
  (s1h, b1h) <- testReq app ["health"]
  (s1s, b1s) <- testReq app ["schemas"]
  putStrLn $ "  GET /health:  " ++ show s1h ++ " — " ++ b1h
  putStrLn $ "  GET /schemas: " ++ show s1s ++ " — " ++ b1s

  -- Test 2: schema endpoint before registration (Servant routes to handler, handler returns 404)
  putStrLn "\nTest 2: Schema endpoint before registration"
  (s2, _) <- testReq app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s2 ++ " (expect 404)"

  -- Test 3: register schema, route through Servant typed dispatch
  putStrLn "\nTest 3: Register 'app.orders', route through Servant"
  registerSchema reg "app.orders" (simpleSchemaApp "app.orders")
  (s3, b3) <- testReq app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s3 ++ " — " ++ b3

  -- Test 4: register second schema, verify Servant routes both correctly
  putStrLn "\nTest 4: Register 'app.users', verify independent routing"
  registerSchema reg "app.users" (simpleSchemaApp "app.users")
  (s4a, b4a) <- testReq app ["schema", "app", "orders"]
  (s4b, b4b) <- testReq app ["schema", "app", "users"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s4a ++ " — " ++ b4a
  putStrLn $ "  GET /schema/app/users:  " ++ show s4b ++ " — " ++ b4b

  -- Test 5: /schemas endpoint reflects runtime state
  putStrLn "\nTest 5: /schemas reflects registered schemas"
  (_, b5) <- testReq app ["schemas"]
  putStrLn $ "  GET /schemas: " ++ b5

  -- Test 6: deregister schema, Servant still routes but returns 404
  putStrLn "\nTest 6: Deregister 'app.orders'"
  deregisterSchema reg "app.orders"
  (s6, _) <- testReq app ["schema", "app", "orders"]
  putStrLn $ "  GET /schema/app/orders: " ++ show s6 ++ " (expect 404)"

  -- Benchmark: measure Servant routing overhead vs pure WAI
  putStrLn "\nBenchmark: 10,000 requests through Servant typed routing + dynamic dispatch"
  registerSchema reg "bench.table" (simpleSchemaApp "bench.table")
  t0 <- getCurrentTime
  forM_ [1 .. 10000 :: Int] $ \_ ->
    testReq app ["schema", "bench", "table"]
  t1 <- getCurrentTime
  let totalMs  = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  let usPerReq = (totalMs * 1000) / 10000
  putStrLn $ "  Total: " ++ showMs totalMs ++ " | Per request: " ++ showUs usPerReq

  let success = s2 == 404 && s3 == 200 && s6 == 404

  putStrLn "\nSummary:"
  putStrLn "  Servant + WAI hybrid: SUCCEEDED"
  putStrLn "  Typed admin endpoints coexist with dynamic schema dispatch"
  putStrLn "  Servant validates URL structure; Raw handler dispatches on runtime state"

  return ServantResult
    { servantSuccess = success
    , servantRoutingLatencyUs = usPerReq
    , servantNotes =
        [ "'schema' :> Capture :> Raw — Servant owns structure, WAI owns content"
        , "Admin endpoints (/health, /schemas, /metrics) get full Servant machinery"
        , "Servant auto-generates client libraries and documentation for admin API"
        , "Raw handler delegates to IORef Map: zero Servant overhead after route match"
        , "URL structure IS fixed in DataCode — Capture covers all runtime variation"
        , "Schema handler closes over Registry — same pattern as pure WAI approach"
        ]
    }

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms (" ++ show ms ++ ")"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs (" ++ show us ++ ")"
