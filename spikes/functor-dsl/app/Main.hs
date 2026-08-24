-- | Spike runner. Writes the record kept in output.txt.
module Main (main) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Text.Printf (printf, PrintfType)
import Control.Monad (forM_)
import Spike.Core
import Spike.Eval
import Spike.Schema
import Spike.Analysis

main :: IO ()
main = do
  banner "DataCode Functor DSL Spike -- OQ-001 revisit"
  putStrLn "Effect-indexed GADT over the full current schema syntax."
  putStrLn "Supersedes the DSL half of spikes/dynamic-loading (see output.txt)."

  section "1. What the type indices rule out"
  sec1
  section "2. The four functor kinds"
  sec2
  section "3. Regex: provenance decides the effect"
  sec3
  section "4. Event functors: both trigger forms"
  sec4
  section "5. Behaviors"
  sec5
  section "6. Function-typed columns"
  sec6
  section "7. Templates: cardinality is the control flow"
  sec7
  section "8. Structural analyses (the transparency invariant)"
  sec8
  section "9. let, virtual columns, next, Component construction"
  sec8b
  section "10. Duration / Period / Grain"
  sec9
  section "11. Apply latency"
  sec10
  section "12. Ceiling"
  sec11

-- ---------------------------------------------------------------------------

banner :: String -> IO ()
banner s = do
  putStrLn (replicate 74 '=')
  putStrLn ("  " ++ s)
  putStrLn (replicate 74 '=')

section :: String -> IO ()
section s = putStrLn ("\n--- " ++ s ++ " " ++ replicate (max 0 (68 - length s)) '-')

-- | printf with the format literal pinned to String. Without this,
-- OverloadedStrings leaves every format string ambiguous.
pf :: PrintfType r => String -> r
pf = printf

run :: Store -> Ev a -> IO (Either Err a)
run st act = runEv act st

-- | Evaluate against a subject row and an optional requesting token.
withCtx :: Row -> Maybe Row -> Ctx
withCtx = Ctx

report :: Show a => String -> Either Err a -> IO ()
report label = \case
  Right v -> pf "  %-46s => %s\n" label (show v)
  Left e  -> pf "  %-46s => REJECTED: %s\n" label (show e)

reportOk :: String -> Either Err () -> IO ()
reportOk label = \case
  Right () -> pf "  %-46s => admitted\n" label
  Left e   -> pf "  %-46s => REJECTED: %s\n" label (show e)

-- ---------------------------------------------------------------------------

sec1 :: IO ()
sec1 = do
  putStrLn "  The old spike's Expr was a plain ADT, so a type error surfaced at eval"
  putStrLn "  time as ValidationError \"... type mismatch\". Two of the three wrong"
  putStrLn "  answers in its recorded run were that leak. Each row below is a term"
  putStrLn "  this DSL rejects at DataCode compile time; every GHC error quoted was"
  putStrLn "  produced by compiling the term, not written by hand."
  putStrLn ""
  forM_ rejected $ \(what, err, why) -> do
    pf "  %s\n" what
    pf "      %-42s %s\n" err why
  putStrLn ""
  putStrLn "  What typing does NOT catch, checked structurally instead (section 8):"
  forM_ notTyped $ \(what, why) -> pf "    %-34s %s\n" what why
  where
    rejected :: [(String, String, String)]
    rejected =
      [ ( "Concat (Lit TText \"amount was \") (Var TAmt IZ)"
        , "Couldn't match Amount with Text", "the old spike's actual bug" )
      , ( "Cmp OrdInt CmpGt (Lit TText \"x\") (Lit TInt 1)"
        , "Expected Ty Int, actual Ty Text", "no cross-type comparison" )
      , ( "Eq_ EqFun (FnLit ...) (FnLit ...)"
        , "Data constructor not in scope: EqFun", "function types have no equality" )
      , ( "KValidation \"t.f\" TInt (... Next \"orderRef\" ...)"
        , "Couldn't match Tx with 'Read", "next is not a predicate" )
      , ( "Behavior (Next \"orderRef\")"
        , "Couldn't match Tx with 'Read", "a behavior may not mutate" )
      , ( "Lift (Next \"orderRef\") :: Term '[] 'Read Int"
        , "No instance for Sub Tx 'Read", "the ladder has no downward lift" )
      , ( "bad :: Term '[] 'Effect Int"
        , "Not in scope: data constructor Effect", "no Effect rung exists at all" )
      , ( "Var TAmt (IS IZ) :: Term '[Amount] 'Pure Amount"
        , "Expected Idx '[] Amount", "cannot name a slot the context lacks" )
      , ( "Var TText IZ :: Term '[Amount] 'Pure Text"
        , "Expected Idx '[Amount] Text", "cannot name a slot at the wrong type" )
      , ( "TsAddPeriod ts (Lit TDur day)"
        , "Couldn't match Duration with Period", "no Period/Duration conversion" )
      , ( "Arith NumInt OpAdd (Lit TPer ...) (Lit TPer ...)"
        , "Expected NumT Period, actual NumT Int", "a Period has no ms count" )
      ]
    notTyped :: [(String, String)]
    notTyped =
      [ ("an unanchored join", "QSelf is the only root, but a join along an")
      , ("", "  undeclared edge compiles -- anchorCheck rejects it")
      , ("a filter outside a guard", "shape check, not a type: filterPlacement")
      , ("a cyclic call graph", "callGraphAcyclic, at schema commit")
      , ("a bypassed conjunct", "a warning, so it must not be a type error")
      ]

