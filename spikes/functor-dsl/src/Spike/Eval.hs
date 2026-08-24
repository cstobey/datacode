-- | The interpreter, the store it reads, and the regex primitive.
--
-- Note what is NOT in the error channel: there is no @"type mismatch"@ case
-- anywhere below. Every constructor's operands are already the right type by
-- construction, so the only failures left are data failures — a row that is
-- not there, a Configuration row that is missing, a pattern that a
-- Configuration row supplied and that does not compile.
module Spike.Eval where

import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Spike.Core

-- ---------------------------------------------------------------------------
-- Store

data Store = Store
  { stTables   :: IORef (Map Text (Map Text Row))   -- ^ table -> row key -> row
  , stConfig   :: IORef (Map Text (Text, Int))      -- ^ path -> (value, row version)
  , stRefs     :: Map Text Text                     -- ^ Reference path -> interned value
  , stTrigger  :: IORef (Map (Text, Text) Bool)     -- ^ system.events.TriggerState
  , stPatCache :: IORef (Map (Text, Int) Regex)     -- ^ keyed on the config row version
  , stQueue    :: IORef [EventRef]
  , stEdges    :: [Edge]
  , stCounters :: IORef (Map Text Int)              -- ^ `next` allocation, per unique constraint
  , stFns      :: Map Text SomeFn                   -- ^ terms a function-typed column may name
  , stStats    :: IORef Stats
  }

data Stats = Stats
  { stDerefs   :: !Int
  , stPatMiss  :: !Int
  , stPatHit   :: !Int
  } deriving (Eq, Show)

newStore :: [Edge] -> Map Text (Map Text Row) -> Map Text (Text, Int) -> Map Text Text
         -> Map Text SomeFn -> IO Store
newStore edges tabs cfg refs fns = Store
  <$> newIORef tabs <*> newIORef cfg <*> pure refs
  <*> newIORef M.empty <*> newIORef M.empty <*> newIORef []
  <*> pure edges <*> newIORef M.empty <*> pure fns <*> newIORef (Stats 0 0 0)

data Err
  = ERowNotFound Text Text      -- ^ table, key
  | ECellMissing Text Text      -- ^ table, field
  | ECellType Text Text String  -- ^ table, field, expected
  | EConfigMissing Text
  | EBadPattern Text Text       -- ^ source, pattern
  | EViolation Text Text        -- ^ functor name, message
  | EAccessDenied Text
  | EFnMissing Text
  | EFnSig Text Text Text       -- ^ name, declared signature, stored signature
  deriving (Eq)

instance Show Err where
  show = \case
    ERowNotFound t k   -> "row not found: " ++ T.unpack t ++ "/" ++ T.unpack k
    ECellMissing t f   -> "no field " ++ T.unpack t ++ "." ++ T.unpack f
    ECellType t f e    -> "stored cell for " ++ T.unpack t ++ "." ++ T.unpack f
                          ++ " is not " ++ e
    EConfigMissing p   -> "no Configuration row at " ++ T.unpack p
    EBadPattern s p    -> "malformed pattern from " ++ T.unpack s ++ ": " ++ T.unpack p
    EViolation n m     -> T.unpack n ++ ": " ++ T.unpack m
    EAccessDenied n    -> "Redacted (" ++ T.unpack n ++ ")"
    EFnMissing n       -> "no term registered for function column value " ++ T.unpack n
    EFnSig n d s       -> T.unpack n ++ ": declared " ++ T.unpack d
                          ++ ", stored " ++ T.unpack s

newtype Ev a = Ev { runEv :: Store -> IO (Either Err a) }

instance Functor Ev where
  fmap f (Ev g) = Ev $ \s -> fmap (fmap f) (g s)
instance Applicative Ev where
  pure x = Ev $ \_ -> pure (Right x)
  Ev f <*> Ev x = Ev $ \s -> f s >>= \case
    Left e   -> pure (Left e)
    Right f' -> fmap (fmap f') (x s)
