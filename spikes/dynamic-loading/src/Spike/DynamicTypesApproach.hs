-- Approach 3: Data.Dynamic + Data.Typeable
--
-- Uses Haskell's built-in runtime type representation to carry schema types
-- as Dynamic values. Functors are stored as (Dynamic -> Either ValidationError Dynamic),
-- checked for type compatibility at runtime using Typeable.
--
-- This is the middle ground: more expressive than the DSL (can use any Haskell function)
-- but constrained to pre-registered types (no arbitrary eval). Think of it as
-- a plugin system where functor implementations are compiled into DataCode but
-- their wiring to schema fields is dynamic.

{-# LANGUAGE ScopedTypeVariables #-}

module Spike.DynamicTypesApproach
  ( DynResult (..)
  , runDynSpike
  , SchemaRegistry
  , registerType
  , registerFunctor
  , applyDynFunctor
  , DynFunctor (..)
  , DynSchema (..)
  , FunctorKind (..)
  ) where

import Data.Dynamic
import Data.Typeable
import Data.Time.Clock (getCurrentTime, diffUTCTime)

-- ---------------------------------------------------------------------------
-- Runtime Schema Registry
--
-- The schema registry maps type names to their Typeable representation and
-- associated functors. This is what lives in memory when DataCode loads a schema.

data DynFunctor = DynFunctor
  { dfName       :: String
  , dfTargetType :: TypeRep       -- what type this functor operates on
  , dfKind       :: FunctorKind
  , dfFn         :: Dynamic -> Either String Dynamic
    -- ^ takes a Dynamic wrapping the target type, returns Right of same type
    --   or Left with an error message. The Dynamic wrapper means we carry
    --   type info but lose compile-time checking.
  }

data FunctorKind
  = Validation
  | ForeignKey  { fkTable :: String, fkField :: String }
  | PathEquiv   { pePath1 :: [String], pePath2 :: [String] }
  | AccessCtrl
  deriving (Show, Eq)

instance Show DynFunctor where
  show df = "DynFunctor{" ++ dfName df ++ " :: " ++ show (dfTargetType df) ++ "}"

data DynSchema = DynSchema
  { dsName     :: String
  , dsFields   :: [(String, TypeRep)]   -- field name -> runtime type
  , dsFunctors :: [DynFunctor]
  } deriving (Show)

type SchemaRegistry = [(String, DynSchema)]

-- ---------------------------------------------------------------------------
-- Registry Operations

registerType :: String -> [(String, TypeRep)] -> [DynFunctor] -> DynSchema
registerType name fields functors = DynSchema name fields functors

registerFunctor
  :: forall a. Typeable a
  => String
  -> FunctorKind
  -> (a -> Either String a)   -- typed function; we wrap it into Dynamic
  -> DynFunctor
registerFunctor name kind fn = DynFunctor
  { dfName       = name
  , dfTargetType = typeOf (undefined :: a)
  , dfKind       = kind
  , dfFn         = \dyn ->
      case fromDynamic dyn of
        Nothing  -> Left $ "Type mismatch: expected " ++ show (typeOf (undefined :: a))
                        ++ " got " ++ show (dynTypeRep dyn)
        Just val -> case fn val of
          Left err  -> Left err
          Right val' -> Right (toDyn val')
  }

applyDynFunctor :: DynFunctor -> Dynamic -> Either String Dynamic
applyDynFunctor = dfFn

applyAllFunctors :: [DynFunctor] -> Dynamic -> Either String Dynamic
applyAllFunctors [] dyn = Right dyn
applyAllFunctors (f:fs) dyn = do
  dyn' <- applyDynFunctor f dyn
  applyAllFunctors fs dyn'

-- ---------------------------------------------------------------------------
-- Example Domain Types
-- These represent types that DataCode has pre-compiled in — the "built-in"
-- type library. User-defined types would require the dynamic loading mechanism
-- from Approach 1 to add new entries here at runtime.

