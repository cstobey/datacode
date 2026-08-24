-- | The demo schema, written as DSL terms.
--
-- This is the schema from CLAUDE.md's quick reference, extended until it
-- exercises every construct the language has acquired since the original spike.
-- Each binding below is annotated with the surface syntax it encodes, so the
-- recorded run can be read against the grammar in docs/schema/railroad.md.
module Spike.Schema where

import Data.Text (Text)
import qualified Data.Map.Strict as M
import Spike.Core
import Spike.Eval

-- ---------------------------------------------------------------------------
-- Declared :> edges. The key declaration is also the sharding declaration, so
-- the shard family is what a rooted key reaches.

eCustomerUser, eCustomerAddr, eOrderCustomer, eOrderCourier, eOrderAddr,
  eSuspAccount, eMemberUser, eMemberProject, eProjectOwner, eOrderStyle :: Edge
eCustomerUser  = Edge "app.commerce.Customer" "user"            "auth.User"
eCustomerAddr  = Edge "app.commerce.Customer" "billing_address"  "app.commerce.Address"
eOrderCustomer = Edge "app.commerce.Order"    "customer"         "app.commerce.Customer"
eOrderCourier  = Edge "app.commerce.Order"    "courier"          "app.commerce.Courier"
eOrderAddr     = Edge "app.commerce.Order"    "bill_addr"        "app.commerce.Address"
eSuspAccount   = Edge "app.commerce.Suspension" "account"        "app.commerce.Customer"
eMemberUser    = Edge "app.commerce.Member"   "user"             "auth.User"
eMemberProject = Edge "app.commerce.Member"   "project"          "app.commerce.Project"
eProjectOwner  = Edge "app.commerce.Project"  "owner"            "app.commerce.Customer"
eOrderStyle    = Edge "app.commerce.Order"    "style"            "app.commerce.PriceStyle"

allEdges :: [Edge]
allEdges =
  [ eCustomerUser, eCustomerAddr, eOrderCustomer, eOrderCourier, eOrderAddr
  , eSuspAccount, eMemberUser, eMemberProject, eProjectOwner, eOrderStyle ]

-- | The Order shard family: what a rooted key can reach without crossing a
-- shard. Reference and Configuration tables do not participate.
orderFamily :: [Text]
orderFamily =
  [ "app.commerce.Order", "app.commerce.Customer", "app.commerce.Address"
  , "app.commerce.Suspension" ]

-- | An edge that is NOT in the family, used to show the crossing warning.
undeclaredEdge :: Edge
undeclaredEdge = Edge "app.commerce.Order" "warehouse" "logistics.Warehouse"

-- ---------------------------------------------------------------------------
-- 1. Validation functors

-- | @type Email : Text where isValidEmail@ — the pattern is a StringLit, so it
-- is checked at schema commit.
emailPattern :: PatSrc
emailPattern = PatLit "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z][A-Za-z]+$"

-- | The same rule sourced from a Reference row. A Reference insert /is/ a schema
-- commit, so this also resolves at compile time.
postalPattern :: PatSrc
postalPattern = PatRef "system.regex.UsPostal" "^[0-9][0-9][0-9][0-9][0-9](-[0-9][0-9][0-9][0-9])?$"

-- | @app.commerce.Customer.email@ — addressed by the field's path, which is also
-- the name of its computed type. No separate naming syntax.
vEmail :: FunctorK
vEmail = KValidation "app.commerce.Customer.email" TText
           (Lift (MatchK (Var TText IZ) emailPattern))
           "not a valid email address"

vPostal :: FunctorK
vPostal = KValidation "app.commerce.Address.postal_code" TText
            (Lift (MatchK (Var TText IZ) postalPattern))
            "not a valid US postal code"

-- | @sku : Text where =~ system.regex.SkuPattern.pattern@ — a Configuration
-- path, so it resolves at runtime and the compiled pattern is cached on the
-- config row version. Note the effect: this term is 'Read' and the two above
-- are 'Pure' lifted, and nothing said so — the index derived it from provenance.
vSku :: FunctorK
vSku = KValidation "app.commerce.Order.sku" TText
         (MatchC (Var TText IZ) "system.regex.SkuPattern.pattern")
         "sku does not match the configured pattern"