instance Monad Ev where
  Ev x >>= k = Ev $ \s -> x s >>= \case
    Left e   -> pure (Left e)
    Right a  -> runEv (k a) s

evStore :: Ev Store
evStore = Ev $ \s -> pure (Right s)

evFail :: Err -> Ev a
evFail e = Ev $ \_ -> pure (Left e)

evIO :: IO a -> Ev a
evIO act = Ev $ \_ -> Right <$> act

bumpStat :: (Stats -> Stats) -> Ev ()
bumpStat f = do
  s <- evStore
  evIO $ modifyIORef' (stStats s) f

-- ---------------------------------------------------------------------------
-- Regex
--
-- A stand-in engine. The production decision is Text.Regex.TDFA; this sandbox
-- cannot install it (see output.txt), so what is validated here is the shape of
-- the primitive — provenance in the type, a version-keyed compiled-pattern
-- cache, and a malformed pattern failing at the point its provenance implies —
-- and not the engine.

data RNode
  = RPred (Char -> Bool)
  | RSeq [RNode]
  | RAlt [RNode]
  | RStar RNode
  | RPlus RNode
  | ROpt RNode

data Regex = Regex { reStart :: Bool, reEnd :: Bool, reNode :: RNode }

compileRegex :: Text -> Maybe Regex
compileRegex src = case T.unpack src of
  ('^':rest) -> build True rest
  s          -> build False s
  where
    build anchS s =
      let (body, anchE) = case reverse s of
                            ('$':r) -> (reverse r, True)
                            _       -> (s, False)
      in case parseAlt body of
           Just (n, "") -> Just (Regex anchS anchE n)
           _            -> Nothing

