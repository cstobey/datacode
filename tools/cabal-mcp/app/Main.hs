{-# LANGUAGE OverloadedStrings #-}
module Main where

import MCP.Server
import Data.Aeson (Value (..))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.IO (hGetContents')
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import System.Timeout (timeout)
import Control.Exception (SomeException, try)

-- ---------------------------------------------------------------------------
-- Server metadata

serverInfo :: McpServerInfo
serverInfo = McpServerInfo
  { serverName         = "cabal-mcp"
  , serverVersion      = "0.1.0"
  , serverInstructions =
      "Runs cabal commands on Haskell projects. \
      \Paths are relative to the repository root."
  }

-- ---------------------------------------------------------------------------
-- Tool definitions

mkTool :: Text -> Text -> [(Text, Text)] -> [Text] -> ToolDefinition
mkTool name desc props reqs =
  mkToolDefinition name desc $
    schema (SchemaObject [(n, describedSchema d (SchemaString Nothing)) | (n, d) <- props] reqs)

toolDefs :: ToolListHandler
toolDefs _ctx = pure
  [ mkTool "cabal_build" "Build a Haskell cabal project"
      [ ("directory",  "Project directory relative to repo root (e.g. spikes/dynamic-loading)")
      , ("target",     "Cabal target to build (optional, builds all if omitted)")
      , ("extra_args", "Extra cabal flags, space-separated (e.g. --enable-tests)")
      ]
      []
  , mkTool "cabal_test" "Run cabal tests for a project"
      [ ("directory",  "Project directory relative to repo root")
      , ("target",     "Test suite target (optional, runs all if omitted)")
      , ("extra_args", "Extra cabal flags, space-separated")
      ]
      []
  , mkTool "cabal_run" "Run a cabal executable (30-second timeout)"
      [ ("directory",  "Project directory relative to repo root")
      , ("target",     "Executable target name (required)")
      , ("args",       "Arguments to pass to the executable, space-separated")
      , ("extra_args", "Extra cabal flags, space-separated")
      ]
      ["target"]
  , mkTool "cabal_check" "Validate a cabal file with cabal check"
      [ ("directory", "Project directory relative to repo root")
      ]
      []
  ]

-- ---------------------------------------------------------------------------
-- Argument helpers

-- | Every declared property is a string, so anything else is treated as absent.
getArg :: Text -> Map Text Value -> String
getArg k kvs = case Map.lookup k kvs of
  Just (String t) -> T.unpack t
  _               -> ""

getWords :: Text -> Map Text Value -> [String]
getWords k kvs = map T.unpack . T.words . T.pack $ getArg k kvs

-- ---------------------------------------------------------------------------
-- Tool dispatch

callTool :: ToolCallHandler
callTool _ctx toolName args = case toolName of
  "cabal_build" -> run dir $ ["build"] ++ extraArgs ++ target
  "cabal_test"  -> run dir $ ["test"]  ++ extraArgs ++ target
  "cabal_run"
    | null target -> pure $ Left (MissingRequiredParams "target")
    | otherwise   -> runTimed 30 dir $ ["run"] ++ extraArgs ++ target ++ ["--"] ++ runArgs
  "cabal_check" -> run dir ["check"]
  _             -> pure $ Left (UnknownTool toolName)
  where
    dir       = let d = getArg "directory" args in if null d then "." else d
    target    = let t = getArg "target" args    in if null t then [] else [t]
    extraArgs = getWords "extra_args" args
    runArgs   = getWords "args" args

-- ---------------------------------------------------------------------------
-- Process execution

run :: FilePath -> [String] -> IO (Either Error ToolResult)
run dir cabalArgs = do
  result <- try (runInDir dir "cabal" cabalArgs) :: IO (Either SomeException (ExitCode, String, String))
  case result of
    Left ex                  -> pure $ Left  $ InternalError (T.pack (show ex))
    Right (ExitSuccess, o, _) -> pure $ Right $ text $ if null o then "(success)" else o
    Right (ExitFailure n, o, e) ->
      pure $ Right $ text $
        "cabal exited " <> show n <> "\n" <> e <> o
  where
    text = toolResult . pure . ContentText . T.pack

runTimed :: Int -> FilePath -> [String] -> IO (Either Error ToolResult)
runTimed secs dir cabalArgs = do
  result <- timeout (secs * 1_000_000) (run dir cabalArgs)
  case result of
    Nothing -> pure $ Left $ InternalError "Timed out"
    Just r  -> pure r

runInDir :: FilePath -> String -> [String] -> IO (ExitCode, String, String)
runInDir dir exe cmdArgs = do
  let pspec = (proc exe cmdArgs)
        { cwd     = Just dir
        , std_out = CreatePipe
        , std_err = CreatePipe
        , std_in  = NoStream
        }
  (_, Just hOut, Just hErr, ph) <- createProcess pspec
  out  <- hGetContents' hOut
  err  <- hGetContents' hErr
  code <- waitForProcess ph
  pure (code, out, err)

-- ---------------------------------------------------------------------------
-- Entry point

main :: IO ()
main = runMcpServerStdio serverInfo noHandlers
  { tools = Just (toolDefs, callTool)
  }