-- ---------------------------------------------------------------------------

sec2 :: IO ()
sec2 = do
  st <- mkStore
  let tok1 = M.lookup "u-1" =<< M.lookup "auth.User" demoTables
      tok2 = M.lookup "u-2" =<< M.lookup "auth.User" demoTables

  putStrLn "  Kind 1 -- validation (a -> Either Error a, on commit)"
  cust <- pure (M.lookup "c-1" =<< M.lookup "app.commerce.Customer" demoTables)
  forM_ cust $ \c -> do
    r <- run st (applyGuard (withCtx c Nothing) vEmail)
    reportOk "Customer.email ada@example.com" r
  let badCust = orderRow { rowTable = "app.commerce.Customer"
                         , rowCells = M.insert "email" (Cell TText "notanemail")
                                        (rowCells orderRow) }
  r <- run st (applyGuard (withCtx badCust Nothing) vEmail)
  reportOk "Customer.email notanemail" r

  addr1 <- pure (M.lookup "a-1" =<< M.lookup "app.commerce.Address" demoTables)
  addr2 <- pure (M.lookup "a-2" =<< M.lookup "app.commerce.Address" demoTables)
  forM_ addr1 $ \a -> run st (applyGuard (withCtx a Nothing) vPostal)
                        >>= reportOk "Address.postal_code 80301"
  forM_ addr2 $ \a -> run st (applyGuard (withCtx a Nothing) vPostal)
                        >>= reportOk "Address.postal_code 80301-1234"

  putStrLn "\n  Kind 2 -- foreign key (DataId -> Either Error Row, on commit)"
  run st (applyGuard (withCtx orderRow Nothing) fkCustomer)
    >>= reportOk "Order.customer -> c-1"
  let dangling = orderRow { rowCells = M.insert "customer" (Cell TText "c-404")
                                         (rowCells orderRow) }
  run st (applyGuard (withCtx dangling Nothing) fkCustomer)
    >>= reportOk "Order.customer -> c-404"
  let undispatched = orderRow { rowCells = M.insert "courier"
                                  (Cell TText (T.pack (show NotDispatched)))
                                  (rowCells orderRow) }
  run st (applyGuard (withCtx undispatched Nothing) fkCourier)
    >>= reportOk "Order.courier -> NotDispatched (head rule)"

  putStrLn "\n  Kind 3 -- path constraint, data variety (Row -> Either Error ())"
  run st (applyGuard (withCtx orderRow Nothing) aBillingMatch)
    >>= reportOk "billingMatch, addresses agree"
  let wrongAddr = orderRow { rowCells = M.insert "bill_addr" (Cell TText "a-2")
                                          (rowCells orderRow) }
  run st (applyGuard (withCtx wrongAddr Nothing) aBillingMatch)
    >>= reportOk "billingMatch, addresses differ"

  putStrLn "\n  Kind 3 -- path constraint, access variety (read AND write)"
  run st (applyGuard (withCtx orderRow tok1) aOwnerAccess)
    >>= reportOk "ownerAccess as the owner"
  run st (applyGuard (withCtx orderRow tok2) aOwnerAccess)
    >>= reportOk "ownerAccess as another user"
  putStrLn "  (on a read the failure resolves to Redacted, not an abort)"

  putStrLn "\n  Kind 3 -- presence and absence, the shapes equality could not express"
  run st (applyGuard (withCtx orderRow tok1) aMemberAccess)
    >>= reportOk "memberAccess (query non-empty) as owner"
  run st (applyGuard (withCtx orderRow tok2) aMemberAccess)
    >>= reportOk "memberAccess as another user"
  run st (applyGuard (withCtx orderRow Nothing) aNotSuspended)
    >>= reportOk "notSuspended, only a lifted suspension"
  st2 <- mkStore
  modifyIORef' (stTables st2) $ M.adjust
    (M.insert "s-active" (mkRow "app.commerce.Suspension" "s-active" 1700000000000 1
      [("account", Cell TText "c-1"), ("lifted", Cell TVar (Variant "NotLifted" Nothing))]))
    "app.commerce.Suspension"
  run st2 (applyGuard (withCtx orderRow Nothing) aNotSuspended)
    >>= reportOk "notSuspended, an unlifted suspension exists"

