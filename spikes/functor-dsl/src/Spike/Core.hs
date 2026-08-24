-- | The DSL itself: an effect-indexed GADT over a typed de Bruijn context.
--
-- Three indices carry the whole design:
--
--   * @ctx@ — the typed variable context. Lambda binding pushes; 'Var' can only name a
--     slot that exists, at the type it was bound with. An unbound or mistyped variable is
--     not a runtime error, it is unrepresentable.
--   * @e@   — the effect, one of 'Pure', 'Read', 'Tx'. There is deliberately no @Effect@
--     rung: the absence of the constructor /is/ the missing @Effect a -> Tx a@ lift.
--   * @a@   — the Haskell carrier of the DataCode type. 'Concat' takes two @Text@ terms,
--     so the old spike's "concatenate an error message with an Int" bug is a type error.
module Spike.Core where

import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)

-- ---------------------------------------------------------------------------
-- The effect ladder
--
-- Pure ⊂ Read ⊂ Tx, with Effect outside the chain and unreachable from inside
-- the DSL. `Effect` is not a constructor here, and that is the point: there is
-- nothing to write that would produce one.

data Eff = Pure | Read | Tx

-- | Least upper bound. Combining two subterms takes the stronger effect.
type Lub :: Eff -> Eff -> Eff
type family Lub a b where
  Lub 'Pure b     = b
  Lub a     'Pure = a
  Lub 'Read 'Read = 'Read
  Lub 'Read 'Tx   = 'Tx
  Lub 'Tx   'Read = 'Tx
  Lub 'Tx   'Tx   = 'Tx

-- | @Sub e f@ — a term of effect @e@ is admissible where @f@ is required.
--
-- Note what is absent: @Sub 'Tx 'Read@. A @Tx@ term (a sequence allocation, a
-- component construction) cannot be lifted into a validation, an assert, a
-- behavior, or a template hole, all of which demand 'Read'. And since 'Eff' has
-- no @Effect@ rung, no instance can mention one.
class Sub (e :: Eff) (f :: Eff)
instance Sub 'Pure 'Pure
instance Sub 'Pure 'Read
instance Sub 'Pure 'Tx
instance Sub 'Read 'Read
instance Sub 'Read 'Tx
instance Sub 'Tx   'Tx

data SEff (e :: Eff) where
  SPure :: SEff 'Pure
  SRead :: SEff 'Read
  STx   :: SEff 'Tx

showEff :: SEff e -> String
showEff = \case { SPure -> "Pure"; SRead -> "Read"; STx -> "Tx" }

-- ---------------------------------------------------------------------------
-- Domain carriers
--
-- Units are values, not conversion functions, and the canonical Duration unit
-- is the millisecond. Duration / Period / Grain are three types with no
-- conversion between the first two in either direction.

newtype Amount    = Amount Rational       deriving (Eq, Ord)
newtype Duration  = Duration Integer      deriving (Eq, Ord)  -- milliseconds
newtype Timestamp = Timestamp Integer     deriving (Eq, Ord)  -- ms since epoch, stored
newtype Moment    = Moment Integer        deriving (Eq, Ord)  -- observation, past or future

data PeriodUnit = PMonth | PQuarter | PYear deriving (Eq, Ord, Show)
data Period     = Period Int PeriodUnit     deriving (Eq, Ord, Show)

-- | Buckets, not widths. Alignment is declared (see 'grainParent'), never computed
-- from a millisecond count, which is what makes IsoWeek's position decidable.
data Grain = GMinute | GHour | GDay | GIsoWeek | GMonth | GQuarter | GYear | GIsoYear
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The alignment forest. Two roots, because ISO weeks tile ISO years and tile
-- nothing on the calendar side.
grainParent :: Grain -> Maybe Grain
grainParent = \case
  GMinute  -> Just GHour
  GHour    -> Just GDay
  GDay     -> Just GMonth          -- calendar side
  GMonth   -> Just GQuarter
  GQuarter -> Just GYear
  GYear    -> Nothing
  GIsoWeek -> Just GIsoYear        -- ISO side
  GIsoYear -> Nothing

instance Show Amount where
  show (Amount r) = show (fromRational r :: Double)
