-- | The structural analyses the transparency invariant promises.
--
-- Every function here is a pure walk over a term or a query. That is the whole
-- argument for keeping the DSL term authoritative: compiled code answers none
-- of these questions, and the optimizer, the access analyser, the coercion-path
-- deriver, and the IDE all ask them.
module Spike.Analysis where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import Data.List (nub, sort, intercalate)
import Spike.Core

-- ---------------------------------------------------------------------------
-- A generic fold over terms

data Visit m = Visit
  { vTerm  :: forall c f b. Term c f b -> m
  , vQuery :: forall c.     Query c    -> m
  }

emptyVisit :: Monoid m => Visit m
emptyVisit = Visit (const mempty) (const mempty)

walkTerm :: Monoid m => Visit m -> Term ctx e a -> m
walkTerm v t0 = vTerm v t0 <> case t0 of
  Lit _ _          -> mempty
  Lift x           -> walkTerm v x
  Var _ _          -> mempty
  Let _ a b        -> walkTerm v a <> walkTerm v b
  If c a b         -> walkTerm v c <> walkTerm v a <> walkTerm v b
  Self             -> mempty
  AuthedUser       -> mempty
  Proj _ _ r       -> walkTerm v r
  Deref _ r        -> walkTerm v r
  VCreatedAt r     -> walkTerm v r
  VOrdinal r       -> walkTerm v r
  VOriginSrv r     -> walkTerm v r
  Arith _ _ a b    -> walkTerm v a <> walkTerm v b
  DurDiv a b       -> walkTerm v a <> walkTerm v b
  DurScale a b     -> walkTerm v a <> walkTerm v b
  TsDiff a b       -> walkTerm v a <> walkTerm v b
  MomDiff a b      -> walkTerm v a <> walkTerm v b
  TsAddPeriod a b  -> walkTerm v a <> walkTerm v b
  StepMonth a b    -> walkTerm v a <> walkTerm v b
  TruncTo _ a      -> walkTerm v a
  Eq_ _ _ a b      -> walkTerm v a <> walkTerm v b
  Cmp _ _ a b      -> walkTerm v a <> walkTerm v b
  Is _ _ a         -> walkTerm v a
  And a b          -> walkTerm v a <> walkTerm v b
  Or a b           -> walkTerm v a <> walkTerm v b
  Not a            -> walkTerm v a
  Len a            -> walkTerm v a
  Concat a b       -> walkTerm v a <> walkTerm v b
  Lower a          -> walkTerm v a
  ShowAmt a        -> walkTerm v a
  MatchK a _       -> walkTerm v a
  MatchC a _       -> walkTerm v a
  IsAbsent a       -> walkTerm v a
  Reason a         -> walkTerm v a
  OrElse a b       -> walkTerm v a <> walkTerm v b
  Exists q         -> walkQuery v q
  Count q          -> walkQuery v q
  Next _           -> mempty
  Construct _ fs   -> mconcat [ walkTerm v x | (_, Field _ x) <- fs ]
  FnLit _ _ _      -> mempty
  CallFn _ _ f x   -> walkTerm v f <> walkTerm v x

walkQuery :: Monoid m => Visit m -> Query ctx -> m
walkQuery v q0 = vQuery v q0 <> case q0 of
  QSelf _            -> mempty
  QJoin q _ _ _      -> walkQuery v q
  QOuter q _ _ _ _   -> walkQuery v q
  QFilter q p        -> walkQuery v q <> walkTerm v p

walkBody :: Monoid m => Visit m -> AssertBody -> m
walkBody v = \case
  ABExpr t    -> walkTerm v t
  ABPresent q -> walkQuery v q
  ABAbsent  q -> walkQuery v q

-- ---------------------------------------------------------------------------
-- The access variety, read off the body
--
-- An assert whose body mentions `authed_user` is an access constraint; anything
-- else is a data constraint. Nothing about the name enters into it, which is
-- what makes `bypass access` exempt an exact set instead of whatever happened
-- to be spelled `access`.