newtype Amount = Amount Int deriving (Show, Eq, Typeable)
newtype Email  = Email  String deriving (Show, Eq, Typeable)
newtype UserId = UserId String deriving (Show, Eq, Typeable)

data CustomerStatus = Active | Suspended | Closed deriving (Show, Eq, Typeable)

data Order = Order
  { orderId         :: String
  , orderUserId     :: String
  , orderAmount     :: Int
  , orderStatus     :: String
  } deriving (Show, Eq, Typeable)

-- ---------------------------------------------------------------------------
-- Example Functors (compiled-in implementations, dynamically wired to schema)

validatePositiveAmount :: Amount -> Either String Amount
validatePositiveAmount a@(Amount n)
  | n > 0    = Right a
  | otherwise = Left $ "Amount must be positive, got: " ++ show n

validateEmailFormat :: Email -> Either String Email
validateEmailFormat e@(Email s)
  | '@' `elem` s && '.' `elem` dropWhile (/= '@') s = Right e
  | otherwise = Left $ "Invalid email format: " ++ s

validateUserId :: UserId -> Either String UserId
validateUserId u@(UserId s)
  | length s == 36 = Right u   -- simplified UUID check
  | otherwise = Left $ "UserId must be UUID format, got length " ++ show (length s)

-- Simulates a foreign key check by verifying the ID matches a known set
-- In a real system this would query the target shard.
mockForeignKeyCheck :: UserId -> Either String UserId
mockForeignKeyCheck u@(UserId uid)
  | uid `elem` knownUsers = Right u
  | otherwise = Left $ "User not found: " ++ uid
  where
    knownUsers = ["550e8400-e29b-41d4-a716-446655440000", "6ba7b810-9dad-11d1-80b4-00c04fd430c8"]

-- ---------------------------------------------------------------------------
-- Spike: build a schema registry at runtime, apply functors

data DynResult = DynResult
  { dynApproach       :: String
  , dynLoadLatencyMs  :: Double
  , dynApplyLatencyMs :: Double
  , dynSuccess        :: Bool
  , dynNotes          :: [String]
  } deriving (Show)