instance Show Duration where
  show (Duration ms) = show ms ++ "ms"
instance Show Timestamp where
  show (Timestamp ms) = "t" ++ show ms
instance Show Moment where
  show (Moment ms) = "@" ++ show ms

-- | Duration constants. Unit names are constants, so @7 day@ desugars to
-- @7 * day@ and no unit name is ever bound in the plural.
day, hour, minute, second, milli, week :: Duration
milli  = Duration 1
second = Duration 1000
minute = Duration 60000
hour   = Duration 3600000
day    = Duration 86400000
week   = Duration 604800000

-- | The row identifier. The virtual columns are projections of these bytes,
-- which is why @created_at@ is an instance of a rule and not a special case.
data DataId = DataId
  { didCreatedAt    :: Integer   -- bytes 0-5
  , didOriginServer :: Int       -- bytes 6-7
  , didSequence     :: Int       -- bytes 8-11, deliberately not exposed in the DSL
  , didOrdinal      :: Int       -- component suffix
  } deriving (Eq, Ord, Show)

-- | Absence is a typed ADT extending Null. There is no NULL, so the /reason/
-- for absence is in the type.
data Absence
  = NotFound | NotGiven | Redacted
  | MissingCustomer | NotDispatched | NoSuspension
  deriving (Eq, Show)

data Nullable a = Present a | Absent Absence deriving (Eq, Show)

-- | A sum-type value. @is@ matches the constructor and ignores the payload;
-- @==@ compares both.
data Variant = Variant { vCtor :: Text, vPayload :: Maybe Text } deriving (Eq, Show)

-- | A stored DSL term used as a column value. Storage is unchanged from an
-- ordinary FunctorRef; what is new is that the signature is known statically,
-- which the phantom @(a -> b)@ carries.
data FunctorRef f = FunctorRef { frName :: Text, frSig :: Text } deriving (Eq, Show)

data Row = Row { rowId :: DataId, rowTable :: Text, rowCells :: Map Text Cell }

-- | An erased cell, as the storage layer hands it over. 'Proj' carries a 'Ty'
-- witness and the cast is checked once per access here; in production the row
-- decoder is generated from the schema node, so the check happens at decode.
data Cell where
  Cell :: Ty a -> a -> Cell

-- ---------------------------------------------------------------------------
-- Type witnesses

data Ty a where
  TInt   :: Ty Int
  TText  :: Ty Text
  TBool  :: Ty Bool
  TAmt   :: Ty Amount
  TDur   :: Ty Duration
  TPer   :: Ty Period
  TGrain :: Ty Grain
  TTime  :: Ty Timestamp
  TMom   :: Ty Moment
  TRow   :: Ty Row
  TVar   :: Ty Variant
  TNull  :: Ty a -> Ty (Nullable a)
  TFun   :: Ty a -> Ty b -> Ty (FunctorRef (a -> b))

showTy :: Ty a -> String
showTy = \case
  TInt -> "Int"; TText -> "Text"; TBool -> "Bool"; TAmt -> "Amount"
  TDur -> "Duration"; TPer -> "Period"; TGrain -> "Grain"
  TTime -> "Timestamp"; TMom -> "Moment"; TRow -> "Row"; TVar -> "Variant"
  TNull t -> showTy t ++ " | Null"
  TFun a b -> showTy a ++ " -> " ++ showTy b

sameTy :: Ty a -> Ty b -> Maybe (a -> b)
sameTy TInt   TInt   = Just id
sameTy TText  TText  = Just id
sameTy TBool  TBool  = Just id
sameTy TAmt   TAmt   = Just id
sameTy TDur   TDur   = Just id
sameTy TPer   TPer   = Just id
sameTy TGrain TGrain = Just id
sameTy TTime  TTime  = Just id
sameTy TMom   TMom   = Just id
sameTy TRow   TRow   = Just id
sameTy TVar   TVar   = Just id
sameTy (TNull a) (TNull b) = fmap fmapNull (sameTy a b)
  where fmapNull f = \case { Present x -> Present (f x); Absent r -> Absent r }