-- | @total : Amount = 0 where \\a -> a >= 0 ; isRoundedToCents@ — a
-- PredicateBlock is an indented run of predicates, implicitly conjoined.
vTotal :: FunctorK
vTotal = KValidation "app.commerce.Order.total" TAmt
           (Lift (And (Cmp OrdAmt CmpGe (Var TAmt IZ) (Lit TAmt (Amount 0)))
                      (Eq_ EqAmt False
                        (Arith NumAmt OpMul (Var TAmt IZ) (Lit TAmt (Amount 100)))
                        (Arith NumAmt OpMul (Var TAmt IZ) (Lit TAmt (Amount 100))))))
           "total must be non-negative and rounded to cents"

-- | On a @Secret@ field only the @a -> Bool@ signature is admissible, because
-- the other two can carry the value out into an error payload and thence into
-- the append-only log. The message here is a constant, not an expression over
-- the value — which is what 'KValidation' enforces by taking a 'Text'.
vPassword :: FunctorK
vPassword = KValidation "auth.Credential.password" TText
              (Lift (Cmp OrdInt CmpGe (Len (Var TText IZ)) (Lit TInt 12)))
              "password too short"

-- ---------------------------------------------------------------------------
-- 2. Foreign key functors

-- | @customer :> Customer@ — no absence alternative, so the edge must resolve.
fkCustomer :: FunctorK
fkCustomer = KForeignKey "app.commerce.Order.customer" eOrderCustomer []

-- | @courier :> Courier | NotDispatched@ — the head rule means only the first
-- variant decides the token, so one Null root serves both.
fkCourier :: FunctorK
fkCourier = KForeignKey "app.commerce.Order.courier" eOrderCourier [NotDispatched]

-- ---------------------------------------------------------------------------
-- 3. Path constraints
--
-- Four bodies, covering all three shapes and both varieties.

-- | @assert billingMatch { customer.billing_address == bill_addr }@ — an
-- expression body. Data constraint: no mention of the token.
aBillingMatch :: FunctorK
aBillingMatch = KPath "billingMatch" $ ABExpr $
  Eq_ EqText False
    (Proj TText "billing_address" (Deref "customer" Self))
    (Proj TText "bill_addr" Self)

-- | @assert ownerAccess { authed_user == customer.user }@ — an access
-- constraint, and the classifier reads that off @authed_user@ rather than off
-- the name.
aOwnerAccess :: FunctorK
aOwnerAccess = KPath "ownerAccess" $ ABExpr $
  Eq_ EqText False
    (Proj TText "id" AuthedUser)
    (Proj TText "user" (Deref "customer" Self))

-- | @assert memberAccess { self >< Project >< Member >< authed_user }@ — a
-- query in assert position asserts its result is non-empty. The token enters as
-- a join term, so the equality /is/ the join and no comparison is written.
aMemberAccess :: FunctorK
aMemberAccess = KPath "memberAccess" $ ABPresent $
  QFilter
    (QJoin (QJoin (QJoin (QSelf "app.commerce.Order") eOrderCustomer Forward Nothing)
                  eProjectOwner Reverse (Just "project"))
           eMemberProject Reverse (Just "member"))
    (Eq_ EqText False (Proj TText "user" Self) (Proj TText "id" AuthedUser))

-- | @assert notSuspended { not $ self >< (Suspension where lifted is NotLifted) }@
-- — `not` of a query asserts it is empty. The filter sits inside the join term.
aNotSuspended :: FunctorK
aNotSuspended = KPath "notSuspended" $ ABAbsent $
  QFilter
    (QJoin (QJoin (QSelf "app.commerce.Order") eOrderCustomer Forward Nothing)
           eSuspAccount Reverse (Just "suspension"))
    (Lift (Is False "NotLifted" (Proj TVar "lifted" Self)))

-- | An access assert with a conjunct that does not mention the token. It is
-- bypassed along with the rest, which is almost never intended, so schema
-- commit warns and names it.
aMixedAccess :: FunctorK
aMixedAccess = KPath "mixedAccess" $ ABExpr $
  And (Eq_ EqText False (Proj TText "id" AuthedUser)
                        (Proj TText "user" (Deref "customer" Self)))
      (Is False "Cancelled" (Proj TVar "status" Self))