runDynSpike :: IO DynResult
runDynSpike = do
  putStrLn "\n=== Approach 3: Data.Dynamic + Typeable ===\n"

  -- Test 1: Build a schema registry at runtime
  putStrLn "Test 1: Build a dynamic schema registry"
  (buildTime, _) <- timed $ do
    let amountFunctor = registerFunctor "PositiveAmount" Validation validatePositiveAmount
    let fkFunctor     = registerFunctor "UserFK"
                          (ForeignKey "User" "id")
                          mockForeignKeyCheck

    let orderSchema = registerType "Order"
          [ ("user_id", typeOf (undefined :: UserId))
          , ("amount",  typeOf (undefined :: Amount))
          ]
          [amountFunctor, fkFunctor]

    return [(dfName amountFunctor, orderSchema)]

  putStrLn $ "  Registry built in: " ++ showMs buildTime

  -- Test 2: Apply validation functors to typed values
  putStrLn "\nTest 2: Apply validation functors via Dynamic"
  let amountFunctor = registerFunctor "PositiveAmount" Validation validatePositiveAmount
  (applyTime, results2) <- timed $ do
    let testValues = [Amount 42, Amount (-5), Amount 0, Amount 1000]
    return $ map (\v -> (v, applyDynFunctor amountFunctor (toDyn v))) testValues
  mapM_ (\(v, r) ->
    putStrLn $ "  " ++ show v ++ " => " ++ show (fmap dynTypeRep r)
              ++ " | " ++ either ("ERROR: "++) show r
    ) results2

  -- Test 3: Type mismatch detection
  putStrLn "\nTest 3: Type mismatch detection"
  let emailFunctor = registerFunctor "EmailFormat" Validation validateEmailFormat
  let wrongType = toDyn (Amount 42)   -- passing Amount to an Email functor
  let mismatchResult = applyDynFunctor emailFunctor wrongType
  putStrLn $ "  Applying Email functor to Amount value: " ++ show mismatchResult

  -- Test 4: Functor chain (compose multiple functors over one value)
  putStrLn "\nTest 4: Functor chain — multiple validators on one value"
  let userIdFunctor = registerFunctor "ValidUserId" Validation validateUserId
  let fkFunctor     = registerFunctor "UserFK" (ForeignKey "User" "id") mockForeignKeyCheck
  let chain = [userIdFunctor, fkFunctor]

  let goodId = toDyn (UserId "550e8400-e29b-41d4-a716-446655440000")
  let badFmt = toDyn (UserId "not-uuid")
  let goodFmtBadFK = toDyn (UserId "00000000-0000-0000-0000-000000000000")

  (chainTime, _) <- timed $ do
    let r1 = applyAllFunctors chain goodId
    let r2 = applyAllFunctors chain badFmt
    let r3 = applyAllFunctors chain goodFmtBadFK
    putStrLn $ "  Known good ID:       " ++ showResult r1
    putStrLn $ "  Bad format ID:       " ++ showResult r2
    putStrLn $ "  Valid format, bad FK: " ++ showResult r3
    return ()
  putStrLn $ "  Chain time: " ++ showMs chainTime

  -- Test 5: Demonstrate the ceiling — user-defined types
  putStrLn "\nTest 5: Ceiling — adding a new user-defined type at runtime"
  putStrLn "  In this approach, new types (like a PhoneNumber) must be:"
  putStrLn "  a) Pre-compiled into DataCode (using Dynamic wiring only)"
  putStrLn "  b) OR loaded via hint/GHC dynamic linking (Approach 1 / 4)"
  putStrLn "  The Dynamic approach alone cannot create new Haskell types at runtime."
  putStrLn "  It CAN dynamically wire existing types to schema fields."

  -- Test 6: TypeRep comparison — simulates schema type checking
  putStrLn "\nTest 6: TypeRep-based schema type checking"
  let schemaField = typeOf (undefined :: Amount)
  let incomingVal1 = toDyn (Amount 5)
  let incomingVal2 = toDyn (Email "x@y.com")
  putStrLn $ "  Schema expects: " ++ show schemaField
  putStrLn $ "  Amount value matches: " ++ show (dynTypeRep incomingVal1 == schemaField)
  putStrLn $ "  Email value matches:  " ++ show (dynTypeRep incomingVal2 == schemaField)

  putStrLn "\nSummary:"
  putStrLn "  Dynamic/Typeable approach SUCCEEDED for pre-compiled types"
  putStrLn "  Type mismatches caught at runtime via TypeRep comparison"
  putStrLn "  Cannot create new Haskell types at runtime — ceiling is pre-compiled type library"

  return $ DynResult "Data.Dynamic + Typeable" buildTime applyTime True
    [ "No GHC dependency at runtime for applying functors"
    , "New types require pre-compilation into DataCode — not fully open to schema authors"
    , "Excellent performance: type checking via TypeRep is O(1)"
    , "Type safety is runtime-checked only — no compile-time guarantee across dynamic boundaries"
    , "Best combined with hint/GHC dynamic linking for user-defined types"
    , "Works well as the implementation substrate for the DSL approach"
    , "Could serve as the 'registered type library' that the DSL references by name"
    ]

showResult :: Either String Dynamic -> String
showResult (Left err) = "ERROR: " ++ err
showResult (Right dyn) = "OK: " ++ show (dynTypeRep dyn)

timed :: IO a -> IO (Double, a)
timed action = do
  t0 <- getCurrentTime
  result <- action
  t1 <- getCurrentTime
  let ms = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  return (ms, result)

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms (" ++ show ms ++ ")"