-- A FunctorRef is phantom in its signature, so matching the two witnesses is
-- enough to re-tag a stored one. This is the only cast a function column needs,
-- and it is why a function-typed column is "mostly a typing change".
sameTy (TFun a b) (TFun c d)
  | Just _ <- sameTy a c, Just _ <- sameTy b d = Just (\(FunctorRef n s) -> FunctorRef n s)
sameTy _ _ = Nothing

-- | Equality witness. There is no instance for a function type, so @==@,
-- @unique@, @order by@, @group by@, @indexed@, a candidate key, and a field
-- @where@ are all closed against function-typed columns by typing rather than
-- by a rule to remember.
data EqT a where
  EqInt  :: EqT Int
  EqText :: EqT Text
  EqBool :: EqT Bool
  EqAmt  :: EqT Amount
  EqDur  :: EqT Duration
  EqTime :: EqT Timestamp
  EqVar  :: EqT Variant

eqWith :: EqT a -> a -> a -> Bool
eqWith = \case
  EqInt -> (==); EqText -> (==); EqBool -> (==); EqAmt -> (==)
  EqDur -> (==); EqTime -> (==); EqVar -> (==)

-- | Ordering witness, likewise absent for function types and for 'Row'.
data OrdT a where
  OrdInt  :: OrdT Int
  OrdAmt  :: OrdT Amount
  OrdDur  :: OrdT Duration
  OrdTime :: OrdT Timestamp
  OrdText :: OrdT Text

cmpWith :: OrdT a -> a -> a -> Ordering
cmpWith = \case
  OrdInt -> compare; OrdAmt -> compare; OrdDur -> compare
  OrdTime -> compare; OrdText -> compare

-- | Numeric witness. Note there is no @NumT Period@: a Period is Int-scaled and
-- has no millisecond count, so it never enters ordinary arithmetic.
data NumT a where
  NumInt :: NumT Int
  NumAmt :: NumT Amount

data ArithOp = OpAdd | OpSub | OpMul deriving (Eq, Show)

applyArith :: NumT a -> ArithOp -> a -> a -> a
applyArith NumInt op a b = case op of
  OpAdd -> a + b; OpSub -> a - b; OpMul -> a * b
applyArith NumAmt op (Amount a) (Amount b) = Amount $ case op of
  OpAdd -> a + b; OpSub -> a - b; OpMul -> a * b

data CmpOp = CmpLt | CmpLe | CmpGt | CmpGe deriving (Eq, Show)

applyCmp :: CmpOp -> Ordering -> Bool
applyCmp op o = case op of
  CmpLt -> o == LT
  CmpLe -> o /= GT
  CmpGt -> o == GT
  CmpGe -> o /= LT

-- ---------------------------------------------------------------------------
-- Regex: provenance is what the type records
--
-- The right operand of =~ is restricted by trait to a string literal, a
-- Reference path, or a Configuration path. The first two resolve at compile
-- time; the third resolves at runtime against a Configuration row, so the
-- compiled-pattern cache is keyed on that row's version. Two constructors
-- rather than one, so the effect index /derives/ the difference from
-- provenance instead of restating it.

data PatSrc
  = PatLit Text            -- ^ StringLit — checked at schema commit
  | PatRef Text Text       -- ^ Reference path and the pattern interned there;
                           --   a Reference insert /is/ a schema commit
  deriving (Eq, Show)

patText :: PatSrc -> Text
patText (PatLit p)   = p
patText (PatRef _ p) = p

patProvenance :: PatSrc -> String
patProvenance (PatLit _)   = "StringLit (compile time)"
patProvenance (PatRef q _) = "Reference " ++ T.unpack q ++ " (compile time)"

-- ---------------------------------------------------------------------------
-- Typed de Bruijn index into the context

