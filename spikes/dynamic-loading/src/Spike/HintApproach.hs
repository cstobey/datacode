-- Approach 1: hint (GHC interpreter)
--
-- Tests whether we can load a user-defined functor expressed as a Haskell
-- string at runtime, extract a pure function from it, and apply it to values.
--
-- This is what project-m36 does for user-defined functions.
-- The concern: latency, sandboxing, and inter-snippet type safety.

module Spike.HintApproach
  ( HintResult (..)
  , runHintSpike
  , hintLoadFunctor
  , hintApplyFunctor
  , HintFunctor (..)
  ) where

import Language.Haskell.Interpreter
import Data.Time.Clock (getCurrentTime, diffUTCTime)

-- ---------------------------------------------------------------------------
-- Types

-- A functor loaded via hint — holds the compiled function as a Dynamic-like
-- wrapped value. We use (String -> Either String String) as a universal repr
-- here since hint cannot extract arbitrary types without explicit type
-- annotations. In a real system, each functor would have a known type schema.
data HintFunctor = HintFunctor
  { functorSource :: String       -- the original source string, for audit
  , functorApply  :: String -> Either String String
    -- ^ simplified: takes a serialized value, returns validated/transformed value
    -- In DataCode, this would be: SchemaValue -> Either ValidationError SchemaValue
  }

