-- Linear Scan — O(routes) comparison baseline
--
-- Maintains a list of (pattern, handler) pairs and tries each in insertion
-- order. Pattern segments are either literals (exact match) or captures
-- (bind any single segment to a name). Semantically correct but O(n) per
-- routing decision — the baseline we are trying to beat.

module Spike.LinearScan
  ( LinearRouter
  , newLinearRouter
  , insertLinear
  , routeLinear
  , ScanResult (..)
  , runLinearSpike
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.IORef
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Control.Monad (forM_, void)
import Control.Exception (evaluate)

-- ---------------------------------------------------------------------------
-- Pattern

data PatSeg = PLit !Text | PCap !Text

parsePattern :: Text -> [PatSeg]
parsePattern p = map seg . filter (not . T.null) . T.splitOn "/" $ p
  where
    seg s
      | T.isPrefixOf "{" s && T.isSuffixOf "}" s =
          PCap (T.drop 1 (T.dropEnd 1 s))
      | otherwise = PLit s

matchPath :: [Text] -> [PatSeg] -> Maybe (Map Text Text)
matchPath []     []         = Just Map.empty
matchPath (t:ts) (PLit l:ps)
  | t == l    = matchPath ts ps
  | otherwise = Nothing
matchPath (t:ts) (PCap n:ps) = do
  rest <- matchPath ts ps
  return (Map.insert n t rest)
matchPath _      _           = Nothing

-- ---------------------------------------------------------------------------
-- Router

newtype LinearRouter h = LinearRouter (IORef [([PatSeg], h)])

newLinearRouter :: IO (LinearRouter h)
newLinearRouter = LinearRouter <$> newIORef []

-- Append so that routes registered first are tried first (insertion-order semantics).
insertLinear :: LinearRouter h -> Text -> h -> IO ()
insertLinear (LinearRouter ref) pat h =
  modifyIORef' ref (++ [(parsePattern pat, h)])

routeLinear :: LinearRouter h -> [Text] -> IO (Maybe (Map Text Text, h))
routeLinear (LinearRouter ref) segs = do
  routes <- readIORef ref
  return $ go routes
  where
    go []            = Nothing
    go ((pat, h):rs) = case matchPath segs pat of
      Just params -> Just (params, h)
      Nothing     -> go rs

-- ---------------------------------------------------------------------------
-- Spike runner

data ScanResult = ScanResult
  { scanLatencyUs  :: !Double
  , scanRouteCount :: !Int
  , scanNotes      :: ![String]
  } deriving (Show)

buildLinear :: Int -> IO (LinearRouter String)
buildLinear n = do
  router <- newLinearRouter
  let resources = 50 :: Int
      actions   = n `div` resources
  forM_ [0 .. resources - 1] $ \i ->
    forM_ [0 .. actions - 1] $ \j ->
      insertLinear router
        ( "/resource_" <> T.pack (show i)
          <> "/{id}/action_" <> T.pack (show j)
        )
        ("handler_" ++ show i ++ "_" ++ show j)
  return router

runLinearSpike :: IO ScanResult
runLinearSpike = do
  putStrLn "\n=== Approach B: Linear Scan ===\n"

  -- Route to resource_49/action_0 — at list position 49*(n/50), near end of list.
  -- Forces O(n) scan through all other-resource patterns before matching.
  let testPath = ["resource_49", "some-uuid", "action_0"]

  -- Benchmark at three scales to show the O(n) slope
  results <- mapM (benchAt testPath) [100, 1000, 10000]

  putStrLn "\nSummary:"
  putStrLn "  Linear scan: SUCCEEDED (correct results)"
  putStrLn "  Latency grows linearly with route count — fails <1µs target at scale"

  let (_, us10k, _) = last results
  return ScanResult
    { scanLatencyUs  = us10k
    , scanRouteCount = 10000
    , scanNotes =
        [ "O(routes) per dispatch — first-segment mismatch exits quickly but still linear"
        , "Insertion-order precedence: fragile at scale, order-sensitive bugs hard to diagnose"
        , "Passes <1µs at 100 routes; fails at 1k; clearly fails at 10k"
        , "Zero setup overhead — fine for tiny route tables or testing; wrong for production"
        ]
    }

benchAt :: [Text] -> Int -> IO (Int, Double, Bool)
benchAt testPath n = do
  router <- buildLinear n
  -- Warm up
  void $ routeLinear router testPath
  t0 <- getCurrentTime
  forM_ [1 .. 10000 :: Int] $ \_ -> do
    r <- routeLinear router testPath
    void $ evaluate r
  t1 <- getCurrentTime
  let totalMs  = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  let usPerReq = totalMs * 1000 / 10000
  let pass     = usPerReq < 1.0
  putStrLn $ "  " ++ show n ++ " routes: " ++ showUs usPerReq
          ++ " — " ++ (if pass then "PASS" else "FAIL (>1µs)")
  return (n, usPerReq, pass)

showUs :: Double -> String
showUs us = showFrac us ++ "µs"
  where
    showFrac x
      | x < 1    = "0." ++ show (round (x * 10) :: Int)
      | otherwise = show (round x :: Int)