data Idx (ctx :: [Type]) a where
  IZ :: Idx (a ': ctx) a
  IS :: Idx ctx a -> Idx (b ': ctx) a

idxLevel :: Idx ctx a -> Int
idxLevel IZ     = 0
idxLevel (IS i) = 1 + idxLevel i

data Env (ctx :: [Type]) where
  ENil  :: Env '[]
  ECons :: a -> Env ctx -> Env (a ': ctx)

lookupEnv :: Idx ctx a -> Env ctx -> a
lookupEnv IZ     (ECons x _)  = x
lookupEnv (IS i) (ECons _ xs) = lookupEnv i xs

-- ---------------------------------------------------------------------------
-- Queries
--
-- An assert body, a template hole, and a behavior all share this. Every one is
-- rooted at `self` and reaches only along declared :> edges, in either
-- direction — which is what bounds the work an access assert does on a read.

data Dir = Forward | Reverse deriving (Eq, Show)

data Edge = Edge
  { edFrom  :: Text          -- ^ table the edge leaves
  , edField :: Text          -- ^ the :> field naming it
  , edTo    :: Text          -- ^ table it points at
  } deriving (Eq, Ord, Show)

data Query (ctx :: [Type]) where
  -- | Rooted at the subject row. There is no unrooted constructor, so an
  -- unanchored source is not a diagnostic — it cannot be written.
  QSelf   :: Text -> Query ctx
  QJoin   :: Query ctx -> Edge -> Dir -> Maybe Text -> Query ctx
  -- | A filter carried /inside/ the join term. Filter-before-guard.
  QFilter :: Query ctx -> Term ctx 'Read Bool -> Query ctx
  -- | An outer join with a Null-derived catch-all; degenerates a derived key
  -- when a key column comes from the outer side.
  QOuter  :: Query ctx -> Edge -> Dir -> Absence -> Maybe Text -> Query ctx

queryRoot :: Query ctx -> Text
queryRoot = \case
  QSelf t          -> t
  QJoin q _ _ _    -> queryRoot q
  QFilter q _      -> queryRoot q
  QOuter q _ _ _ _ -> queryRoot q

-- ---------------------------------------------------------------------------
-- The term

data Term (ctx :: [Type]) (e :: Eff) a where
  -- Literals and unit constants are Pure.
  Lit    :: Ty a -> a -> Term ctx 'Pure a
  -- | The ladder's lifting, made explicit so it stays inspectable.
  Lift   :: Sub e f => Term ctx e a -> Term ctx f a

  -- Variables and binding. There is no @Lam@ producing a Haskell arrow: a DSL
  -- function is a /term in a context of its parameters/ ('Fn' below), applied
  -- by extending the environment. That keeps every function inspectable, which
  -- a Haskell closure would not be.
  Var    :: Ty a -> Idx ctx a -> Term ctx 'Pure a
  Let    :: Ty a -> Term ctx e1 a -> Term (a ': ctx) e2 b -> Term ctx (Lub e1 e2) b
  If     :: Term ctx e1 Bool -> Term ctx e2 a -> Term ctx e2 a -> Term ctx (Lub e1 e2) a

  -- Rows. `self` is in hand, so projecting it computes nothing.
  Self       :: Term ctx 'Pure Row
  -- | The requesting token, a full User row rather than an id. Mentioning it is
  -- what makes an assert an access constraint — read off the body, never the name.
  AuthedUser :: Term ctx 'Read Row
  Proj       :: Ty a -> Text -> Term ctx e Row -> Term ctx e a
  -- | Following a :> edge resolves a DataId to a row, so it is Read.
  Deref      :: Text -> Term ctx e Row -> Term ctx (Lub e 'Read) Row

  -- Virtual columns: projections of the row identifier.
  VCreatedAt :: Term ctx e Row -> Term ctx e Timestamp
  VOrdinal   :: Term ctx e Row -> Term ctx e Int
  -- | origin_server is the one virtual column that is a reference, so unlike
  -- the others it costs a Read.
  VOriginSrv :: Term ctx e Row -> Term ctx (Lub e 'Read) Row

  -- Arithmetic
  Arith  :: NumT a -> ArithOp -> Term ctx e1 a -> Term ctx e2 a -> Term ctx (Lub e1 e2) a
  -- | The one division that yields a dimensionless number. This is what lets
  -- units work as values without dimensional typing.
  DurDiv :: Term ctx e1 Duration -> Term ctx e2 Duration -> Term ctx (Lub e1 e2) Amount
  -- | @7 day@ — NumLit Ident desugars to multiplication, so units compose.
  DurScale :: Term ctx e1 Amount -> Term ctx e2 Duration -> Term ctx (Lub e1 e2) Duration
  TsDiff :: Term ctx e1 Timestamp -> Term ctx e2 Timestamp -> Term ctx (Lub e1 e2) Duration
  -- | The observation moment less a stored timestamp. Distinct from 'TsDiff'
  -- because Moment and Timestamp are distinct types: one ranges over past and
  -- future, the other is a value in a row.
  MomDiff :: Term ctx e1 Moment -> Term ctx e2 Timestamp -> Term ctx (Lub e1 e2) Duration
  -- | Calendar addition, from-origin: Dec 31 + 3 * month = Mar 31.
  TsAddPeriod :: Term ctx e1 Timestamp -> Term ctx e2 Period -> Term ctx (Lub e1 e2) Timestamp
  -- | Accumulating one month at a time with a clamp at each step, so the
  -- day-of-month never recovers. Calendar addition is not associative, which is
  -- why one operator cannot cover both readings.
  StepMonth :: Term ctx e1 Timestamp -> Term ctx e2 Int -> Term ctx (Lub e1 e2) Timestamp
  TruncTo :: Grain -> Term ctx e Timestamp -> Term ctx e Timestamp

  -- Comparison and logic
  Eq_    :: EqT a -> Bool -> Term ctx e1 a -> Term ctx e2 a -> Term ctx (Lub e1 e2) Bool
  Cmp    :: OrdT a -> CmpOp -> Term ctx e1 a -> Term ctx e2 a -> Term ctx (Lub e1 e2) Bool
  -- | @is@ / @is not@ — constructor match ignoring payload.
  Is     :: Bool -> Text -> Term ctx e Variant -> Term ctx e Bool
  And    :: Term ctx e1 Bool -> Term ctx e2 Bool -> Term ctx (Lub e1 e2) Bool
  Or     :: Term ctx e1 Bool -> Term ctx e2 Bool -> Term ctx (Lub e1 e2) Bool
  Not    :: Term ctx e Bool -> Term ctx e Bool

  -- Text. Both operands of Concat are Text, which is what makes the old spike's
  -- "error message ++ Int" bug a compile error rather than a wrong answer.
  Len    :: Term ctx e Text -> Term ctx e Int
  Concat :: Term ctx e1 Text -> Term ctx e2 Text -> Term ctx (Lub e1 e2) Text
  Lower  :: Term ctx e Text -> Term ctx e Text
  -- | Formatting is an ordinary function, which is why templates have no
  -- filters and no pipes.
  ShowAmt :: Term ctx e Amount -> Term ctx e Text

  -- | =~ against a pattern fixed at schema commit.
  MatchK :: Term ctx e Text -> PatSrc -> Term ctx e Bool
  -- | =~ against a Configuration path. Resolves at runtime, so it is Read, and
  -- the cache is keyed on the config row version.
  MatchC :: Term ctx e Text -> Text -> Term ctx (Lub e 'Read) Bool

  -- Typed absence
  IsAbsent :: Term ctx e (Nullable a) -> Term ctx e Bool
  Reason   :: Term ctx e (Nullable a) -> Term ctx e Variant
  OrElse   :: Term ctx e1 (Nullable a) -> Term ctx e2 a -> Term ctx (Lub e1 e2) a

  -- | A query standing in boolean position asserts its result is non-empty.
  -- @Not (Exists q)@ asserts it is empty. No quantifier keyword is needed.
  Exists :: Query ctx -> Term ctx 'Read Bool
  Count  :: Query ctx -> Term ctx 'Read Int

  -- | @next <UniqueName>@. A Tx allocation, not a value — and because there is
  -- no @Sub 'Tx 'Read@, it cannot appear in a where, a behavior, or a hole.
  Next :: Text -> Term ctx 'Tx Int
  -- | A Component default constructs the row, in the same transaction.
  Construct :: Text -> [(Text, Field ctx)] -> Term ctx 'Tx Row

  -- | A stored function-typed column value.
  FnLit  :: Ty a -> Ty b -> Text -> Term ctx 'Pure (FunctorRef (a -> b))
  -- | Calling one costs a Read: the referenced term has to be fetched and
  -- interpreted. The witnesses are what let the fetched term be checked against
  -- the column's declared signature.
  CallFn :: Ty a -> Ty b -> Term ctx e1 (FunctorRef (a -> b)) -> Term ctx e2 a
         -> Term ctx (Lub 'Read (Lub e1 e2)) b

data Field (ctx :: [Type]) where
  Field :: Ty a -> Term ctx 'Tx a -> Field ctx

-- | A user-defined function: a term in a context of its parameter. Applying it
-- extends the environment rather than building a Haskell closure, so the body
-- stays a value the optimizer and the IDE can walk.
data Fn a b = Fn
  { fnName  :: Text
  , fnParam :: Ty a
  , fnRet   :: Ty b
  , fnBody  :: Term '[a] 'Read b
  }

data SomeFn where
  SomeFn :: Ty a -> Ty b -> Text -> Term '[a] 'Read b -> SomeFn

fnSig :: Ty a -> Ty b -> String
fnSig a b = showTy a ++ " -> Read " ++ showTy b

-- ---------------------------------------------------------------------------
-- Behaviors
--
-- Behavior a ≅ Moment -> a. Exactly one parameter, always Moment, because two
-- behaviors compose pointwise only over a shared domain. Read, never Tx: a
-- behavior may query at the sample moment and may not mutate. Nothing is
-- stored, so there is no clock read anywhere in here — Moment arrives as an
-- argument.

newtype Behavior a = Behavior (Term '[Moment] 'Read a)

-- ---------------------------------------------------------------------------
-- The four functor kinds
--
-- Kinds 1-3 are Read or Tx and can abort a commit. Kind 4 produces an EventRef
-- — a queue row insert — and can abort nothing. A handler is not here at all:
-- it runs in Effect, which this DSL cannot express.

-- | Result of an event functor. Not @Either Error a@: the commit always
-- succeeds, because inserting the queue row /is/ the commit.
data EventRef = EventRef
  { erQueue     :: Text
  , erPayload   :: [(Text, String)]
  , erScheduled :: Timestamp
  } deriving (Eq, Show)

data AssertBody where
  -- | Equality of two paths — the case where the body is an expression.
  ABExpr     :: Term '[] 'Read Bool -> AssertBody
  -- | Presence: the query's result is non-empty.
  ABPresent  :: Query '[] -> AssertBody
  -- | Absence: `not` of one.
  ABAbsent   :: Query '[] -> AssertBody

data Trigger where
  -- | @on <cond> emit@ — the transition is observed across the write.
  TOn    :: Term '[] 'Read Bool -> Trigger
  -- | @every <interval> emit … where <cond>@ — the interval is any Read
  -- expression of type Duration, evaluated per row per tick, not a constant.
  TEvery :: Term '[] 'Read Duration -> Maybe (Term '[] 'Read Bool) -> Trigger

data FunctorK where
  -- | Validation. Field-scoped, so the context is the field value alone. The
  -- message is a plain Text and not an expression over the value: on a Secret
  -- field only @a -> Bool@ is admissible, and a message that could interpolate
  -- the value is exactly the leak that rule exists to prevent.
  KValidation :: Text -> Ty a -> Term '[a] 'Read Bool -> Text -> FunctorK
  KForeignKey :: Text -> Edge -> [Absence] -> FunctorK
  KPath       :: Text -> AssertBody -> FunctorK
  KEvent      :: Text -> Trigger -> Text -> [(Text, Term '[] 'Read Text)] -> FunctorK

functorName :: FunctorK -> Text
functorName = \case
  KValidation n _ _ _ -> n
  KForeignKey n _ _   -> n
  KPath n _           -> n
  KEvent n _ _ _      -> n

functorKind :: FunctorK -> String
functorKind = \case
  KValidation{} -> "validation"
  KForeignKey{} -> "foreign key"
  KPath{}       -> "path constraint"
  KEvent{}      -> "event"

-- ---------------------------------------------------------------------------
-- Templates
--
-- Text with holes, where the result count of a hole's query is the control
-- flow: zero rows render nothing, one renders once, N render N times joined by
-- the template's separator. No if, no each, no else.

data Piece (ctx :: [Type]) where
  PText :: Text -> Piece ctx
  PHole :: Query ctx -> Maybe Text -> Piece ctx   -- ^ query, optional `using` template

data Template = Template { tmplName :: Text, tmplSep :: Text, tmplPieces :: [Piece '[]] }