-- | The same query written with the filter outside the outer join term — the
-- SQL ON-versus-WHERE trap, which inverts what the assert reads as.
aBadPlacement :: Query '[]
aBadPlacement =
  QFilter
    (QOuter (QSelf "app.commerce.Order") eSuspAccount Reverse NoSuspension (Just "suspension"))
    (Lift (Is False "NotLifted" (Proj TVar "lifted" Self)))

-- | An assert reaching outside the shard family. Anchoring bounds work; it does
-- not buy locality, so this one cannot be @enforce always@.
aCrossShard :: FunctorK
aCrossShard = KPath "warehouseStocked" $ ABPresent $
  QJoin (QSelf "app.commerce.Order") undeclaredEdge Forward Nothing

-- ---------------------------------------------------------------------------
-- 4. Event functors — both trigger forms

-- | @on status is Shipped emit app.events.EmailQueue { recipient = customer.email }@
evShipped :: FunctorK
evShipped = KEvent "orderShipped"
  (TOn (Lift (Is False "Shipped" (Proj TVar "status" Self))))
  "app.events.EmailQueue"
  [ ("recipient", Proj TText "email" (Deref "customer" Self))
  , ("order_num", Lift (Proj TText "id" Self))
  ]

-- | @every poll_interval emit app.events.SyncQueue { … } where balance >= credit_limit@
-- The interval is a field of the row, not a literal — one production covers a
-- LengthLit, a field, and a Configuration path, which is why no interval
-- override mechanism was needed.
evPoll :: FunctorK
evPoll = KEvent "creditWatch"
  (TEvery (Lift (Proj TDur "poll_interval" Self))
          (Just (Cmp OrdAmt CmpGe
                   (Proj TAmt "balance" (Deref "customer" Self))
                   (Proj TAmt "credit_limit" (Deref "customer" Self)))))
  "app.events.SyncQueue"
  [ ("customer", Lift (Proj TText "customer" Self)) ]

-- | @every 15 minute emit …@ — a literal interval, and a condition the solver
-- could have closed. This is the case schema commit warns about.
evTick :: FunctorK
evTick = KEvent "trialExpiry"
  (TEvery (Lift (DurScale (Lit TAmt (Amount 15)) (Lit TDur minute)))
          (Just (Lift (Cmp OrdTime CmpGe (Proj TTime "expires_at" Self)
                                         (Proj TTime "placed_at" Self)))))
  "app.events.SyncQueue"
  [ ("order", Lift (Proj TText "id" Self)) ]

-- ---------------------------------------------------------------------------
-- Behaviors
--
-- @accrued : Behavior Amount = \\m -> rate * (m - opened_at) / day@
-- Read, one parameter, always Moment. Nothing is stored and no clock is read.

bAccrued :: Behavior Amount
bAccrued = Behavior $ Lift $
  Arith NumAmt OpMul
    (Proj TAmt "rate" Self)
    (DurDiv (MomDiff (Var TMom IZ) (Proj TTime "opened_at" Self)) (Lit TDur day))

-- ---------------------------------------------------------------------------
-- Function-typed columns
--
-- @type Renderer = Amount -> Read Text@, and a field naming it. A field may not
-- write an arrow inline, which is what makes "every function in this column
-- shares one signature" a property of what the field is.

fnMoney :: SomeFn
fnMoney = SomeFn TAmt TText "money" $
  Lift (Concat (Lit TText "$") (ShowAmt (Var TAmt IZ)))

fnRegistry :: M.Map Text SomeFn
fnRegistry = M.fromList [("money", fnMoney), ("plain", fnPlain)]

fnPlain :: SomeFn
fnPlain = SomeFn TAmt TText "plain" (Lift (ShowAmt (Var TAmt IZ)))

-- | Reading a function column and calling it. A literal is admissible only on a
-- Reference table; a Configuration table admits a FunctorRef and no literal —
-- code by schema, selection-among-code by data.
callStyle :: Term '[] 'Read Text
callStyle = CallFn TAmt TText
  (Proj (TFun TAmt TText) "render" (Deref "style" Self))
  (Proj TAmt "total" Self)