data Variety = DataConstraint | AccessConstraint deriving (Eq, Show)

mentionsToken :: Monoid m => Visit m
mentionsToken = emptyVisit

tokenMentions :: Term ctx e a -> Int
tokenMentions = getSum' . walkTerm (Visit f (const (Sum' 0)))
  where f :: Term c g b -> Sum'
        f AuthedUser = Sum' 1
        f _          = Sum' 0

bodyTokenMentions :: AssertBody -> Int
bodyTokenMentions = getSum' . walkBody (Visit f (const (Sum' 0)))
  where f :: Term c g b -> Sum'
        f AuthedUser = Sum' 1
        f _          = Sum' 0

newtype Sum' = Sum' { getSum' :: Int }
instance Semigroup Sum' where Sum' a <> Sum' b = Sum' (a + b)
instance Monoid Sum' where mempty = Sum' 0

variety :: AssertBody -> Variety
variety b = if bodyTokenMentions b > 0 then AccessConstraint else DataConstraint

-- | What `grant <role> on <ns> bypass access` skips, and what it does not.
-- An administrator is exempt from access control, never from data integrity.
bypassPartition :: [FunctorK] -> ([Text], [Text])
bypassPartition fs =
  ( [ n | KPath n b <- fs, variety b == AccessConstraint ]
  , [ n | KPath n b <- fs, variety b == DataConstraint   ] )

-- | Conjuncts of an access assert that do not mention the token are bypassed
-- along with it. That is almost never intended, so schema commit warns and
-- names them. Conjuncts are the top-level 'And' spine.
silentlyBypassed :: AssertBody -> [Int]
silentlyBypassed b
  | variety b /= AccessConstraint = []
  | otherwise = case b of
      ABExpr t -> [ i | (i, n) <- zip [1 ..] (conjuncts t), n == 0 ]
      _        -> []
  where
    conjuncts :: Term ctx e Bool -> [Int]
    conjuncts (And x y) = conjuncts x ++ conjuncts y
    conjuncts t         = [tokenMentions t]

-- ---------------------------------------------------------------------------
-- Anchoring
--
-- Rooted at self is structural — 'QSelf' is the only root constructor. What
-- still needs checking is that every join follows a *declared* :> edge, which
-- is what bounds an access assert's work to the row's connected component.

anchorCheck :: [Edge] -> Query ctx -> Either String ()
anchorCheck declared = go
  where
    go = \case
      QSelf _          -> Right ()
      QFilter q _      -> go q
      QJoin q e _ _    -> go q >> declaredOk e
      QOuter q e _ _ _ -> go q >> declaredOk e
    declaredOk e
      | e `elem` declared = Right ()
      | otherwise = Left $ "join along undeclared edge " ++ T.unpack (edFrom e)
                           ++ "." ++ T.unpack (edField e) ++ " :> " ++ T.unpack (edTo e)

-- | The hop count an assert costs on every read that reaches the row.
queryHops :: Query ctx -> Int
queryHops = \case
  QSelf _          -> 0
  QFilter q _      -> queryHops q
  QJoin q _ _ _    -> 1 + queryHops q
  QOuter q _ _ _ _ -> 1 + queryHops q

-- | Anchoring bounds work; it does not buy locality. An edge leaving the shard
-- family means the revalidation set crosses shards, which is what forces the
-- attachment down from `enforce always` to `enforce forward`.
crossingEdges :: [Text] -> Query ctx -> [Edge]
crossingEdges family = nub . go
  where
    go = \case
      QSelf _          -> []
      QFilter q _      -> go q
      QJoin q e _ _    -> go q ++ [ e | edTo e `notElem` family ]
      QOuter q e _ _ _ -> go q ++ [ e | edTo e `notElem` family ]

-- | A negative assertion's revalidation set is the FK chain traversed
-- backwards: writing a row in @table@ obliges revisiting asserts on every table
-- that can reach it.
revalidationSet :: [Edge] -> Text -> [Text]
revalidationSet edges table = sort (nub (go [table] [table]))
  where
    go []      seen = seen
    go (t:ts)  seen =
      let ups = [ edFrom e | e <- edges, edTo e == t, edFrom e `notElem` seen ]
      in go (ts ++ ups) (seen ++ ups)

-- ---------------------------------------------------------------------------
-- Filter placement
--
-- A filter on an outer-joined source must sit inside the join term. Filtering
-- after the guard deletes the rows the guard produced, so an account whose every
-- suspension is lifted yields zero rows instead of a NoSuspension row. The
-- constructor shape closes it: 'QFilter' applied to a 'QOuter' is the error.

filterPlacement :: Query ctx -> Either String ()
filterPlacement = \case
  QFilter (QOuter{}) _ ->
    Left "filter applied outside an outer join term; move it inside: \
         \Account >< (Suspension where …) | NoSuspension"
  QFilter q _      -> filterPlacement q
  QJoin q _ _ _    -> filterPlacement q
  QOuter q _ _ _ _ -> filterPlacement q
  QSelf _          -> Right ()

-- ---------------------------------------------------------------------------
-- The function call graph must be acyclic
--
-- Decidable because the graph is in the schema graph. A schema-commit
-- obligation, not a runtime guard, which is what makes 'CallFn' terminate.

callGraphAcyclic :: [(Text, [Text])] -> Either [Text] ()
callGraphAcyclic g = mapM_ (\n -> visit [] n) (map fst g)
  where
    adj = M.fromList g
    visit path n
      | n `elem` path = Left (reverse (n : path))
      | otherwise     = mapM_ (visit (n : path)) (M.findWithDefault [] n adj)

-- ---------------------------------------------------------------------------
-- The `every`-was-unnecessary classifier
--
-- OQ-034 wants the solver's job framed as shrinking the set of conditions for
-- which `every` is the only option. The classifier that decides "could the
-- solver have closed this?" is required even for conditions the solver declines,
-- because it is what the warning is made of.

data Closable = Closable String | NotClosable String deriving (Eq, Show)

-- | A sampled condition is closable when it compares a monotone function of the
-- observation moment against something that does not move: solve for the
-- crossing instead of sampling for it.
classifyTrigger :: Trigger -> Closable
classifyTrigger = \case
  TOn _ -> Closable "transition observed across the write; no sampling at all"
  TEvery _ Nothing -> NotClosable "no condition — an unconditional tick has no crossing to solve"
  TEvery _ (Just c)
    | movingBoth c   -> NotClosable "both sides move with the row's stored fields"
    | derefs c > 0   -> NotClosable "condition dereferences an edge, so it moves when another row is written"
    | otherwise      -> Closable "condition is a comparison against a value fixed at the write; \
                                 \a crossing moment is derivable"
  where
    movingBoth c = derefs c > 1

derefs :: Term ctx e a -> Int
derefs = getSum' . walkTerm (Visit f (const (Sum' 0)))
  where f :: Term c g b -> Sum'
        f (Deref _ _)   = Sum' 1
        f (VOriginSrv _) = Sum' 1
        f (CallFn _ _ _ _) = Sum' 1
        f _             = Sum' 0