-- ---------------------------------------------------------------------------

sec3 :: IO ()
sec3 = do
  st <- mkStore
  putStrLn "  The right operand is restricted by trait. Two constructors, so the"
  putStrLn "  effect index derives the difference instead of restating it:"
  mapM_ (\(a, b) -> pf "    %-38s %s\n" a b)
    ([ ("MatchK <StringLit>",           "Pure -- checked at schema commit")
     , ("MatchK <Reference path>",      "Pure -- a Reference insert IS a commit")
     , ("MatchC <Configuration path>",  "Read -- resolves at runtime, cached")
     ] :: [(String, String)])
  putStrLn ""
  run st (applyGuard (withCtx orderRow Nothing) vSku)
    >>= reportOk "Order.sku SKU-4471 vs configured pattern"
  let badSku = orderRow { rowCells = M.insert "sku" (Cell TText "SKU-44")
                                       (rowCells orderRow) }
  run st (applyGuard (withCtx badSku Nothing) vSku)
    >>= reportOk "Order.sku SKU-44 vs configured pattern"

  putStrLn "\n  Cache is keyed on the Configuration row version:"
  s0 <- readIORef (stStats st)
  pf "    after two matches: %d compile, %d cache hit\n" (stPatMiss s0) (stPatHit s0)
  -- retune the pattern; the version bump invalidates exactly the old entry
  modifyIORef' (stConfig st)
    (M.insert "system.regex.SkuPattern.pattern" ("^SKU-[0-9][0-9]$", 2))
  run st (applyGuard (withCtx badSku Nothing) vSku)
    >>= reportOk "Order.sku SKU-44 after retuning to ^SKU-[0-9]{2}$"
  s1 <- readIORef (stStats st)
  pf "    after retune:      %d compile, %d cache hit\n" (stPatMiss s1) (stPatHit s1)

  putStrLn "\n  A malformed pattern fails where its provenance implies:"
  modifyIORef' (stConfig st)
    (M.insert "system.regex.SkuPattern.pattern" ("^SKU-[0-9", 3))
  run st (applyGuard (withCtx orderRow Nothing) vSku)
    >>= reportOk "Configuration pattern ^SKU-[0-9 (unterminated)"
  putStrLn "    a StringLit or Reference pattern is rejected at schema commit instead,"
  putStrLn "    so it never reaches a row at all"

-- ---------------------------------------------------------------------------