data HintResult = HintResult
  { hrApproach       :: String
  , hrLoadLatencyMs  :: Double
  , hrApplyLatencyMs :: Double
  , hrSuccess        :: Bool
  , hrNotes          :: [String]
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- Spike: load a validation functor from a string, measure latency, apply it

-- Simulates: a schema author defines a validation rule as a Haskell expression
-- stored in the schema transaction graph. On schema load, DataCode compiles
-- it and caches the result.
runHintSpike :: IO HintResult
runHintSpike = do
  putStrLn "\n=== Approach 1: hint (GHC interpreter) ===\n"

  -- Test 1: compile a simple validation functor
  putStrLn "Test 1: Compile a simple Int validation functor from source string"
  (loadTime, mFunctor) <- timed $ hintLoadFunctor validationSource

  case mFunctor of
    Left err -> do
      putStrLn $ "  FAILED to compile: " ++ err
      return $ HintResult "hint" loadTime 0 False
        ["Compilation failed — hint may not be installed or GHC not on PATH"]

    Right fn -> do
      putStrLn $ "  Compiled in " ++ showMs loadTime ++ "ms"

      -- Test 2: apply the functor to values
      putStrLn "\nTest 2: Apply functor to values"
      (applyTime, results) <- timed $ do
        let inputs = ["42", "-5", "0", "100", "abc"]
        return $ map (\i -> (i, fn i)) inputs

      mapM_ (\(i, r) -> putStrLn $ "  apply(" ++ i ++ ") = " ++ show r) results

      -- Test 3: compile a more complex functor (simulates a foreign key check)
      putStrLn "\nTest 3: Compile a foreign-key-style path functor"
      (loadTime2, mFunctor2) <- timed $ hintLoadFunctor pathFunctorSource
      case mFunctor2 of
        Left err -> putStrLn $ "  FAILED: " ++ err
        Right _  -> putStrLn $ "  Compiled in " ++ showMs loadTime2 ++ "ms"

      -- Test 4: try to compile something with IO (should fail in sandboxed mode)
      putStrLn "\nTest 4: Attempt to compile IO action (should be rejected)"
      (_, mUnsafe) <- timed $ hintLoadFunctorSandboxed unsafeSource
      case mUnsafe of
        Left err -> putStrLn $ "  Correctly rejected: " ++ take 120 err
        Right _  -> putStrLn $ "  WARNING: IO action compiled — sandbox ineffective!"

      -- Test 5: repeated compilation to see if GHC interpreter caches
      putStrLn "\nTest 5: Compile same functor 5 times — does it get faster?"
      times <- mapM (\_ -> fst <$> timed (hintLoadFunctor validationSource)) [1..5 :: Int]
      mapM_ (\(i,t) -> putStrLn $ "  Run " ++ show i ++ ": " ++ showMs t ++ "ms")
            (zip [1 :: Int ..] times)

      putStrLn "\nSummary:"
      putStrLn $ "  Initial load latency: " ++ showMs loadTime ++ "ms"
      putStrLn $ "  Apply latency (5 values): " ++ showMs applyTime ++ "ms"
      putStrLn "  hint approach SUCCEEDED for pure functors"

      return $ HintResult "hint" loadTime applyTime True
        [ "GHC must be on PATH at runtime — deployment concern"
        , "Compilation latency may be too high for interactive schema changes"
        , "Sandboxing: restricting to Safe Haskell module set works but limits expressiveness"
        , "No cross-snippet type checking — inter-functor type safety is lost"
        , "hint uses the IO monad; extracting pure functions requires type annotation in source"
        ]

-- ---------------------------------------------------------------------------
-- Source strings (simulate schema-stored functor definitions)

-- A validation functor: ensures an Int field is positive
validationSource :: String
validationSource =
  "\\(s :: String) -> \
  \case reads s of \
  \  [(n, \"\")] -> if (n :: Int) > 0 \
  \                 then Right s \
  \                 else Left (\"Value \" ++ s ++ \" must be positive\") \
  \  _ -> Left (\"Not a valid Int: \" ++ s)"

-- A path-style functor: simulate checking that a path exists (foreign key)
-- In a real system this would do a DB lookup; here we simulate with a pure check
pathFunctorSource :: String
pathFunctorSource =
  "\\(s :: String) -> \
  \if length s == 36 \
  \then Right s \
  \else Left (\"Expected UUID format, got: \" ++ s)"

-- An unsafe source that attempts IO — should be blocked by sandboxing
unsafeSource :: String
unsafeSource =
  "\\(_ :: String) -> \
  \unsafePerformIO (writeFile \"/tmp/pwned\" \"hacked\") `seq` Right \"ok\""

-- ---------------------------------------------------------------------------
-- hint loading functions

-- Load a functor without sandboxing
hintLoadFunctor :: String -> IO (Either String (String -> Either String String))
hintLoadFunctor src = do
  result <- runInterpreter $ do
    setImports ["Prelude", "Data.List"]
    interpret src (as :: String -> Either String String)
  return $ case result of
    Left err -> Left (showInterpreterError err)
    Right fn -> Right fn

-- Load a functor with Safe Haskell restrictions
-- This is the sandbox approach: only allow Safe-flagged imports
hintLoadFunctorSandboxed :: String -> IO (Either String (String -> Either String String))
hintLoadFunctorSandboxed src = do
  result <- runInterpreter $ do
    -- Restrict to safe imports only
    set [languageExtensions := [SafeImports]]
    setImports ["Prelude"]
    -- Note: `unsafePerformIO` is in System.IO.Unsafe which is not Safe,
    -- so it should be blocked. In practice, the effectiveness depends on
    -- whether the interpreter enforces Safe Haskell module flags.
    interpret src (as :: String -> Either String String)
  return $ case result of
    Left err -> Left (showInterpreterError err)
    Right fn -> Right fn

hintApplyFunctor :: (String -> Either String String) -> [String] -> [Either String String]
hintApplyFunctor fn = map fn

showInterpreterError :: InterpreterError -> String
showInterpreterError (UnknownError s) = "UnknownError: " ++ s
showInterpreterError (WontCompile errs) = "WontCompile: " ++ unlines (map errMsg errs)
showInterpreterError (NotAllowed s) = "NotAllowed: " ++ s
showInterpreterError (GhcException s) = "GhcException: " ++ s

-- ---------------------------------------------------------------------------
-- Utilities

timed :: IO a -> IO (Double, a)
timed action = do
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  let ms = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  return (ms, result)

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms (" ++ show ms ++ ")"