-- | The call graph must be acyclic, which is decidable because it lives in the
-- schema graph.
goodCallGraph, badCallGraph :: [(Text, [Text])]
goodCallGraph = [("money", ["round2"]), ("round2", []), ("plain", [])]
badCallGraph  = [("money", ["round2"]), ("round2", ["fmt"]), ("fmt", ["money"])]

-- ---------------------------------------------------------------------------
-- let, virtual columns, next, and Component construction

-- | @let window = expires_at - created_at in window / hour@ — one binding,
-- Haskell-shaped, scoped to the body.
tLet :: Term '[] 'Read Amount
tLet = Lift $
  Let TDur (TsDiff (Proj TTime "expires_at" Self) (VCreatedAt Self))
           (DurDiv (Var TDur IZ) (Lit TDur hour))

-- | The virtual columns are projections of the row identifier, which is what
-- makes created_at an instance of a rule rather than a special case.
tCreatedAt :: Term '[] 'Read Timestamp
tCreatedAt = Lift (VCreatedAt Self)

tOrdinal :: Term '[] 'Read Int
tOrdinal = Lift (VOrdinal Self)

-- | origin_server resolves through Node's candidate key rather than a DataId,
-- and is the only virtual column that is a reference — hence the Read.
tOriginServer :: Term '[] 'Read Text
tOriginServer = Proj TText "hostname" (VOriginSrv Self)

-- | @order_num : Int = next orderRef@ — an allocation, not a value. The scope of
-- the sequence is the scope of the uniqueness it serves: @unique orderRef
-- { customer, order_num }@ has a per-customer counter living with the customer
-- row, so it is a local read-modify-write in a shard the transaction already
-- touches.
tNext :: Term '[] 'Tx Int
tNext = Next "orderRef"

-- | @settings :> Settings : Component = { theme = Dark, digest = 7 day }@ —
-- the sub-table body is the constructor, so the row exists whenever its parent
-- does with no trigger machinery.
tComponent :: Term '[] 'Tx Row
tComponent = Construct "app.commerce.OrderSettings"
  [ ("theme",  Field TVar (Lift (Lit TVar (Variant "Dark" Nothing))))
  , ("digest", Field TDur (Lift (DurScale (Lit TAmt (Amount 7)) (Lit TDur day))))
  , ("seq",    Field TInt (Next "orderRef"))
  ]

-- ---------------------------------------------------------------------------
-- Templates
--
-- Cardinality is the control flow. The third hole is the conditional: its query
-- returns zero rows for an undispatched order, so nothing renders and no `if`
-- was needed.

orderTemplate :: Template
orderTemplate = Template "app.templates.OrderLine" ", "
  [ PText "Order "
  , PHole (QSelf "app.commerce.Order") Nothing
  , PText " for "
  , PHole (QJoin (QSelf "app.commerce.Order") eOrderCustomer Forward Nothing)
          (Just "customerCard")
  , PText " courier="
  , PHole (QJoin (QSelf "app.commerce.Order") eOrderCourier Forward Nothing) Nothing
  ]

-- ---------------------------------------------------------------------------
-- Retention chains

goodChain, badGrainChain, badRetentionChain :: [(Grain, Duration)]
goodChain         = [(GMinute, Duration (7 * 86400000)), (GHour, Duration (90 * 86400000)),
                     (GDay, Duration (366 * 86400000)), (GMonth, Duration (5 * 366 * 86400000))]
-- `for 30 day , by Month` — Month is 28-31 days, so the check is against the
-- successor's maximum span and this is rejected.
badRetentionChain = [(GDay, Duration (30 * 86400000)), (GMonth, Duration (366 * 86400000))]
-- `by IsoWeek , by Month` — the week of January 29 straddles two months, so
-- merging across it would put a bucket in a month it is only partly inside.
badGrainChain     = [(GIsoWeek, Duration (366 * 86400000)), (GMonth, Duration (1830 * 86400000))]

-- ---------------------------------------------------------------------------
-- Data