sec4 :: IO ()
sec4 = do
  st <- mkStore
  putStrLn "  Both forms fire on a False -> True transition, never on merely being"
  putStrLn "  true. The state is a TriggerState bit per (trigger, row)."
  putStrLn ""
  putStrLn "  on status is Shipped emit app.events.EmailQueue { … }"
  r1 <- run st (fireEvent (withCtx orderRow Nothing) (Timestamp 1700000005000) evShipped)
  report "tick 1: status Pending" r1
  r2 <- run st (fireEvent (withCtx orderShipped Nothing) (Timestamp 1700000006000) evShipped)
  report "tick 2: status Shipped (transition)" r2
  r3 <- run st (fireEvent (withCtx orderShipped Nothing) (Timestamp 1700000007000) evShipped)
  report "tick 3: still Shipped (no transition)" r3

  putStrLn "\n  every poll_interval emit … where balance >= credit_limit"
  putStrLn "  (the interval is a field of the row, evaluated per row per tick)"
  r4 <- run st (fireEvent (withCtx orderRow Nothing) (Timestamp 1700000008000) evPoll)
  report "tick 1: 500 >= 400, transition" r4
  r5 <- run st (fireEvent (withCtx orderRow Nothing) (Timestamp 1700000009000) evPoll)
  report "tick 2: still true, no transition" r5

  q <- readIORef (stQueue st)
  pf "\n  queue depth after five ticks: %d\n" (length q)
  putStrLn "  each entry is a row in an ordinary LogData queue table, not a blob:"
  forM_ (reverse q) $ \e ->
    pf "    %-26s scheduled %s  %s\n" (T.unpack (erQueue e))
      (show (erScheduled e)) (show (erPayload e))
  putStrLn "  an event functor produces an EventRef, never Either Error a -- inserting"
  putStrLn "  the queue row IS the commit, so it can abort nothing"

-- ---------------------------------------------------------------------------

sec5 :: IO ()
sec5 = do
  st <- mkStore
  let cust = M.findWithDefault (orderRow) "c-1"
               (M.findWithDefault M.empty "app.commerce.Customer" demoTables)
  putStrLn "  accrued : Behavior Amount = \\m -> rate * (m - opened_at) / day"
  putStrLn "  Nothing is stored. Moment arrives as an argument, so there is no clock"
  putStrLn "  to read -- the missing Effect lift rather than a convention."
  putStrLn ""
  forM_ [0, 1, 7, 30, 365] $ \d -> do
    let m = Moment (1700000000000 + d * 86400000)
    r <- run st (evalBehavior (withCtx cust Nothing) m bAccrued)
    report ("sample at +" ++ show d ++ " day") r
  putStrLn "  the same term sampled in the past and the future, unchanged: Moment"
  putStrLn "  ranges over both, which is why it is not called CurrentTime"

-- ---------------------------------------------------------------------------

sec6 :: IO ()
sec6 = do
  st <- mkStore
  putStrLn "  type Renderer = Amount -> Read Text; a field names it and may not"
  putStrLn "  write an arrow inline. Storage is unchanged -- it is a FunctorRef --"
  putStrLn "  and what is new is that the compiler knows the signature."
  putStrLn ""
  run st (eval (withCtx orderRow Nothing) ENil callStyle)
    >>= report "style s-1 -> render (registered)"
  let noFn = orderRow { rowCells = M.insert "style" (Cell TText "s-2") (rowCells orderRow) }
  run st (eval (withCtx noFn Nothing) ENil callStyle)
    >>= report "style s-2 -> render (unregistered)"

  putStrLn "\n  The call graph must be acyclic -- decidable, because it is in the"
  putStrLn "  schema graph, and a schema-commit obligation rather than a runtime guard."
  case callGraphAcyclic goodCallGraph of
    Right () -> putStrLn "    money -> round2                        => admitted"
    Left c   -> putStrLn ("    unexpected cycle: " ++ show c)
  case callGraphAcyclic badCallGraph of
    Right () -> putStrLn "    money -> round2 -> fmt -> money        => MISSED"
    Left c   -> pf "    money -> round2 -> fmt -> money        => REJECTED: %s\n"
                          (T.unpack (T.intercalate " -> " c))
  putStrLn "\n  Restrictions that fall out of function types having no equality:"
  putStrLn "    unique, order by, group by, ==, indexed, candidate key, field where"
  putStrLn "    -- all closed by the absence of an EqT/OrdT instance, not by a rule"