parseAlt :: String -> Maybe (RNode, String)
parseAlt s = do
  (first, rest) <- parseSeq s
  go [first] rest
  where
    go acc ('|':r) = do (n, r') <- parseSeq r; go (n:acc) r'
    go [one] r     = Just (one, r)
    go acc r       = Just (RAlt (reverse acc), r)

parseSeq :: String -> Maybe (RNode, String)
parseSeq = go []
  where
    go acc s@(c:_) | c == '|' || c == ')' = Just (RSeq (reverse acc), s)
    go acc []                            = Just (RSeq (reverse acc), [])
    go acc s = do
      (atom, r) <- parseAtom s
      case r of
        ('*':r') -> go (RStar atom : acc) r'
        ('+':r') -> go (RPlus atom : acc) r'
        ('?':r') -> go (ROpt  atom : acc) r'
        _        -> go (atom : acc) r

parseAtom :: String -> Maybe (RNode, String)
parseAtom = \case
  '.':r          -> Just (RPred (const True), r)
  '(':r          -> do (n, r') <- parseAlt r
                       case r' of { ')':r'' -> Just (n, r''); _ -> Nothing }
  '[':r          -> parseClass r
  '\\':e:r       -> Just (RPred (escClass e), r)
  '\\':[]        -> Nothing
  c:r | c `elem` ("*+?)|" :: String) -> Nothing
      | otherwise -> Just (RPred (== c), r)
  []             -> Nothing

escClass :: Char -> (Char -> Bool)
escClass = \case
  'd' -> \c -> c >= '0' && c <= '9'
  'w' -> \c -> c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                        || (c >= '0' && c <= '9')
  's' -> \c -> c `elem` (" \t\n\r" :: String)
  c   -> (== c)

parseClass :: String -> Maybe (RNode, String)
parseClass s0 =
  let (neg, s1) = case s0 of { '^':r -> (True, r); _ -> (False, s0) }
  in go neg [] s1
  where
    go _   _   []          = Nothing
    go neg acc (']':r)
      | null acc           = Nothing
      | otherwise          = let f c = any ($ c) acc
                             in Just (RPred (if neg then not . f else f), r)
    go neg acc ('\\':e:r)  = go neg (escClass e : acc) r
    go neg acc (a:'-':b:r)
      | b /= ']'           = go neg ((\c -> c >= a && c <= b) : acc) r
    go neg acc (c:r)       = go neg ((== c) : acc) r

matchNode :: RNode -> String -> (String -> Bool) -> Bool
matchNode n s k = case n of
  RPred p    -> case s of { c:r | p c -> k r; _ -> False }
  RSeq []    -> k s
  RSeq (x:xs)-> matchNode x s (\r -> matchNode (RSeq xs) r k)
  RAlt xs    -> any (\x -> matchNode x s k) xs
  ROpt x     -> matchNode x s k || k s
  RPlus x    -> matchNode x s (\r -> matchNode (RStar x) r k)
  RStar x    -> let go r = k r || matchNode x r (\r' -> if length r' < length r then go r' else False)
                in go s

runRegex :: Regex -> Text -> Bool
runRegex (Regex anchS anchE n) t =
  let s = T.unpack t
      k = if anchE then null else const True
      starts = if anchS then [s] else tails' s
  in any (\st -> matchNode n st k) starts
  where tails' xs = xs : case xs of { [] -> []; (_:r) -> tails' r }

-- | Compile once per (pattern, version) and keep it.
cachedPattern :: Text -> Int -> Text -> Ev Regex
cachedPattern pat ver provenance = do
  s <- evStore
  cache <- evIO $ readIORef (stPatCache s)
  case M.lookup (pat, ver) cache of
    Just r  -> do bumpStat (\st -> st { stPatHit = stPatHit st + 1 }); pure r
    Nothing -> case compileRegex pat of
      Nothing -> evFail (EBadPattern provenance pat)
      Just r  -> do
        bumpStat (\st -> st { stPatMiss = stPatMiss st + 1 })
        evIO $ modifyIORef' (stPatCache s) (M.insert (pat, ver) r)
        pure r

-- | Resolve a Configuration-sourced pattern. The cache key includes the config
-- row version, so retuning the pattern invalidates exactly the entries derived
-- from the old row and nothing else.
configPattern :: Text -> Ev Regex
configPattern path = do
  s <- evStore
  cfg <- evIO $ readIORef (stConfig s)
  case M.lookup path cfg of
    Nothing -> evFail (EConfigMissing path)
    Just (pat, ver) -> cachedPattern pat ver path

-- ---------------------------------------------------------------------------
-- Row access

getRow :: Text -> Text -> Ev Row
getRow table key = do
  s <- evStore
  tabs <- evIO $ readIORef (stTables s)
  case M.lookup table tabs >>= M.lookup key of
    Just r  -> pure r
    Nothing -> evFail (ERowNotFound table key)

cellAs :: Ty a -> Text -> Row -> Ev a
cellAs ty field row = case M.lookup field (rowCells row) of
  Nothing -> evFail (ECellMissing (rowTable row) field)
  Just (Cell ty' v) -> case sameTy ty' ty of
    Just f  -> pure (f v)
    Nothing -> evFail (ECellType (rowTable row) field (showTy ty))

-- ---------------------------------------------------------------------------
-- Evaluation
--
-- The effect index is erased here: `eval` ignores it entirely, because it did
-- its work at construction time. That is the point of a phantom index.

data Ctx = Ctx
  { cxSelf  :: Row
  , cxToken :: Maybe Row      -- ^ Nothing on an internal write with no requesting token
  }

eval :: Ctx -> Env ctx -> Term ctx e a -> Ev a
eval cx env term = case term of
  Lit _ v      -> pure v
  Lift t       -> eval cx env t
  Var _ i      -> pure (lookupEnv i env)
  Let _ v body -> do v' <- eval cx env v; eval cx (ECons v' env) body
  If c t f     -> do c' <- eval cx env c; if c' then eval cx env t else eval cx env f

  Self         -> pure (cxSelf cx)
  AuthedUser   -> case cxToken cx of
                    Just r  -> pure r
                    Nothing -> evFail (EAccessDenied "no requesting token")
  Proj ty f r  -> do r' <- eval cx env r; cellAs ty f r'
  Deref f r    -> do
    r' <- eval cx env r
    bumpStat (\st -> st { stDerefs = stDerefs st + 1 })
    key <- cellAs TText f r'
    tgt <- edgeTarget (rowTable r') f
    getRow tgt key

  VCreatedAt r -> do r' <- eval cx env r
                     pure (Timestamp (didCreatedAt (rowId r')))
  VOrdinal r   -> do r' <- eval cx env r; pure (didOrdinal (rowId r'))
  VOriginSrv r -> do
    r' <- eval cx env r
    -- resolves through Node's candidate key, not a DataId — the one virtual
    -- column that is a reference
    getRow "system.shards.Node" (T.pack (show (didOriginServer (rowId r'))))

  Arith nt op a b   -> applyArith nt op <$> eval cx env a <*> eval cx env b
  DurDiv a b        -> do Duration x <- eval cx env a
                          Duration y <- eval cx env b
                          pure (Amount (fromIntegral x / fromIntegral y))
  DurScale a b      -> do Amount k <- eval cx env a
                          Duration d <- eval cx env b
                          pure (Duration (truncate (k * fromIntegral d)))
  TsDiff a b        -> do Timestamp x <- eval cx env a
                          Timestamp y <- eval cx env b
                          pure (Duration (x - y))
  MomDiff a b       -> do Moment x <- eval cx env a
                          Timestamp y <- eval cx env b
                          pure (Duration (x - y))
  TsAddPeriod a b   -> do Timestamp x <- eval cx env a
                          p <- eval cx env b
                          pure (Timestamp (addPeriodFromOrigin x p))
  StepMonth a b     -> do Timestamp x <- eval cx env a
                          n <- eval cx env b
                          pure (Timestamp (stepMonths x n))
  TruncTo g a       -> do Timestamp x <- eval cx env a
                          pure (Timestamp (truncGrain g x))

  Eq_ w neg a b -> do a' <- eval cx env a; b' <- eval cx env b
                      let r = eqWith w a' b'
                      pure (if neg then not r else r)
  Cmp w op a b  -> do a' <- eval cx env a; b' <- eval cx env b
                      pure (applyCmp op (cmpWith w a' b'))
  Is neg ctor v -> do v' <- eval cx env v
                      let r = vCtor v' == ctor
                      pure (if neg then not r else r)
  And a b       -> do a' <- eval cx env a
                      if a' then eval cx env b else pure False
  Or a b        -> do a' <- eval cx env a
                      if a' then pure True else eval cx env b
  Not a         -> not <$> eval cx env a

  Len a         -> T.length <$> eval cx env a
  Concat a b    -> T.append <$> eval cx env a <*> eval cx env b
  Lower a       -> T.toLower <$> eval cx env a
  ShowAmt a     -> do Amount r <- eval cx env a
                      pure (T.pack (showAmount r))

  MatchK a src  -> do
    a' <- eval cx env a
    -- A compile-time-provenance pattern is interned once, at schema commit.
    -- Version 0 marks "fixed for the life of this schema node", which is
    -- exactly what distinguishes it from a Configuration pattern.
    r <- cachedPattern (patText src) 0 (T.pack (patProvenance src))
    pure (runRegex r a')
  MatchC a path -> do
    a' <- eval cx env a
    r  <- configPattern path
    pure (runRegex r a')

  IsAbsent a    -> eval cx env a >>= \case { Absent _ -> pure True; _ -> pure False }
  Reason a      -> eval cx env a >>= \case
                     Absent r  -> pure (Variant (T.pack (show r)) Nothing)
                     Present _ -> pure (Variant "Present" Nothing)
  OrElse a d    -> eval cx env a >>= \case
                     Present v -> pure v
                     Absent _  -> eval cx env d

  Exists q      -> not . null <$> evalQuery cx env q
  Count q       -> length <$> evalQuery cx env q

  Next uniq     -> do
    s <- evStore
    evIO $ atomicModifyIORef' (stCounters s) $ \m ->
      let n = M.findWithDefault 0 uniq m + 1 in (M.insert uniq n m, n)
  Construct tbl fields -> do
    vals <- mapM (\(k, Field ty t) -> (\v -> (k, Cell ty v)) <$> eval cx env t) fields
    pure (Row (DataId 0 1 0 0) tbl (M.fromList vals))

  FnLit a b n   -> pure (FunctorRef n (T.pack (fnSig a b)))
  CallFn ta tb f x -> do
    FunctorRef name _ <- eval cx env f
    x' <- eval cx env x
    s <- evStore
    case M.lookup name (stFns s) of
      Nothing -> evFail (EFnMissing name)
      Just (SomeFn ta' tb' _ body) ->
        -- the stored term is checked against the column's declared signature
        case (sameTy ta ta', sameTy tb' tb) of
          (Just inC, Just outC) -> outC <$> eval cx (ECons (inC x') ENil) body
          _ -> evFail (EFnSig name (T.pack (fnSig ta tb)) (T.pack (fnSig ta' tb')))

edgeTarget :: Text -> Text -> Ev Text
edgeTarget from field = do
  s <- evStore
  case [ edTo e | e <- stEdges s, edFrom e == from, edField e == field ] of
    (t:_) -> pure t
    []    -> evFail (ECellMissing from field)

-- ---------------------------------------------------------------------------
-- Query evaluation
--
-- A query is a walk from the subject row along declared edges. `QFilter`
-- rebinds `self` to the source just joined, which is what "filter inside the
-- join term" means operationally: the predicate sees the joined source, not
-- the outer row.

evalQuery :: Ctx -> Env ctx -> Query ctx -> Ev [Row]
evalQuery cx env = \case
  QSelf _            -> pure [cxSelf cx]
  QJoin q e dir _    -> do rs <- evalQuery cx env q; concat <$> mapM (step e dir) rs
  QOuter q e dir a _ -> do
    rs <- evalQuery cx env q
    outs <- mapM (step e dir) rs
    -- an outer join yields the guard variant rather than dropping the row
    pure $ concatMap (\(r, o) -> if null o then [guardRow a r] else o) (zip rs outs)
  QFilter q p        -> do
    rs <- evalQuery cx env q
    keep <- mapM (\r -> (,) r <$> eval cx { cxSelf = r } env p) rs
    pure [ r | (r, True) <- keep ]
  where
    guardRow a r = Row (rowId r) (T.pack (show a)) M.empty

step :: Edge -> Dir -> Row -> Ev [Row]
step e Forward r = do
  s <- evStore
  tabs <- evIO $ readIORef (stTables s)
  case M.lookup (edField e) (rowCells r) of
    Just (Cell ty v) | Just f <- sameTy ty TText ->
      pure $ maybe [] (\m -> maybe [] pure (M.lookup (f v) m)) (M.lookup (edTo e) tabs)
    _ -> pure []
step e Reverse r = do
  s <- evStore
  tabs <- evIO $ readIORef (stTables s)
  key <- rowKey r
  let src = M.findWithDefault M.empty (edFrom e) tabs
  pure [ row | row <- M.elems src, pointsAt row key ]
  where
    pointsAt row k = case M.lookup (edField e) (rowCells row) of
      Just (Cell ty v) | Just f <- sameTy ty TText -> f v == k
      _ -> False

-- | The spike keys rows by an explicit @id@ cell so that a reverse walk can
-- compare without a real head_index.
rowKey :: Row -> Ev Text
rowKey r = cellAs TText "id" r

-- ---------------------------------------------------------------------------
-- Applying the four kinds

-- | Kinds 1-3 return @Either Err ()@ and can abort the commit.
applyGuard :: Ctx -> FunctorK -> Ev ()
applyGuard cx = \case
  KValidation name ty pred_ msg -> do
    -- a field validation's context is the field value alone
    v <- cellAs ty (fieldOfValidation name) (cxSelf cx)
    ok <- eval cx (ECons v ENil) pred_
    if ok then pure () else evFail (EViolation name msg)
  KForeignKey name e absences -> do
    k <- cellAs TText (edField e) (cxSelf cx)
    s <- evStore
    tabs <- evIO $ readIORef (stTables s)
    if maybe False (M.member k) (M.lookup (edTo e) tabs)
      then pure ()
      -- Head rule: only the first variant decides the token, so a Null-derived
      -- alternative in `courier :> Courier | NotDispatched` satisfies the edge.
      else if k `elem` map (T.pack . show) absences
             then pure ()
             else evFail (EViolation name ("no row in " <> edTo e))
  KPath name body -> do
    ok <- case body of
      ABExpr t    -> eval cx ENil t
      ABPresent q -> not . null <$> evalQuery cx ENil q
      ABAbsent  q -> null <$> evalQuery cx ENil q
    if ok then pure () else evFail (EViolation name "path constraint")
  KEvent{} -> pure ()   -- events enqueue; they cannot abort

fieldOfValidation :: Text -> Text
fieldOfValidation = last . T.splitOn "."

-- | Sampling a behavior. The Moment arrives as an argument bound into the
-- environment — there is no clock to read, which is the missing 'Effect' lift
-- doing its work rather than a convention about not calling getCurrentTime.
evalBehavior :: Ctx -> Moment -> Behavior a -> Ev a
evalBehavior cx m (Behavior body) = eval cx (ECons m ENil) body

-- | Kind 4. Fires only on a False -> True transition of its condition, which is
-- what the TriggerState bit per (trigger, row) is for. Produces an EventRef,
-- never an Either — the commit already succeeded.
fireEvent :: Ctx -> Timestamp -> FunctorK -> Ev (Maybe EventRef)
fireEvent cx now = \case
  KEvent name trig queue payload -> do
    key <- rowKey (cxSelf cx)
    let cond = case trig of
                 TOn c            -> c
                 TEvery _ (Just c) -> c
                 TEvery _ Nothing  -> Lift (Lit TBool True)
    nowTrue <- eval cx ENil cond
    s <- evStore
    prev <- evIO $ M.findWithDefault False (name, key) <$> readIORef (stTrigger s)
    evIO $ modifyIORef' (stTrigger s) (M.insert (name, key) nowTrue)
    if nowTrue && not prev
      then do
        vals <- mapM (\(k, t) -> (,) k . T.unpack <$> eval cx ENil t) payload
        due <- case trig of
                 TOn _        -> pure now
                 TEvery iv _  -> do Duration d <- eval cx ENil iv
                                    let Timestamp t = now
                                    pure (Timestamp (t + d))
        let ref = EventRef queue vals due
        evIO $ modifyIORef' (stQueue s) (ref :)
        pure (Just ref)
      else pure Nothing
  _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Templates
--
-- Cardinality is the control flow: zero rows render nothing, one renders once,
-- N render N joined by the separator.

renderTemplate :: Ctx -> Template -> Ev Text
renderTemplate cx (Template _ sep pieces) = T.concat <$> mapM piece pieces
  where
    piece (PText t) = pure t
    piece (PHole q using) = do
      rs <- evalQuery cx ENil q
      chunks <- mapM (renderRow using) rs
      pure (T.intercalate sep chunks)
    renderRow using r = case using of
      Just tn -> pure ("<" <> tn <> ":" <> rowTable r <> ">")
      Nothing -> pure ("<" <> rowTable r <> ">")   -- the theme's render fn for the row's type

-- ---------------------------------------------------------------------------
-- Calendar helpers (deliberately crude; the point is that the three types do
-- not interconvert, not that the arithmetic is production-grade)

dayMs :: Integer
dayMs = 86400000

addPeriodFromOrigin :: Integer -> Period -> Integer
addPeriodFromOrigin t (Period n u) = clampMonths t (n * months u)
  where months = \case { PMonth -> 1; PQuarter -> 3; PYear -> 12 }

-- | From-origin: the day-of-month is clamped once, against the target month.
clampMonths :: Integer -> Int -> Integer
clampMonths t n =
  let (y, m, d) = toYmd t
      total = (fromIntegral y * 12 + fromIntegral m - 1) + n
      y' = total `div` 12
      m' = total `mod` 12 + 1
      d' = min d (daysInMonth (fromIntegral y') (fromIntegral m'))
  in fromYmd (fromIntegral y') (fromIntegral m') d'

-- | Accumulating: clamped at each step, so the day-of-month never recovers.
stepMonths :: Integer -> Int -> Integer
stepMonths t n = foldl' (\acc _ -> clampMonths acc 1) t [1 .. n]

toYmd :: Integer -> (Int, Int, Int)
toYmd ms = go 1970 (ms `div` dayMs)
  where
    go y d | d >= yl y = go (y + 1) (d - yl y)
           | otherwise = let (m, dd) = month 1 d in (y, m, fromIntegral dd + 1)
      where
        month m' d' | d' >= fromIntegral (daysInMonth y m') =
                        month (m' + 1) (d' - fromIntegral (daysInMonth y m'))
                    | otherwise = (m', d')
    yl y = if leap y then 366 else 365

fromYmd :: Int -> Int -> Int -> Integer
fromYmd y m d =
  let years = sum [ if leap yy then 366 else 365 | yy <- [1970 .. y - 1] ] :: Integer
      months = sum [ fromIntegral (daysInMonth y mm) | mm <- [1 .. m - 1] ]
  in (fromIntegral years + months + fromIntegral (d - 1)) * dayMs

leap :: Int -> Bool
leap y = (y `mod` 4 == 0 && y `mod` 100 /= 0) || y `mod` 400 == 0

daysInMonth :: Int -> Int -> Int
daysInMonth y m = case m of
  1 -> 31; 2 -> if leap y then 29 else 28; 3 -> 31; 4 -> 30; 5 -> 31; 6 -> 30
  7 -> 31; 8 -> 31; 9 -> 30; 10 -> 31; 11 -> 30; _ -> 31

truncGrain :: Grain -> Integer -> Integer
truncGrain g t = case g of
  GMinute  -> t - t `mod` 60000
  GHour    -> t - t `mod` 3600000
  GDay     -> t - t `mod` dayMs
  GIsoWeek -> let d = t `div` dayMs in (d - ((d + 3) `mod` 7)) * dayMs  -- Monday
  GMonth   -> let (y, m, _) = toYmd t in fromYmd y m 1
  GQuarter -> let (y, m, _) = toYmd t in fromYmd y (((m - 1) `div` 3) * 3 + 1) 1
  GYear    -> let (y, _, _) = toYmd t in fromYmd y 1 1
  GIsoYear -> let (y, _, _) = toYmd t in fromYmd y 1 1

-- | Two decimal places, without pulling in a formatting library.
showAmount :: Rational -> String
showAmount r =
  let cents = round (r * 100) :: Integer
      (w, c) = (abs cents `div` 100, abs cents `mod` 100)
      sign = if cents < 0 then "-" else ""
  in sign ++ show w ++ "." ++ (if c < 10 then '0' : show c else show c)

-- | Convenience for the runner.
mkRow :: Text -> Text -> Integer -> Int -> [(Text, Cell)] -> Row
mkRow table key created srv cells =
  Row (DataId created srv 0 0) table (M.fromList (("id", Cell TText key) : cells))

tableOf :: [Row] -> Map Text Row
tableOf rs = M.fromList (mapMaybe (\r -> (,) <$> keyOf r <*> pure r) rs)
  where keyOf r = case M.lookup "id" (rowCells r) of
          Just (Cell ty v) -> sameTy ty TText >>= \f -> Just (f v)
          Nothing -> Nothing