-- ---------------------------------------------------------------------------
-- Retention chain alignment
--
-- A step's retention is compared against the successor grain's *maximum* span,
-- which keeps the check conservative and decidable. Grains align rather than
-- merely coarsen, so the check is over declared alignment edges, not arithmetic.

grainMaxSpan :: Grain -> Duration
grainMaxSpan = \case
  GMinute  -> Duration 60000
  GHour    -> Duration 3600000
  GDay     -> Duration 86400000
  GIsoWeek -> Duration (7 * 86400000)
  GMonth   -> Duration (31 * 86400000)
  GQuarter -> Duration (92 * 86400000)
  GYear    -> Duration (366 * 86400000)
  GIsoYear -> Duration (371 * 86400000)

-- | @(grain, retention)@ per step, coarsest last.
chainCheck :: [(Grain, Duration)] -> Either String ()
chainCheck steps = mapM_ step (zip steps (drop 1 steps))
  where
    step ((g, Duration keep), (g', _)) = do
      case grainParent g of
        Nothing -> Left $ show g ++ " is a root of the alignment forest; nothing coarsens it"
        Just p | p /= g' && not (reachable g g') ->
                   Left $ show g ++ " does not tile " ++ show g'
                          ++ " — the two are on different roots or skip a level"
               | otherwise -> Right ()
      let Duration maxSpan = grainMaxSpan g'
      if keep < maxSpan
        then Left $ "retention " ++ show (Duration keep) ++ " at " ++ show g
                    ++ " is shorter than the maximum span of " ++ show g'
                    ++ " (" ++ show (Duration maxSpan) ++ ")"
        else Right ()
    reachable a b = b `elem` ancestors a
    ancestors a = case grainParent a of
      Nothing -> []
      Just p  -> p : ancestors p

-- ---------------------------------------------------------------------------
-- Static cost and feature inventory

termSize :: Term ctx e a -> Int
termSize = getSum' . walkTerm (Visit (const (Sum' 1)) (const (Sum' 0)))

newtype Feats = Feats [String]
instance Semigroup Feats where Feats a <> Feats b = Feats (a ++ b)
instance Monoid Feats where mempty = Feats []

features :: Term ctx e a -> [String]
features t = let Feats fs = walkTerm (Visit f (const mempty)) t in nub (sort fs)
  where
    f :: Term c g b -> Feats
    f = \case
      AuthedUser      -> Feats ["authed_user"]
      Deref _ _       -> Feats [":> deref"]
      MatchK _ s      -> Feats ["=~ " ++ patProvenance s]
      MatchC _ _      -> Feats ["=~ Configuration (runtime, cached)"]
      Is _ _ _        -> Feats ["is"]
      IsAbsent _      -> Feats ["typed absence"]
      Reason _        -> Feats ["typed absence"]
      OrElse _ _      -> Feats ["typed absence"]
      Exists _        -> Feats ["anchored subquery"]
      Count _         -> Feats ["anchored subquery"]
      Next _          -> Feats ["next (Tx)"]
      Construct _ _   -> Feats ["Component construction (Tx)"]
      DurDiv _ _      -> Feats ["Duration / Duration"]
      DurScale _ _    -> Feats ["unit as value"]
      TsAddPeriod _ _ -> Feats ["Period (calendar, from-origin)"]
      StepMonth _ _   -> Feats ["stepMonth (accumulating, clamped)"]
      TruncTo _ _     -> Feats ["Grain truncation"]
      VCreatedAt _    -> Feats ["virtual column"]
      VOrdinal _      -> Feats ["virtual column"]
      VOriginSrv _    -> Feats ["virtual column (reference)"]
      CallFn _ _ _ _  -> Feats ["function-typed column"]
      FnLit _ _ _     -> Feats ["function-typed column"]
      Let _ _ _       -> Feats ["let … in"]
      Var _ _         -> Feats ["bound variable"]
      _               -> mempty

featuresOfBody :: AssertBody -> [String]
featuresOfBody = \case
  ABExpr t    -> features t
  ABPresent q -> "anchored subquery (presence)" : featuresOfQuery q
  ABAbsent  q -> "anchored subquery (absence)"  : featuresOfQuery q

featuresOfQuery :: Query ctx -> [String]
featuresOfQuery q = let Feats fs = walkQuery (Visit fT fQ) q in nub (sort fs)
  where
    fT :: Term c g b -> Feats
    fT AuthedUser = Feats ["authed_user"]
    fT _          = mempty
    fQ :: Query c -> Feats
    fQ (QOuter _ _ _ a _) = Feats ["outer join guard (" ++ show a ++ ")"]
    fQ (QFilter _ _)      = Feats ["filter inside join term"]
    fQ _                  = mempty

showList' :: [String] -> String
showList' [] = "(none)"
showList' xs = intercalate ", " xs