demoTables :: M.Map Text (M.Map Text Row)
demoTables = M.fromList
  [ ("auth.User", tableOf
      [ mkRow "auth.User" "u-1" 1700000000000 1 [("name", Cell TText "Ada")]
      , mkRow "auth.User" "u-2" 1700000000000 1 [("name", Cell TText "Grace")]
      ])
  , ("app.commerce.Address", tableOf
      [ mkRow "app.commerce.Address" "a-1" 1700000000000 1
          [("postal_code", Cell TText "80301")]
      , mkRow "app.commerce.Address" "a-2" 1700000000000 2
          [("postal_code", Cell TText "80301-1234")]
      ])
  , ("app.commerce.Customer", tableOf
      [ mkRow "app.commerce.Customer" "c-1" 1700000001000 1
          [ ("user", Cell TText "u-1")
          , ("email", Cell TText "ada@example.com")
          , ("billing_address", Cell TText "a-1")
          , ("balance", Cell TAmt (Amount 500))
          , ("credit_limit", Cell TAmt (Amount 400))
          , ("rate", Cell TAmt (Amount 12))
          , ("opened_at", Cell TTime (Timestamp 1700000000000))
          ]
      ])
  , ("app.commerce.Courier", tableOf
      [ mkRow "app.commerce.Courier" "k-1" 1700000000000 1 [("name", Cell TText "DHL")] ])
  , ("app.commerce.PriceStyle", tableOf
      [ mkRow "app.commerce.PriceStyle" "s-1" 1700000000000 1
          [("render", Cell (TFun TAmt TText) (FunctorRef "money" "Amount -> Read Text"))]
      , mkRow "app.commerce.PriceStyle" "s-2" 1700000000000 1
          [("render", Cell (TFun TAmt TText) (FunctorRef "nosuch" "Amount -> Read Text"))]
      ])
  , ("app.commerce.Project", tableOf
      [ mkRow "app.commerce.Project" "p-1" 1700000000000 1 [("owner", Cell TText "c-1")] ])
  , ("app.commerce.Member", tableOf
      [ mkRow "app.commerce.Member" "m-1" 1700000000000 1
          [("project", Cell TText "p-1"), ("user", Cell TText "u-1")] ])
  , ("app.commerce.Suspension", tableOf
      [ mkRow "app.commerce.Suspension" "s-lifted" 1700000000000 1
          [("account", Cell TText "c-1"), ("lifted", Cell TVar (Variant "Lifted" Nothing))]
      ])
  , ("system.shards.Node", tableOf
      [ mkRow "system.shards.Node" "1" 0 1 [("hostname", Cell TText "node-a")]
      , mkRow "system.shards.Node" "2" 0 1 [("hostname", Cell TText "node-b")]
      ])
  , ("app.commerce.Order", tableOf [ orderRow ])
  ]

orderRow :: Row
orderRow = mkRow "app.commerce.Order" "o-1" 1700000002000 1
  [ ("customer",   Cell TText "c-1")
  , ("courier",    Cell TText "k-1")
  , ("bill_addr",  Cell TText "a-1")
  , ("style",      Cell TText "s-1")
  , ("status",     Cell TVar (Variant "Pending" Nothing))
  , ("total",      Cell TAmt (Amount 99.99))
  , ("sku",        Cell TText "SKU-4471")
  , ("placed_at",  Cell TTime (Timestamp 1700000002000))
  , ("expires_at", Cell TTime (Timestamp 1702592002000))  -- created_at + 30 day
  , ("poll_interval", Cell TDur (Duration 30000))
  ]

-- | The same order, shipped, with a mismatched billing address and an
-- undispatched courier — used to show each functor kind failing.
orderShipped :: Row
orderShipped = orderRow
  { rowCells = M.union
      (M.fromList [ ("status", Cell TVar (Variant "Shipped" Nothing)) ])
      (rowCells orderRow) }

demoConfig :: M.Map Text (Text, Int)
demoConfig = M.fromList
  [ ("system.regex.SkuPattern.pattern", ("^SKU-[0-9][0-9][0-9][0-9]$", 1)) ]

demoRefs :: M.Map Text Text
demoRefs = M.fromList [ ("system.regex.UsPostal", patText postalPattern) ]

mkStore :: IO Store
mkStore = newStore allEdges demoTables demoConfig demoRefs fnRegistry

allFunctors :: [FunctorK]
allFunctors =
  [ vEmail, vPostal, vSku, vTotal, vPassword
  , fkCustomer, fkCourier
  , aBillingMatch, aOwnerAccess, aMemberAccess, aNotSuspended, aMixedAccess
  , evShipped, evPoll, evTick
  ]