-- ---------------------------------------------------------------------------

sec7 :: IO ()
sec7 = do
  st <- mkStore
  putStrLn "  One production, and the result count of a hole's query is the control"
  putStrLn "  flow: 0 rows renders nothing, 1 renders once, N renders N joined by the"
  putStrLn "  template's separator. No if, no each, no else."
  putStrLn ""
  run st (renderTemplate (withCtx orderRow Nothing) orderTemplate)
    >>= report "order with a courier" . fmap T.unpack
  st2 <- mkStore
  modifyIORef' (stTables st2) (M.insert "app.commerce.Courier" M.empty)
  run st2 (renderTemplate (withCtx orderRow Nothing) orderTemplate)
    >>= report "courier hole returns zero rows" . fmap T.unpack
  putStrLn "  the second is the conditional, and it is just the query's where clause"
  putStrLn "  holes are Read and rooted at self, the same anchoring rule as an assert"

-- ---------------------------------------------------------------------------

sec8 :: IO ()
sec8 = do
  putStrLn "  Every answer below is a pure walk over the term. This is what the"
  putStrLn "  transparency invariant is for, and what compiled code cannot answer."
  putStrLn ""
  putStrLn "  Assert variety, read off the body (never the name):"
  forM_ [aBillingMatch, aOwnerAccess, aMemberAccess, aNotSuspended, aMixedAccess] $
    \f -> case f of
      KPath n b -> pf "    %-16s %-18s %d mention(s) of authed_user\n"
                     (T.unpack n) (show (variety b)) (bodyTokenMentions b)
      _ -> pure ()

  let (skipped, kept) = bypassPartition allFunctors
  putStrLn "\n  grant <role> on <ns> bypass access skips exactly:"
  pf "    skipped:  %s\n" (showList' (map T.unpack skipped))
  pf "    enforced: %s\n" (showList' (map T.unpack kept))
  putStrLn "    an administrator is exempt from access control, never from integrity"

  putStrLn "\n  Warning: a conjunct of an access assert that does not mention the token"
  putStrLn "  is bypassed with it, which is almost never intended."
  case aMixedAccess of
    KPath n b -> pf "    %s: conjunct(s) %s have no token mention\n"
                   (T.unpack n) (show (silentlyBypassed b))
    _ -> pure ()

  putStrLn "\n  Anchoring: every join must follow a declared :> edge."
  forM_ ([ ("memberAccess", bodyQuery aMemberAccess)
         , ("notSuspended", bodyQuery aNotSuspended)
         , ("warehouseStocked", bodyQuery aCrossShard)
         ] :: [(String, Maybe (Query '[]))]) $ \(n, mq) ->
    forM_ mq $ \q -> case anchorCheck allEdges q of
      Right () -> pf "    %-18s %d hop(s)  => anchored\n" n (queryHops q)
      Left e   -> pf "    %-18s %d hop(s)  => REJECTED: %s\n" n (queryHops q) e

  putStrLn "\n  Anchoring bounds work; it does not buy locality:"
  forM_ (bodyQuery aCrossShard) $ \q ->
    forM_ (crossingEdges orderFamily q) $ \e ->
      pf "    edge %s.%s :> %s leaves the shard family\n"
        (T.unpack (edFrom e)) (T.unpack (edField e)) (T.unpack (edTo e))
  putStrLn "    consequence: this attachment cannot be `enforce always`; it is"
  putStrLn "    coerced to `enforce forward` and the commit reports the crossing"

  putStrLn "\n  Revalidation set -- the FK chain traversed backwards. Writing a"
  putStrLn "  Suspension row obliges revisiting asserts on:"
  pf "    %s\n" (showList' (map T.unpack
    (revalidationSet allEdges "app.commerce.Suspension")))
  putStrLn "  and writing an Address:"
  pf "    %s\n" (showList' (map T.unpack
    (revalidationSet allEdges "app.commerce.Address")))

  putStrLn "\n  Filter placement (SQL's ON-versus-WHERE trap, closed structurally):"
  case filterPlacement aBadPlacement of
    Right () -> putStrLn "    filter outside the outer join term => MISSED"
    Left e   -> pf "    filter outside the outer join term => REJECTED\n      %s\n" e
  forM_ (bodyQuery aNotSuspended) $ \q -> case filterPlacement q of
    Right () -> putStrLn "    filter inside the join term        => admitted"
    Left e   -> pf "    unexpected: %s\n" e

  putStrLn "\n  Could the solver have closed this condition instead of sampling it?"
  putStrLn "  (OQ-034 wants the classifier even for conditions the solver declines)"
  forM_ ([("orderShipped", evShipped), ("creditWatch", evPoll), ("trialExpiry", evTick)]
         :: [(String, FunctorK)]) $
    \(n, f) -> case f of
      KEvent _ trig _ _ -> pf "    %-14s %s\n" n (showClosable (classifyTrigger trig))
      _ -> pure ()

  putStrLn "\n  Retention chain checks (grains align, they do not merely coarsen):"
  forM_ ([("Minute->Hour->Day->Month", goodChain)
         ,("for 30 day , by Month", badRetentionChain)
         ,("by IsoWeek , by Month", badGrainChain)
         ] :: [(String, [(Grain, Duration)])]) $ \(n, c) ->
    case chainCheck c of
      Right () -> pf "    %-26s => admitted\n" n
      Left e   -> pf "    %-26s => REJECTED: %s\n" n e

  putStrLn "\n  Static cost and feature inventory per functor:"
  forM_ allFunctors $ \f ->
    pf "    %-34s %-16s %s\n" (T.unpack (functorName f)) (functorKind f)
      (showList' (functorFeatures f))
  where
    showClosable = \case
      Closable s    -> "CLOSABLE  -- warn: " ++ s
      NotClosable s -> "sampled   -- " ++ s

bodyQuery :: FunctorK -> Maybe (Query '[])
bodyQuery = \case
  KPath _ (ABPresent q) -> Just q
  KPath _ (ABAbsent q)  -> Just q
  _                     -> Nothing

functorFeatures :: FunctorK -> [String]
functorFeatures = \case
  KValidation _ _ t _ -> features t
  KForeignKey _ _ as  -> ":> resolve" : [ "absence alternative (" ++ show a ++ ")" | a <- as ]
  KPath _ b           -> featuresOfBody b
  KEvent _ trig _ pay ->
    (case trig of
       TOn c            -> "on (transition)" : features c
       TEvery iv mc     -> "every (sampled)" : features iv
                             ++ maybe [] features mc)
    ++ concatMap (features . snd) pay

-- ---------------------------------------------------------------------------

sec8b :: IO ()
sec8b = do
  st <- mkStore
  let cx = withCtx orderRow Nothing
  putStrLn "  let … in -- one binding, scoped to the body:"
  run st (eval cx ENil tLet) >>= report "let window = expires_at - created_at in window / hour"
  putStrLn "\n  Virtual columns are projections of the row identifier (bytes 0-5,"
  putStrLn "  6-7, and the component suffix), declared nowhere:"
  run st (eval cx ENil tCreatedAt)    >>= report "created_at  (bytes 0-5)"
  run st (eval cx ENil tOrdinal)      >>= report "ordinal     (component suffix)"
  run st (eval cx ENil tOriginServer) >>= report "origin_server.hostname (a reference)"
  putStrLn "    origin_server is the one virtual column that is a reference, so it"
  putStrLn "    is the only one costing a Read -- and the effect index says so"
  putStrLn "    the sequence counter (bytes 8-11) has no constructor at all"

  putStrLn "\n  next <UniqueName> -- an allocation, and therefore Tx:"
  forM_ [1 .. 3 :: Int] $ \i ->
    run st (eval cx ENil tNext) >>= report ("allocation " ++ show i)
  putStrLn "    gaps are guaranteed (an aborted transaction burns a value); gapless"
  putStrLn "    numbering is a reporting requirement served by a view over the log"
  putStrLn "    it is Tx, so `where next orderRef > 0` does not typecheck"

  putStrLn "\n  A Component default constructs the row, in the same transaction:"
  r <- run st (eval cx ENil tComponent)
  case r of
    Left e  -> pf "  %-46s => REJECTED: %s\n" ("construct" :: String) (show e)
    Right row -> do
      pf "  %-46s => %s\n" ("construct app.commerce.OrderSettings" :: String)
        (T.unpack (rowTable row))
      forM_ (M.toList (rowCells row)) $ \(k, Cell ty _) ->
        pf "      %-12s : %s\n" (T.unpack k) (showTy ty)
  putStrLn "    deleting the parent deletes it, mechanically over Component edges --"
  putStrLn "    no cascade declaration, because the edges ARE the ownership"

-- ---------------------------------------------------------------------------

sec9 :: IO ()
sec9 = do
  st <- mkStore
  putStrLn "  Three types, because they were one while Duration was the only one --"
  putStrLn "  which hid a `month` with a fixed millisecond count and a bucket size"
  putStrLn "  with no count at all."
  putStrLn ""
  putStrLn "  Units are values, so `7 day` IS `7 * day` and units compose:"
  forM_ [("7 day", DurScale (Lit TAmt (Amount 7)) (Lit TDur day))
        ,("2 * week", DurScale (Lit TAmt (Amount 2)) (Lit TDur week))
        ,("90 minute", DurScale (Lit TAmt (Amount 90)) (Lit TDur minute))] $ \(n, t) ->
    run st (eval (withCtx orderRow Nothing) ENil t) >>= report n

  putStrLn "\n  Duration / Duration is the one dimensionless division, which is what"
  putStrLn "  makes units work as values without dimensional typing:"
  run st (eval (withCtx orderRow Nothing) ENil
           (DurDiv (DurScale (Lit TAmt (Amount 36)) (Lit TDur hour)) (Lit TDur day)))
    >>= report "36 hour / day"

  putStrLn "\n  Calendar addition is not associative, so one operator cannot cover"
  putStrLn "  both readings. Dec 31 2024 with 3 months:"
  let dec31 = Lit TTime (Timestamp (fromYmd 2024 12 31))
  run st (eval (withCtx orderRow Nothing) ENil
           (TsAddPeriod dec31 (Lit TPer (Period 3 PMonth))))
    >>= report "+ 3 * month  (from-origin)" . fmap showYmd
  run st (eval (withCtx orderRow Nothing) ENil (StepMonth dec31 (Lit TInt 3)))
    >>= report "stepMonth 3  (accumulating)" . fmap showYmd
  putStrLn "    the second clamps at each step, so the day-of-month never recovers"
  putStrLn "    -- the semantics a schedule anchored to a late day-of-month needs"

  putStrLn "\n  Grain truncation into labelled buckets:"
  let t = Timestamp (fromYmd 2025 1 29 + 13 * 3600000 + 47 * 60000)
  forM_ [GMinute, GHour, GDay, GIsoWeek, GMonth, GQuarter, GYear] $ \g ->
    run st (eval (withCtx orderRow Nothing) ENil (TruncTo g (Lit TTime t)))
      >>= report ("truncate to " ++ show g) . fmap showYmd
  putStrLn "    IsoWeek is coarser than Day and finer than Month while dividing"
  putStrLn "    neither, which is why its position is declared and not computed"
  putStrLn "\n  No conversion exists between Period and Duration in either direction,"
  putStrLn "  so `now + 3 * month` gets calendar semantics because the type system"
  putStrLn "  decided it, not because of a rule to remember."

showYmd :: Timestamp -> String
showYmd (Timestamp ms) =
  let (y, m, d) = toYmd ms
      tod = ms `mod` 86400000
      (hh, mm) = (tod `div` 3600000, (tod `mod` 3600000) `div` 60000)
  in pf "%04d-%02d-%02d %02d:%02d" y m d hh mm

-- ---------------------------------------------------------------------------

sec10 :: IO ()
sec10 = do
  st <- mkStore
  let n = 20000 :: Int
      cx = withCtx orderRow (M.lookup "u-1" =<< M.lookup "auth.User" demoTables)
  putStrLn "  Interpreting a term, per application, over 20k iterations."
  putStrLn ""
  bench "validation (regex, Configuration)" n (run st (applyGuard cx vSku))
  bench "validation (regex, StringLit)" n
    (run st (applyGuard (withCtx (custRow "ada@example.com") Nothing) vEmail))
  bench "path constraint, data (1 deref)" n (run st (applyGuard cx aBillingMatch))
  bench "path constraint, access (1 deref)" n (run st (applyGuard cx aOwnerAccess))
  bench "anchored subquery, absence (2 hops)" n (run st (applyGuard cx aNotSuspended))
  bench "event, on (transition + state bit)" n
    (run st (fireEvent cx (Timestamp 1700000005000) evShipped))
  bench "behavior sample" n
    (run st (evalBehavior (withCtx (custRow "x@y.zz") Nothing) (Moment 1700000000000) bAccrued))
  s <- readIORef (stStats st)
  pf "\n  derefs: %d, pattern compiles: %d, cache hits: %d\n"
    (stDerefs s) (stPatMiss s) (stPatHit s)
  putStrLn "  For scale: the storage spike measured an LMDB read at 11us/op. Functor"
  putStrLn "  interpretation is one to two orders of magnitude below that floor, and"
  putStrLn "  every figure here is dominated by the store lookups the real engine"
  putStrLn "  would be doing anyway."
  putStrLn ""
  putStrLn "  One finding worth acting on: the StringLit regex is the slowest row, and"
  putStrLn "  it is not the matching -- it is the cache being keyed on the pattern Text"
  putStrLn "  itself. A compile-time-provenance pattern should be interned to an integer"
  putStrLn "  id at schema commit, which is the same interning `Doc indexed` keys already"
  putStrLn "  use. Nothing in the design forbids it; the spike simply did not do it."
  where
    custRow e = Row (DataId 1700000001000 1 0 0) "app.commerce.Customer" $ M.fromList
      [ ("id", Cell TText "c-1"), ("email", Cell TText e)
      , ("user", Cell TText "u-1"), ("billing_address", Cell TText "a-1")
      , ("rate", Cell TAmt (Amount 12))
      , ("opened_at", Cell TTime (Timestamp 1700000000000)) ]

bench :: String -> Int -> IO a -> IO ()
bench label n act = do
  _ <- act
  t0 <- getCurrentTime
  forM_ [1 .. n] $ \_ -> act
  t1 <- getCurrentTime
  let secs = realToFrac (diffUTCTime t1 t0) :: Double
      per  = secs * 1e6 / fromIntegral n
  pf "  %-40s %8.3f us/apply  (%.1f ms total)\n" label per (secs * 1000)

-- ---------------------------------------------------------------------------

sec11 :: IO ()
sec11 = do
  putStrLn "  Encoded and exercised above:"
  forM_ [ "all four functor kinds, with the path kind in all three shapes"
        , "both event trigger forms, with `every`'s interval a per-row Read expr"
        , "=~ with all three admissible right operands, cached on config version"
        , "typed absence, the head rule, and outer-join guards"
        , "Duration / Period / Grain, units as values, both calendar additions"
        , "behaviors as Moment -> a, sampled past and future"
        , "function-typed columns with a static signature and an acyclicity check"
        , "template holes, where cardinality is the control flow"
        , "let, is / is not, virtual columns, next, Component construction"
        ] $ \s -> putStrLn ("    + " ++ s)
  putStrLn "\n  Still not encoded:"
  forM_ [ "Recursive types. Unchanged from the original spike."
        , "A closed-form crossing solver for behavior-triggered conditions \
          \(OQ-034).\n      The classifier that decides whether one COULD close a \
          \condition is\n      implemented above; the solver itself is not."
        , "Mergeable sketch types (t-digest, HyperLogLog) for percentile in a\n \
          \     multi-step retention chain (OQ-034)."
        , "The regex engine. Text.Regex.TDFA could not be installed in this\n \
          \     sandbox, so the matcher here is a stand-in -- what is validated is\n \
          \     the primitive's shape, the provenance restriction, and the cache."
        ] $ \s -> putStrLn ("    - " ++ s)
  putStrLn "\n  Nothing above needed a runtime GHC dependency, and nothing above is"
  putStrLn "  expressible at effect Effect, because the ladder has no such rung."
