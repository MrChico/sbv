-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Core.Symbolic
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Symbolic values
-----------------------------------------------------------------------------

{-# LANGUAGE    GeneralizedNewtypeDeriving #-}
{-# LANGUAGE    TypeSynonymInstances       #-}
{-# LANGUAGE    TypeOperators              #-}
{-# LANGUAGE    MultiParamTypeClasses      #-}
{-# LANGUAGE    ScopedTypeVariables        #-}
{-# LANGUAGE    FlexibleInstances          #-}
{-# LANGUAGE    PatternGuards              #-}
{-# LANGUAGE    NamedFieldPuns             #-}
{-# LANGUAGE    DeriveDataTypeable         #-}
{-# LANGUAGE    DeriveFunctor              #-}
{-# LANGUAGE    CPP                        #-}
{-# OPTIONS_GHC -fno-warn-orphans          #-}

module Data.SBV.Core.Symbolic
  ( NodeId(..)
  , SW(..), swKind, trueSW, falseSW
  , Op(..), PBOp(..), FPOp(..)
  , Quantifier(..), needsExistentials
  , RoundingMode(..)
  , SBVType(..), newUninterpreted, addAxiom
  , SVal(..)
  , svMkSymVar
  , ArrayContext(..), ArrayInfo
  , svToSW, svToSymSW, forceSWArg
  , SBVExpr(..), newExpr, isCodeGenMode
  , Cached, cache, uncache
  , ArrayIndex, uncacheAI
  , NamedSymVar
  , getSValPathCondition, extendSValPathCondition
  , getTableIndex
  , SBVPgm(..), Symbolic, runSymbolic, runSymbolicWithState, runSymbolic', State(..), withNewIncState, IncState(..)
  , inProofMode, inNonInteractiveProofMode, switchToInteractiveMode, getProofMode, SBVRunMode(..), Result(..)
  , registerKind, registerLabel
  , addAssertion, addSValConstraint, internalConstraint, internalVariable
  , SMTLibPgm(..), SMTLibVersion(..), smtLibVersionExtension
  , SolverCapabilities(..)
  , extractSymbolicSimulationState
  , OptimizeStyle(..), Objective(..), Penalty(..), objectiveName, addSValOptGoal
  , Tactic(..), addSValTactic, isParallelCaseAnywhere
  , Query(..), QueryContext(..), QueryState(..), query, runQuery
  , SMTScript(..), Solver(..), SMTSolver(..), SMTResult(..), SMTModel(..), SMTConfig(..), SMTEngine, getSBranchRunConfig
  , outputSVal
  , mkSValUserSort
  , SArr(..), readSArr, resetSArr, writeSArr, mergeSArr, newSArr, eqSArr
  ) where

import Control.DeepSeq          (NFData(..))
import Control.Monad            (when, unless)
import Control.Monad.Reader     (MonadReader, ReaderT, ask, runReaderT)
import Control.Monad.State.Lazy (MonadState, StateT(..), evalStateT)
import Control.Monad.Trans      (MonadIO, liftIO)
import Data.Char                (isAlpha, isAlphaNum, toLower)
import Data.IORef               (IORef, newIORef, readIORef)
import Data.List                (intercalate, sortBy)
import Data.Maybe               (isJust, fromJust, fromMaybe)

import GHC.Stack.Compat

import qualified Data.IORef    as R    (modifyIORef')
import qualified Data.Generics as G    (Data(..))
import qualified Data.IntMap   as IMap (IntMap, empty, size, toAscList, lookup, insert, insertWith)
import qualified Data.Map      as Map  (Map, empty, toList, size, insert, lookup)
import qualified Data.Set      as Set  (Set, empty, toList, insert, member)
import qualified Data.Foldable as F    (toList)
import qualified Data.Sequence as S    (Seq, empty, (|>))

import System.Mem.StableName
import System.Random

import Data.SBV.Core.Kind
import Data.SBV.Core.Concrete
import Data.SBV.SMT.SMTLibNames
import Data.SBV.Utils.TDiff(Timing)

import Data.SBV.Control.Types

import Prelude ()
import Prelude.Compat

-- | A symbolic node id
newtype NodeId = NodeId Int deriving (Eq, Ord)

-- | A symbolic word, tracking it's signedness and size.
data SW = SW !Kind !NodeId deriving (Eq, Ord)

instance HasKind SW where
  kindOf (SW k _) = k

instance Show SW where
  show (SW _ (NodeId n))
    | n < 0 = "s_" ++ show (abs n)
    | True  = 's' : show n

-- | Kind of a symbolic word.
swKind :: SW -> Kind
swKind (SW k _) = k

-- | Forcing an argument; this is a necessary evil to make sure all the arguments
-- to an uninterpreted function and sBranch test conditions are evaluated before called;
-- the semantics of uinterpreted functions is necessarily strict; deviating from Haskell's
forceSWArg :: SW -> IO ()
forceSWArg (SW k n) = k `seq` n `seq` return ()

-- | Constant False as an SW. Note that this value always occupies slot -2.
falseSW :: SW
falseSW = SW KBool $ NodeId (-2)

-- | Constant True as an SW. Note that this value always occupies slot -1.
trueSW :: SW
trueSW  = SW KBool $ NodeId (-1)

-- | Symbolic operations
data Op = Plus
        | Times
        | Minus
        | UNeg
        | Abs
        | Quot
        | Rem
        | Equal
        | NotEqual
        | LessThan
        | GreaterThan
        | LessEq
        | GreaterEq
        | Ite
        | And
        | Or
        | XOr
        | Not
        | Shl Int
        | Shr Int
        | Rol Int
        | Ror Int
        | Extract Int Int                       -- Extract i j: extract bits i to j. Least significant bit is 0 (big-endian)
        | Join                                  -- Concat two words to form a bigger one, in the order given
        | LkUp (Int, Kind, Kind, Int) !SW !SW   -- (table-index, arg-type, res-type, length of the table) index out-of-bounds-value
        | ArrEq   Int Int                       -- Array equality
        | ArrRead Int
        | KindCast Kind Kind
        | Uninterpreted String
        | Label String                          -- Essentially no-op; useful for code generation to emit comments.
        | IEEEFP FPOp                           -- Floating-point ops, categorized separately
        | PseudoBoolean PBOp                    -- Pseudo-boolean ops, categorized separately
        deriving (Eq, Ord)

-- | Floating point operations
data FPOp = FP_Cast        Kind Kind SW   -- From-Kind, To-Kind, RoundingMode. This is "value" conversion
          | FP_Reinterpret Kind Kind      -- From-Kind, To-Kind. This is bit-reinterpretation using IEEE-754 interchange format
          | FP_Abs
          | FP_Neg
          | FP_Add
          | FP_Sub
          | FP_Mul
          | FP_Div
          | FP_FMA
          | FP_Sqrt
          | FP_Rem
          | FP_RoundToIntegral
          | FP_Min
          | FP_Max
          | FP_ObjEqual
          | FP_IsNormal
          | FP_IsSubnormal
          | FP_IsZero
          | FP_IsInfinite
          | FP_IsNaN
          | FP_IsNegative
          | FP_IsPositive
          deriving (Eq, Ord)

-- Note that the show instance maps to the SMTLib names. We need to make sure
-- this mapping stays correct through SMTLib changes. The only exception
-- is FP_Cast; where we handle different source/origins explicitly later on.
instance Show FPOp where
   show (FP_Cast f t r)      = "(FP_Cast: " ++ show f ++ " -> " ++ show t ++ ", using RM [" ++ show r ++ "])"
   show (FP_Reinterpret f t) = case (f, t) of
                                  (KBounded False 32, KFloat)  -> "(_ to_fp 8 24)"
                                  (KBounded False 64, KDouble) -> "(_ to_fp 11 53)"
                                  _                            -> error $ "SBV.FP_Reinterpret: Unexpected conversion: " ++ show f ++ " to " ++ show t
   show FP_Abs               = "fp.abs"
   show FP_Neg               = "fp.neg"
   show FP_Add               = "fp.add"
   show FP_Sub               = "fp.sub"
   show FP_Mul               = "fp.mul"
   show FP_Div               = "fp.div"
   show FP_FMA               = "fp.fma"
   show FP_Sqrt              = "fp.sqrt"
   show FP_Rem               = "fp.rem"
   show FP_RoundToIntegral   = "fp.roundToIntegral"
   show FP_Min               = "fp.min"
   show FP_Max               = "fp.max"
   show FP_ObjEqual          = "="
   show FP_IsNormal          = "fp.isNormal"
   show FP_IsSubnormal       = "fp.isSubnormal"
   show FP_IsZero            = "fp.isZero"
   show FP_IsInfinite        = "fp.isInfinite"
   show FP_IsNaN             = "fp.isNaN"
   show FP_IsNegative        = "fp.isNegative"
   show FP_IsPositive        = "fp.isPositive"

-- | Pseudo-boolean operations
data PBOp = PB_AtMost  Int        -- ^ At most k
          | PB_AtLeast Int        -- ^ At least k
          | PB_Exactly Int        -- ^ Exactly k
          | PB_Le      [Int] Int  -- ^ At most k,  with coefficients given. Generalizes PB_AtMost
          | PB_Ge      [Int] Int  -- ^ At least k, with coefficients given. Generalizes PB_AtLeast
          | PB_Eq      [Int] Int  -- ^ Exactly k,  with coefficients given. Generalized PB_Exactly
          deriving (Eq, Ord, Show)

-- Show instance for 'Op'. Note that this is largely for debugging purposes, not used
-- for being read by any tool.
instance Show Op where
  show (Shl i) = "<<"  ++ show i
  show (Shr i) = ">>"  ++ show i
  show (Rol i) = "<<<" ++ show i
  show (Ror i) = ">>>" ++ show i
  show (Extract i j) = "choose [" ++ show i ++ ":" ++ show j ++ "]"
  show (LkUp (ti, at, rt, l) i e)
        = "lookup(" ++ tinfo ++ ", " ++ show i ++ ", " ++ show e ++ ")"
        where tinfo = "table" ++ show ti ++ "(" ++ show at ++ " -> " ++ show rt ++ ", " ++ show l ++ ")"
  show (ArrEq i j)       = "array_" ++ show i ++ " == array_" ++ show j
  show (ArrRead i)       = "select array_" ++ show i
  show (KindCast fr to)  = "cast_" ++ show fr ++ "_" ++ show to
  show (Uninterpreted i) = "[uninterpreted] " ++ i
  show (Label s)         = "[label] " ++ s
  show (IEEEFP w)        = show w
  show (PseudoBoolean p) = show p
  show op
    | Just s <- op `lookup` syms = s
    | True                       = error "impossible happened; can't find op!"
    where syms = [ (Plus, "+"), (Times, "*"), (Minus, "-"), (UNeg, "-"), (Abs, "abs")
                 , (Quot, "quot")
                 , (Rem,  "rem")
                 , (Equal, "=="), (NotEqual, "/=")
                 , (LessThan, "<"), (GreaterThan, ">"), (LessEq, "<="), (GreaterEq, ">=")
                 , (Ite, "if_then_else")
                 , (And, "&"), (Or, "|"), (XOr, "^"), (Not, "~")
                 , (Join, "#")
                 ]

-- | Quantifiers: forall or exists. Note that we allow
-- arbitrary nestings.
data Quantifier = ALL | EX deriving Eq

-- | Are there any existential quantifiers?
needsExistentials :: [Quantifier] -> Bool
needsExistentials = (EX `elem`)

-- | A simple type for SBV computations, used mainly for uninterpreted constants.
-- We keep track of the signedness/size of the arguments. A non-function will
-- have just one entry in the list.
newtype SBVType = SBVType [Kind]
             deriving (Eq, Ord)

instance Show SBVType where
  show (SBVType []) = error "SBV: internal error, empty SBVType"
  show (SBVType xs) = intercalate " -> " $ map show xs

-- | A symbolic expression
data SBVExpr = SBVApp !Op ![SW]
             deriving (Eq, Ord)

-- | To improve hash-consing, take advantage of commutative operators by
-- reordering their arguments.
reorder :: SBVExpr -> SBVExpr
reorder s = case s of
              SBVApp op [a, b] | isCommutative op && a > b -> SBVApp op [b, a]
              _ -> s
  where isCommutative :: Op -> Bool
        isCommutative o = o `elem` [Plus, Times, Equal, NotEqual, And, Or, XOr]

-- Show instance for 'SBVExpr'. Again, only for debugging purposes.
instance Show SBVExpr where
  show (SBVApp Ite [t, a, b])             = unwords ["if", show t, "then", show a, "else", show b]
  show (SBVApp (Shl i) [a])               = unwords [show a, "<<", show i]
  show (SBVApp (Shr i) [a])               = unwords [show a, ">>", show i]
  show (SBVApp (Rol i) [a])               = unwords [show a, "<<<", show i]
  show (SBVApp (Ror i) [a])               = unwords [show a, ">>>", show i]
  show (SBVApp (PseudoBoolean pb) args)   = unwords (show pb : map show args)
  show (SBVApp op                 [a, b]) = unwords [show a, show op, show b]
  show (SBVApp op                 args)   = unwords (show op : map show args)

-- | A program is a sequence of assignments
newtype SBVPgm = SBVPgm {pgmAssignments :: S.Seq (SW, SBVExpr)}

-- | 'NamedSymVar' pairs symbolic words and user given/automatically generated names
type NamedSymVar = (SW, String)

-- | Style of optimization. Note that in the pareto case the user is allowed
-- to specify a max number of fronts to query the solver for, since there might
-- potentially be an infinite number of them and there is no way to know exactly
-- how many ahead of time. If 'Nothing' is given, SBV will possibly loop forever
-- if the number is really infinite.
data OptimizeStyle = Lexicographic      -- ^ Objectives are optimized in the order given, earlier objectives have higher priority. This is the default.
                   | Independent        -- ^ Each objective is optimized independently.
                   | Pareto (Maybe Int) -- ^ Objectives are optimized according to pareto front: That is, no objective can be made better without making some other worse.
                   deriving (Eq, Show)

-- | Penalty for a soft-assertion. The default penalty is @1@, with all soft-assertions belonging
-- to the same objective goal. A positive weight and an optional group can be provided by using
-- the 'Penalty' constructor.
data Penalty = DefaultPenalty                  -- ^ Default: Penalty of @1@ and no group attached
             | Penalty Rational (Maybe String) -- ^ Penalty with a weight and an optional group
             deriving Show

-- | Objective of optimization. We can minimize, maximize, or give a soft assertion with a penalty
-- for not satisfying it.
data Objective a = Minimize   String a         -- ^ Minimize this metric
                 | Maximize   String a         -- ^ Maximize this metric
                 | AssertSoft String a Penalty -- ^ A soft assertion, with an associated penalty
                 deriving (Show, Functor)

-- | The name of the objective
objectiveName :: Objective a -> String
objectiveName (Minimize   s _)   = s
objectiveName (Maximize   s _)   = s
objectiveName (AssertSoft s _ _) = s

-- | The context of a query is the state of the symbolic simulation run and some extra info
data QueryContext = QueryContext {
                        contextState   :: State
                      , contextSkolems :: [String]
                      }

instance NFData QueryContext where
   rnf (QueryContext st sks) = rnf st `seq` rnf sks `seq` ()

-- | The state we keep track of as we interact with the solver
data QueryState = QueryState { queryAsk                 :: String -> IO String
                             , queryConfig              :: SMTConfig
                             , queryContext             :: QueryContext
                             , queryDefault             :: Bool -> IO [SMTResult]
                             , queryGetModel            :: IO [SMTResult]
                             , queryIgnoreExitCode      :: Bool
                             , queryAssertionStackDepth :: Int
                             }

-- | A query is a user-guided mechanism to extract results from the solver.
newtype Query a = Query (StateT QueryState IO a)
             deriving (Applicative, Functor, Monad, MonadIO, MonadState QueryState)

-- Show instance for Query, needed since tactics are Showable
instance Show (Query a) where
   show _ = "<Query>"

-- | Execute a query.
runQuery :: Query a -> QueryState -> IO a
runQuery (Query userQuery) qs@QueryState{queryAsk} = evalStateT f' qs
  where f' = do let cmd = "(set-option :print-success true)"
                r <- liftIO $ queryAsk cmd
                case r of
                  "success" -> userQuery
                  _         -> error $ unlines [ ""
                                               , "*** Data.SBV: Failed to initiate contact with the solver!"
                                               , "***   Sent    : " ++ cmd
                                               , "***   Expected: success"
                                               , "***   Received: " ++ r
                                               , "*** Try running in debug mode for further information."
                                               ]

-- | Install a custom query.
query :: Query [SMTResult] -> Symbolic ()
query q = addSValTactic (QueryUsing q)

-- | Solver tactic
data Tactic a = CaseSplit          Bool [(String, a, [Tactic a])]  -- ^ Case-split, with implicit coverage. Bool says whether we should be verbose.
              | CheckCaseVacuity   Bool                            -- ^ Should the case-splits be checked for vacuity? (Default: True.)
              | ParallelCase                                       -- ^ Run case-splits in parallel. (Default: Sequential.)
              | CheckConstrVacuity Bool                            -- ^ Should "constraints" be checked for vacuity? (Default: False.)
              | StopAfter          Int                             -- ^ Time-out given to solver, in seconds.
              | CheckUsing         String                          -- ^ Invoke with check-sat-using command, instead of check-sat
              | UseSolver          SMTConfig                       -- ^ Use this solver (z3, yices, etc.)
              | SetOptions         [SMTOption]                     -- ^ Set these options
              | OptimizePriority   OptimizeStyle                   -- ^ Use this style for optimize calls. (Default: Lexicographic)
              | QueryUsing         (Query [SMTResult])             -- ^ Use a custom query-engine to extract results.
              deriving (Show, Functor)

instance NFData OptimizeStyle where
   rnf x = x `seq` ()

instance NFData Penalty where
   rnf DefaultPenalty  = ()
   rnf (Penalty p mbs) = rnf p `seq` rnf mbs `seq` ()

instance NFData a => NFData (Objective a) where
   rnf (Minimize   s a)   = rnf s `seq` rnf a `seq` ()
   rnf (Maximize   s a)   = rnf s `seq` rnf a `seq` ()
   rnf (AssertSoft s a p) = rnf s `seq` rnf a `seq` rnf p `seq` ()

instance NFData a => NFData (Tactic a) where
   rnf (CaseSplit   b l)      = rnf b `seq` rnf l `seq` ()
   rnf (CheckCaseVacuity b)   = rnf b `seq` ()
   rnf ParallelCase           = ()
   rnf (CheckConstrVacuity b) = rnf b `seq` ()
   rnf (StopAfter        i)   = rnf i `seq` ()
   rnf (CheckUsing       s)   = rnf s `seq` ()
   rnf (UseSolver        s)   = rnf s `seq` ()
   rnf (SetOptions       o)  =  rnf o `seq` ()
   rnf (OptimizePriority s)   = rnf s `seq` ()
   rnf (QueryUsing       _)   = ()

-- | Is there a parallel-case anywhere?
isParallelCaseAnywhere :: Tactic a -> Bool
isParallelCaseAnywhere ParallelCase{}   = True
isParallelCaseAnywhere (CaseSplit _ cs) = or [any isParallelCaseAnywhere t | (_, _, t) <- cs]
isParallelCaseAnywhere _                = False

-- | Result of running a symbolic computation
data Result = Result { reskinds       :: Set.Set Kind                            -- ^ kinds used in the program
                     , resTraces      :: [(String, CW)]                          -- ^ quick-check counter-example information (if any)
                     , resUISegs      :: [(String, [String])]                    -- ^ uninterpeted code segments
                     , resInputs      :: [(Quantifier, NamedSymVar)]             -- ^ inputs (possibly existential)
                     , resConsts      :: [(SW, CW)]                              -- ^ constants
                     , resTables      :: [((Int, Kind, Kind), [SW])]             -- ^ tables (automatically constructed) (tableno, index-type, result-type) elts
                     , resArrays      :: [(Int, ArrayInfo)]                      -- ^ arrays (user specified)
                     , resUIConsts    :: [(String, SBVType)]                     -- ^ uninterpreted constants
                     , resAxioms      :: [(String, [String])]                    -- ^ axioms
                     , resAsgns       :: SBVPgm                                  -- ^ assignments
                     , resConstraints :: [(Maybe String, SW)]                    -- ^ additional constraints (boolean)
                     , resTactics     :: [Tactic SW]                             -- ^ User given tactics
                     , resGoals       :: [Objective (SW, SW)]                    -- ^ User specified optimization goals
                     , resAssertions  :: [(String, Maybe CallStack, SW)]         -- ^ assertions
                     , resOutputs     :: [SW]                                    -- ^ outputs
                     }

-- Show instance for 'Result'. Only for debugging purposes.
instance Show Result where
  show (Result _ _ _ _ cs _ _ [] [] _ [] _ _ _ [r])
    | Just c <- r `lookup` cs
    = show c
  show (Result kinds _ cgs is cs ts as uis axs xs cstrs tacs goals asserts os) = intercalate "\n" $
                   (if null usorts then [] else "SORTS" : map ("  " ++) usorts)
                ++ ["INPUTS"]
                ++ map shn is
                ++ ["CONSTANTS"]
                ++ map shc cs
                ++ ["TABLES"]
                ++ map sht ts
                ++ ["ARRAYS"]
                ++ map sha as
                ++ ["UNINTERPRETED CONSTANTS"]
                ++ map shui uis
                ++ ["USER GIVEN CODE SEGMENTS"]
                ++ concatMap shcg cgs
                ++ ["AXIOMS"]
                ++ map shax axs
                ++ ["TACTICS"]
                ++ map show tacs
                ++ ["GOALS"]
                ++ map show goals
                ++ ["DEFINE"]
                ++ map (\(s, e) -> "  " ++ shs s ++ " = " ++ show e) (F.toList (pgmAssignments xs))
                ++ ["CONSTRAINTS"]
                ++ map (("  " ++) . shCstr) cstrs
                ++ ["ASSERTIONS"]
                ++ map (("  "++) . shAssert) asserts
                ++ ["OUTPUTS"]
                ++ map (("  " ++) . show) os
    where usorts = [sh s t | KUserSort s t <- Set.toList kinds]
                   where sh s (Left   _) = s
                         sh s (Right es) = s ++ " (" ++ intercalate ", " es ++ ")"

          shs sw = show sw ++ " :: " ++ show (swKind sw)

          sht ((i, at, rt), es)  = "  Table " ++ show i ++ " : " ++ show at ++ "->" ++ show rt ++ " = " ++ show es

          shc (sw, cw) = "  " ++ show sw ++ " = " ++ show cw

          shcg (s, ss) = ("Variable: " ++ s) : map ("  " ++) ss

          shn (q, (sw, nm)) = "  " ++ ni ++ " :: " ++ show (swKind sw) ++ ex ++ alias
            where ni = show sw
                  ex | q == ALL = ""
                     | True     = ", existential"
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm

          sha (i, (nm, (ai, bi), ctx)) = "  " ++ ni ++ " :: " ++ show ai ++ " -> " ++ show bi ++ alias
                                       ++ "\n     Context: "     ++ show ctx
            where ni = "array_" ++ show i
                  alias | ni == nm = ""
                        | True     = ", aliasing " ++ show nm

          shui (nm, t) = "  [uninterpreted] " ++ nm ++ " :: " ++ show t

          shax (nm, ss) = "  -- user defined axiom: " ++ nm ++ "\n  " ++ intercalate "\n  " ss

          shCstr (Nothing, c) = show c
          shCstr (Just nm, c) = nm ++ ": " ++ show c

          shAssert (nm, stk, p) = "  -- assertion: " ++ nm ++ " " ++ maybe "[No location]"
#if MIN_VERSION_base(4,9,0)
                prettyCallStack
#else
                showCallStack
#endif
                stk ++ ": " ++ show p

-- | The context of a symbolic array as created
data ArrayContext = ArrayFree (Maybe SW)     -- ^ A new array, with potential initializer for each cell
                  | ArrayReset Int SW        -- ^ An array created from another array by fixing each element to another value
                  | ArrayMutate Int SW SW    -- ^ An array created by mutating another array at a given cell
                  | ArrayMerge  SW Int Int   -- ^ An array created by symbolically merging two other arrays

instance Show ArrayContext where
  show (ArrayFree Nothing)  = " initialized with random elements"
  show (ArrayFree (Just s)) = " initialized with " ++ show s ++ " :: " ++ show (swKind s)
  show (ArrayReset i s)     = " reset array_" ++ show i ++ " with " ++ show s ++ " :: " ++ show (swKind s)
  show (ArrayMutate i a b)  = " cloned from array_" ++ show i ++ " with " ++ show a ++ " :: " ++ show (swKind a) ++ " |-> " ++ show b ++ " :: " ++ show (swKind b)
  show (ArrayMerge s i j)   = " merged arrays " ++ show i ++ " and " ++ show j ++ " on condition " ++ show s

-- | Expression map, used for hash-consing
type ExprMap   = Map.Map SBVExpr SW

-- | Constants are stored in a map, for hash-consing. The bool is needed to tell -0 from +0, sigh
type CnstMap   = Map.Map (Bool, CW) SW

-- | Kinds used in the program; used for determining the final SMT-Lib logic to pick
type KindSet = Set.Set Kind

-- | Tables generated during a symbolic run
type TableMap  = Map.Map (Kind, Kind, [SW]) Int

-- | Representation for symbolic arrays
type ArrayInfo = (String, (Kind, Kind), ArrayContext)

-- | Arrays generated during a symbolic run
type ArrayMap  = IMap.IntMap ArrayInfo

-- | Uninterpreted-constants generated during a symbolic run
type UIMap     = Map.Map String SBVType

-- | Code-segments for Uninterpreted-constants, as given by the user
type CgMap     = Map.Map String [String]

-- | Cached values, implementing sharing
type Cache a   = IMap.IntMap [(StableName (State -> IO a), a)]

-- | Different means of running a symbolic piece of code
data SBVRunMode = Proof       (Bool, SMTConfig) -- ^ Fully Symbolic, proof mode.
                | Interactive (Bool, SMTConfig) -- ^ In an interactive mode, during user control.
                | CodeGen                       -- ^ Code generation mode.
                | Concrete StdGen               -- ^ Concrete simulation mode. The StdGen is for the pConstrain acceptance in cross runs.

-- Show instance for SBVRunMode; debugging purposes only
instance Show SBVRunMode where
   show (Proof       (True, _))  = "Satisfiability"
   show (Proof       (False, _)) = "Proof"
   show (Interactive (True, _))  = "Satisfiability"
   show (Interactive (False, _)) = "Proof"
   show CodeGen                  = "Code generation"
   show Concrete{}               = "Concrete evaluation"

-- | Is this a concrete run? (i.e., quick-check or test-generation like)
isConcreteMode :: State -> Bool
isConcreteMode State{runMode} = case runMode of
                                  Concrete{}    -> True
                                  Proof{}       -> False
                                  Interactive{} -> False
                                  CodeGen       -> False

-- | Is this a CodeGen run? (i.e., generating code)
isCodeGenMode :: State -> Bool
isCodeGenMode State{runMode} = case runMode of
                                 Concrete{}    -> False
                                 Proof{}       -> False
                                 Interactive{} -> False
                                 CodeGen       -> True

-- | The state in query mode, i.e., additional context
data IncState = IncState { rNewConsts :: IORef CnstMap
                         , rNewAsgns  :: IORef SBVPgm
                         }

-- | Get a new IncState
newIncState :: IO IncState
newIncState = do
        nc  <- newIORef Map.empty
        pgm <- newIORef (SBVPgm S.empty)
        return IncState { rNewConsts = nc
                        , rNewAsgns  = pgm
                        }

-- | Get a new IncState
withNewIncState :: State -> (State -> IO a) -> IO (IncState, a)
withNewIncState st cont = do
        is <- newIncState
        R.modifyIORef' (rIncState st) (const is)
        r  <- cont st
        finalIncState <- readIORef (rIncState st)
        return (finalIncState, r)

-- | Return and clean and incState

-- | The state of the symbolic interpreter
data State  = State { runMode      :: SBVRunMode
                    , pathCond     :: SVal                             -- ^ kind KBool
                    , rIncState    :: IORef IncState
                    , rStdGen      :: IORef StdGen
                    , rCInfo       :: IORef [(String, CW)]
                    , rctr         :: IORef Int
                    , rUsedKinds   :: IORef KindSet
                    , rUsedLbls    :: IORef (Set.Set String)
                    , rinps        :: IORef [(Quantifier, NamedSymVar)]
                    , rConstraints :: IORef [(Maybe String, SW)]
                    , routs        :: IORef [SW]
                    , rtblMap      :: IORef TableMap
                    , spgm         :: IORef SBVPgm
                    , rconstMap    :: IORef CnstMap
                    , rexprMap     :: IORef ExprMap
                    , rArrayMap    :: IORef ArrayMap
                    , rUIMap       :: IORef UIMap
                    , rCgMap       :: IORef CgMap
                    , raxioms      :: IORef [(String, [String])]
                    , rTacs        :: IORef [Tactic SW]
                    , rOptGoals    :: IORef [Objective (SW, SW)]
                    , rAsserts     :: IORef [(String, Maybe CallStack, SW)]
                    , rSWCache     :: IORef (Cache SW)
                    , rAICache     :: IORef (Cache Int)
                    }

-- NFData is a bit of a lie, but it's sufficient, most of the content is iorefs that we don't want to touch
instance NFData State where
   rnf State{} = ()

-- | Get the current path condition
getSValPathCondition :: State -> SVal
getSValPathCondition = pathCond

-- | Extend the path condition with the given test value.
extendSValPathCondition :: State -> (SVal -> SVal) -> State
extendSValPathCondition st f = st{pathCond = f (pathCond st)}

-- | Are we running in proof mode?
inProofMode :: State -> Bool
inProofMode s = case runMode s of
                  Proof{}       -> True
                  Interactive{} -> True
                  CodeGen       -> False
                  Concrete{}    -> False

-- | Return the current proof mode
getProofMode :: State -> SBVRunMode
getProofMode = runMode

-- | Are we running in proof mode, but not in an interactive query?
inNonInteractiveProofMode :: State -> Bool
inNonInteractiveProofMode s = case runMode s of
                                Proof{}       -> True
                                Interactive{} -> False
                                CodeGen       -> False
                                Concrete{}    -> False

-- | Move to interactive mode from proof mode. It's an error to call
-- this function in a non-proof mode.
switchToInteractiveMode :: State -> State
switchToInteractiveMode s = case runMode s of
                              Proof bfcg      -> s {runMode = Interactive bfcg}
                              m@Interactive{} -> bad m
                              m@CodeGen       -> bad m
                              m@Concrete{}    -> bad m
  where bad m = error $ "Data.SBV: Impossible happened: Trying to switch to interactive in mode: " ++ show m

-- | If in proof mode, get the underlying configuration (used for 'sBranch')
getSBranchRunConfig :: State -> Maybe SMTConfig
getSBranchRunConfig st = case runMode st of
                           Proof (_, s)  -> Just s
                           _             -> Nothing

-- | The "Symbolic" value. Either a constant (@Left@) or a symbolic
-- value (@Right Cached@). Note that caching is essential for making
-- sure sharing is preserved.
data SVal = SVal !Kind !(Either CW (Cached SW))

instance HasKind SVal where
  kindOf (SVal k _) = k

-- Show instance for 'SVal'. Not particularly "desirable", but will do if needed
-- NB. We do not show the type info on constant KBool values, since there's no
-- implicit "fromBoolean" applied to Booleans in Haskell; and thus a statement
-- of the form "True :: SBool" is just meaningless. (There should be a fromBoolean!)
instance Show SVal where
  show (SVal KBool (Left c))  = showCW False c
  show (SVal k     (Left c))  = showCW False c ++ " :: " ++ show k
  show (SVal k     (Right _)) =         "<symbolic> :: " ++ show k

-- | Equality constraint on SBV values. Not desirable since we can't really compare two
-- symbolic values, but will do.
instance Eq SVal where
  SVal _ (Left a) == SVal _ (Left b) = a == b
  a == b = error $ "Comparing symbolic bit-vectors; Use (.==) instead. Received: " ++ show (a, b)
  SVal _ (Left a) /= SVal _ (Left b) = a /= b
  a /= b = error $ "Comparing symbolic bit-vectors; Use (./=) instead. Received: " ++ show (a, b)

-- | Things we do not support in interactive mode, at least for now!
noInteractive :: [String] -> IO ()
noInteractive ss = error $ unlines $  "*** Data.SBV: Unsupported interactive/query mode feature."
                                   :  map ("***  " ++) ss
                                   ++ ["*** Data.SBV: Please report this as a feature request!"]

-- | Modification of the state, but carefully handling the interactive tasks
modifyState :: State -> (State -> IORef a) -> (a -> a) -> IO () -> IO ()
modifyState st@State{runMode} field update interactiveUpdate = do
        R.modifyIORef' (field st) update
        case runMode of
          Interactive{} -> interactiveUpdate
          _             -> return ()

-- | Modify the incremental state
modifyIncState  :: State -> (IncState -> IORef a) -> (a -> a) -> IO ()
modifyIncState State{rIncState} field update = do
        incState <- readIORef rIncState
        R.modifyIORef' (field incState) update

-- | Increment the variable counter
incCtr :: State -> IO Int
incCtr st = do ctr <- readIORef (rctr st)
               modifyState st rctr (+1) (return ())
               return ctr

-- | Generate a random value, for quick-check and test-gen purposes
throwDice :: State -> IO Double
throwDice st = do g <- readIORef (rStdGen st)
                  let (r, g') = randomR (0, 1) g
                  modifyState st rStdGen (const g') (return ())
                  return r

-- | Create a new uninterpreted symbol, possibly with user given code
newUninterpreted :: State -> String -> SBVType -> Maybe [String] -> IO ()
newUninterpreted st nm t mbCode
  | null nm || not enclosed && (not (isAlpha (head nm)) || not (all validChar (tail nm)))
  = error $ "Bad uninterpreted constant name: " ++ show nm ++ ". Must be a valid identifier."
  | True = do
        uiMap <- readIORef (rUIMap st)
        case nm `Map.lookup` uiMap of
          Just t' -> when (t /= t') $ error $  "Uninterpreted constant " ++ show nm ++ " used at incompatible types\n"
                                            ++ "      Current type      : " ++ show t ++ "\n"
                                            ++ "      Previously used at: " ++ show t'
          Nothing -> do modifyState st rUIMap (Map.insert nm t) $ noInteractive [ "Uninterpreted function introduction:"
                                                                                , "  Named:  " ++ nm
                                                                                , "  Type :  " ++ show t
                                                                                ]
                        when (isJust mbCode) $ modifyState st rCgMap (Map.insert nm (fromJust mbCode)) (return ())
  where validChar x = isAlphaNum x || x `elem` "_"
        enclosed    = head nm == '|' && last nm == '|' && length nm > 2 && not (any (`elem` "|\\") (tail (init nm)))

-- | Add a new sAssert based constraint
addAssertion :: State -> Maybe CallStack -> String -> SW -> IO ()
addAssertion st cs msg cond = modifyState st rAsserts ((msg, cs, cond):)
                                        $ noInteractive [ "Named assertions (sAssert):"
                                                        , "  Tag: " ++ msg
                                                        , "  Loc: " ++ maybe "Unknown" show cs
                                                        ]

-- | Create an internal variable, which acts as an input but isn't visible to the user.
-- Such variables are existentially quantified in a SAT context, and universally quantified
-- in a proof context.
internalVariable :: State -> Kind -> IO SW
internalVariable st k = do (sw, nm) <- newSW st k
                           let q = case runMode st of
                                     Proof       (True,  _) -> EX
                                     Proof       (False, _) -> ALL
                                     Interactive (True,  _) -> EX
                                     Interactive (False, _) -> ALL
                                     CodeGen                -> ALL
                                     Concrete{}             -> ALL
                           modifyState st rinps ((q, (sw, "__internal_sbv_" ++ nm)):)
                                     $ noInteractive [ "Internal variable creation:"
                                                     , "  Named: " ++ nm
                                                     ]
                           return sw
{-# INLINE internalVariable #-}

-- | Create a new SW
newSW :: State -> Kind -> IO (SW, String)
newSW st k = do ctr <- incCtr st
                let sw = SW k (NodeId ctr)
                registerKind st k
                return (sw, 's' : show ctr)
{-# INLINE newSW #-}

-- | Register a new kind with the system, used for uninterpreted sorts
registerKind :: State -> Kind -> IO ()
registerKind st k
  | KUserSort sortName _ <- k, map toLower sortName `elem` smtLibReservedNames
  = error $ "SBV: " ++ show sortName ++ " is a reserved sort; please use a different name."
  | True
  = do ks <- readIORef (rUsedKinds st)
       -- explicitly check membership in case we use it in a query context
       unless (k `Set.member` ks) $ modifyState st rUsedKinds (Set.insert k)
                                              $ noInteractive [ "Registering a new kind:"
                                                              , "  Kind: " ++ show k
                                                              ]

-- | Register a new label with the system, making sure they are unique and have no '|'s in them
registerLabel :: State -> String -> IO ()
registerLabel st nm
  | map toLower nm `elem` smtLibReservedNames
  = error $ "SBV: " ++ show nm ++ " is a reserved string; please use a different name."
  | '|' `elem` nm
  = error $ "SBV: " ++ show nm ++ " contains the character `|', which is not allowed!"
  | '\\' `elem` nm
  = error $ "SBV: " ++ show nm ++ " contains the character `\', which is not allowed!"
  | True
  = do old <- readIORef $ rUsedLbls st
       if nm `Set.member` old
          then error $ "SBV: " ++ show nm ++ " is used as a label multiple times. Please do not use duplicate names!"
          else modifyState st rUsedLbls (Set.insert nm)
                         $ noInteractive [ "Registering a label:"
                                         , "  Label: " ++ nm
                                         ]

-- | Create a new constant; hash-cons as necessary
-- NB. For each constant, we also store weather it's negative-0 or not,
-- as otherwise +0 == -0 and thus we'd confuse those entries. That's a
-- bummer as we incur an extra boolean for this rare case, but it's simple
-- and hopefully we don't generate a ton of constants in general.
newConst :: State -> CW -> IO SW
newConst st c = do
  constMap <- readIORef (rconstMap st)
  let key = (isNeg0 (cwVal c), c)
  case key `Map.lookup` constMap of
    Just sw -> return sw
    Nothing -> do let k = kindOf c
                  (sw, _) <- newSW st k
                  let ins = Map.insert key sw
                  modifyState st rconstMap ins $ modifyIncState st rNewConsts ins
                  return sw
  where isNeg0 (CWFloat  f) = isNegativeZero f
        isNeg0 (CWDouble d) = isNegativeZero d
        isNeg0 _            = False
{-# INLINE newConst #-}

-- | Create a new table; hash-cons as necessary
getTableIndex :: State -> Kind -> Kind -> [SW] -> IO Int
getTableIndex st at rt elts = do
  let key = (at, rt, elts)
  tblMap <- readIORef (rtblMap st)
  case key `Map.lookup` tblMap of
    Just i -> return i
    _      -> do let i = Map.size tblMap
                 modifyState st rtblMap (Map.insert key i)
                            $ noInteractive [ "Creation of a new table:"
                                            , "   Index kind: " ++ show at
                                            , "   Value kind: " ++ show rt
                                            , "   Elements  : " ++ unwords (map show elts)
                                            ]
                 return i

-- | Create a new expression; hash-cons as necessary
newExpr :: State -> Kind -> SBVExpr -> IO SW
newExpr st k app = do
   let e = reorder app
   exprMap <- readIORef (rexprMap st)
   case e `Map.lookup` exprMap of
     Just sw -> return sw
     Nothing -> do (sw, _) <- newSW st k
                   let append (SBVPgm xs) = SBVPgm (xs S.|> (sw, e))
                   modifyState st spgm append $ modifyIncState st rNewAsgns append
                   modifyState st rexprMap (Map.insert e sw) (return ())
                   return sw
{-# INLINE newExpr #-}

-- | Convert a symbolic value to a symbolic-word
svToSW :: State -> SVal -> IO SW
svToSW st (SVal _ (Left c))  = newConst st c
svToSW st (SVal _ (Right f)) = uncache f st

-- | Convert a symbolic value to an SW, inside the Symbolic monad
svToSymSW :: SVal -> Symbolic SW
svToSymSW sbv = do st <- ask
                   liftIO $ svToSW st sbv

-------------------------------------------------------------------------
-- * Symbolic Computations
-------------------------------------------------------------------------
-- | A Symbolic computation. Represented by a reader monad carrying the
-- state of the computation, layered on top of IO for creating unique
-- references to hold onto intermediate results.
newtype Symbolic a = Symbolic (ReaderT State IO a)
                   deriving (Applicative, Functor, Monad, MonadIO, MonadReader State)

-- | Create a symbolic value, based on the quantifier we have. If an
-- explicit quantifier is given, we just use that. If not, then we
-- pick existential for SAT calls and universal for everything else.
-- @randomCW@ is used for generating random values for this variable
-- when used for 'quickCheck' purposes.
svMkSymVar :: Maybe Quantifier -> Kind -> Maybe String -> Symbolic SVal
svMkSymVar mbQ k mbNm = do
        st <- ask
        let q = case (mbQ, runMode st) of
                  (Just x,  _)                      -> x   -- user given, just take it
                  (Nothing, Concrete{})             -> ALL -- concrete simulation, pick universal
                  (Nothing, Proof       (True,  _)) -> EX  -- sat mode, pick existential
                  (Nothing, Proof       (False, _)) -> ALL -- proof mode, pick universal
                  (Nothing, Interactive (True,  _)) -> EX  -- interactive sat mode, pick existential
                  (Nothing, Interactive (False, _)) -> ALL -- interactive proof mode, pick universal
                  (Nothing, CodeGen)                -> ALL -- code generation, pick universal
        case runMode st of
          Concrete _ | q == EX -> case mbNm of
                                    Nothing -> error $ "Cannot quick-check in the presence of existential variables, type: " ++ show k
                                    Just nm -> error $ "Cannot quick-check in the presence of existential variable " ++ nm ++ " :: " ++ show k
          Concrete _           -> do cw <- liftIO (randomCW k)
                                     liftIO $ modifyState st rCInfo ((fromMaybe "_" mbNm, cw):) (return ())
                                     return (SVal k (Left cw))
          _          -> do (sw, internalName) <- liftIO $ newSW st k
                           let nm = fromMaybe internalName mbNm
                           introduceUserName st nm k q sw

-- | Create a properly quantified variable of a user defined sort. Only valid
-- in proof contexts.
mkSValUserSort :: Kind -> Maybe Quantifier -> Maybe String -> Symbolic SVal
mkSValUserSort k mbQ mbNm = do
        st <- ask
        let (KUserSort sortName _) = k
        liftIO $ registerKind st k
        let q = case (mbQ, runMode st) of
                  (Just x,  _)                      -> x
                  (Nothing, Proof       (True,  _)) -> EX
                  (Nothing, Proof       (False, _)) -> ALL
                  (Nothing, Interactive (True,  _)) -> EX
                  (Nothing, Interactive (False, _)) -> ALL
                  (Nothing, CodeGen)                -> error $ "SBV: Uninterpreted sort " ++ sortName ++ " can not be used in code-generation mode."
                  (Nothing, Concrete{})             -> error $ "SBV: Uninterpreted sort " ++ sortName ++ " can not be used in concrete simulation mode."
        ctr <- liftIO $ incCtr st
        let sw = SW k (NodeId ctr)
            nm = fromMaybe ('s':show ctr) mbNm
        introduceUserName st nm k q sw

-- | Introduce a new user name. We die if repeated.
introduceUserName :: State -> String -> Kind -> Quantifier -> SW -> Symbolic SVal
introduceUserName st nm k q sw = do is <- liftIO $ readIORef (rinps st)
                                    if nm `elem` [n | (_, (_, n)) <- is]
                                       then error $ "SBV: Repeated user given name: " ++ show nm ++ ". Please use unique names."
                                       else do liftIO $ modifyState st rinps ((q, (sw, nm)):)
                                                                  $ noInteractive [ "Adding a new named input:"
                                                                                  , "  Name      : " ++ show nm
                                                                                  , "  Kind      : " ++ show k
                                                                                  , "  Quantifier: " ++ if q == EX then "existential" else "universal"
                                                                                  , "  Node      : " ++ show sw
                                                                                  ]
                                               return $ SVal k $ Right $ cache (const (return sw))

-- | Add a user specified axiom to the generated SMT-Lib file. The first argument is a mere
-- string, use for commenting purposes. The second argument is intended to hold the multiple-lines
-- of the axiom text as expressed in SMT-Lib notation. Note that we perform no checks on the axiom
-- itself, to see whether it's actually well-formed or is sensical by any means.
-- A separate formalization of SMT-Lib would be very useful here.
addAxiom :: String -> [String] -> Symbolic ()
addAxiom nm ax = do
        st <- ask
        liftIO $ modifyState st raxioms ((nm, ax) :)
                           $ noInteractive [ "Adding a new axiom:"
                                           , "  Named: " ++ show nm
                                           , "  Axiom: " ++ unlines ax
                                           ]

-- | Run a symbolic computation in Proof mode and return a 'Result'. The boolean
-- argument indicates if this is a sat instance or not.
runSymbolic :: (Bool, SMTConfig) -> Symbolic a -> IO Result
runSymbolic m c = snd `fmap` runSymbolic' (Proof m) c

-- | Run a symbolic computation in the Proof mode, but also return the final state
runSymbolicWithState :: (Bool, SMTConfig) -> Symbolic a -> IO (State, Result)
runSymbolicWithState m c = runSymbolic' (Proof m) (c >> ask)

-- | Run a symbolic computation, and return a extra value paired up with the 'Result'
runSymbolic' :: SBVRunMode -> Symbolic a -> IO (a, Result)
runSymbolic' currentRunMode (Symbolic c) = do
   ctr       <- newIORef (-2) -- start from -2; False and True will always occupy the first two elements
   cInfo     <- newIORef []
   pgm       <- newIORef (SBVPgm S.empty)
   emap      <- newIORef Map.empty
   cmap      <- newIORef Map.empty
   inps      <- newIORef []
   outs      <- newIORef []
   tables    <- newIORef Map.empty
   arrays    <- newIORef IMap.empty
   uis       <- newIORef Map.empty
   cgs       <- newIORef Map.empty
   axioms    <- newIORef []
   swCache   <- newIORef IMap.empty
   aiCache   <- newIORef IMap.empty
   usedKinds <- newIORef Set.empty
   usedLbls  <- newIORef Set.empty
   cstrs     <- newIORef []
   tacs      <- newIORef []
   optGoals  <- newIORef []
   asserts   <- newIORef []
   istate    <- newIORef =<< newIncState
   rGen      <- case currentRunMode of
                  Concrete g -> newIORef g
                  _          -> newStdGen >>= newIORef
   let st = State { runMode      = currentRunMode
                  , pathCond     = SVal KBool (Left trueCW)
                  , rIncState    = istate
                  , rStdGen      = rGen
                  , rCInfo       = cInfo
                  , rctr         = ctr
                  , rUsedKinds   = usedKinds
                  , rUsedLbls    = usedLbls
                  , rinps        = inps
                  , routs        = outs
                  , rtblMap      = tables
                  , spgm         = pgm
                  , rconstMap    = cmap
                  , rArrayMap    = arrays
                  , rexprMap     = emap
                  , rUIMap       = uis
                  , rCgMap       = cgs
                  , raxioms      = axioms
                  , rSWCache     = swCache
                  , rAICache     = aiCache
                  , rConstraints = cstrs
                  , rTacs        = tacs
                  , rOptGoals    = optGoals
                  , rAsserts     = asserts
                  }
   _ <- newConst st falseCW -- s(-2) == falseSW
   _ <- newConst st trueCW  -- s(-1) == trueSW
   r <- runReaderT c st
   res <- extractSymbolicSimulationState st
   return (r, res)

-- | Grab the program from a running symbolic simulation state. This is useful for internal purposes, for
-- instance when implementing 'sBranch'.
extractSymbolicSimulationState :: State -> IO Result
extractSymbolicSimulationState st@State{ spgm=pgm, rinps=inps, routs=outs, rtblMap=tables, rArrayMap=arrays, rUIMap=uis, raxioms=axioms
                                       , rAsserts=asserts, rUsedKinds=usedKinds, rCgMap=cgs, rCInfo=cInfo, rConstraints=cstrs
                                       , rTacs=tacs, rOptGoals=optGoals } = do
   SBVPgm rpgm  <- readIORef pgm
   inpsO <- reverse `fmap` readIORef inps
   outsO <- reverse `fmap` readIORef outs
   let swap  (a, b)              = (b, a)
       swapc ((_, a), b)         = (b, a)
       cmp   (a, _) (b, _)       = a `compare` b
       arrange (i, (at, rt, es)) = ((i, at, rt), es)
   cnsts <- (sortBy cmp . map swapc . Map.toList) `fmap` readIORef (rconstMap st)
   tbls  <- (map arrange . sortBy cmp . map swap . Map.toList) `fmap` readIORef tables
   arrs  <- IMap.toAscList `fmap` readIORef arrays
   unint <- Map.toList `fmap` readIORef uis
   axs   <- reverse `fmap` readIORef axioms
   knds  <- readIORef usedKinds
   cgMap <- Map.toList `fmap` readIORef cgs
   traceVals  <- reverse `fmap` readIORef cInfo
   extraCstrs <- reverse `fmap` readIORef cstrs
   tactics    <- reverse `fmap` readIORef tacs
   goals      <- reverse `fmap` readIORef optGoals
   assertions <- reverse `fmap` readIORef asserts
   return $ Result knds traceVals cgMap inpsO cnsts tbls arrs unint axs (SBVPgm rpgm) extraCstrs tactics goals assertions outsO

-- | Handling constraints
imposeConstraint :: Maybe String -> SVal -> Symbolic ()
imposeConstraint mbNm c = do st <- ask
                             case runMode st of
                               CodeGen -> error "SBV: constraints are not allowed in code-generation"
                               _       -> do () <- case mbNm of
                                                     Nothing -> return ()
                                                     Just nm -> liftIO $ registerLabel st nm
                                             liftIO $ internalConstraint st mbNm c

-- | Require a boolean condition to be true in the state. Only used for internal purposes.
internalConstraint :: State -> Maybe String -> SVal -> IO ()
internalConstraint st mbNm b = do v <- svToSW st b
                                  modifyState st rConstraints ((mbNm, v):)
                                            $ noInteractive [ "Adding an internal constraint:"
                                                            , "  Named: " ++ fromMaybe "<unnamed>" mbNm
                                                            ]

-- | Add a tactic
addSValTactic :: Tactic SVal -> Symbolic ()
addSValTactic tac = do st <- ask
                       let walk (CaseSplit b cs)       = let app (nm, v, ts) = do ts' <- mapM walk ts
                                                                                  v' <- svToSW st v
                                                                                  return (nm, v', ts')
                                                         in CaseSplit b `fmap` mapM app cs
                           walk ParallelCase           = return   ParallelCase
                           walk (CheckCaseVacuity b)   = return $ CheckCaseVacuity b
                           walk (StopAfter i)          = return $ StopAfter  i
                           walk (CheckConstrVacuity b) = return $ CheckConstrVacuity b
                           walk (CheckUsing s)         = return $ CheckUsing s
                           walk (UseSolver  s)         = return $ UseSolver  s
                           walk (SetOptions o)         = return $ SetOptions o
                           walk (OptimizePriority s)   = return $ OptimizePriority s
                           walk (QueryUsing f)         = return $ QueryUsing f
                       tac' <- liftIO $ walk tac
                       liftIO $ modifyState st rTacs (tac':)
                                          $ noInteractive [ "Adding a new tactic:"
                                                          , "  Tactic: " ++ show tac
                                                          ]

-- | Add an optimization goal
addSValOptGoal :: Objective SVal -> Symbolic ()
addSValOptGoal obj = do st <- ask

                        -- create the tracking variable here for the metric
                        let mkGoal nm orig = do origSW  <- liftIO $ svToSW st orig
                                                track   <- svMkSymVar (Just EX) (kindOf orig) (Just nm)
                                                trackSW <- liftIO $ svToSW st track
                                                return (origSW, trackSW)

                        let walk (Minimize   nm v)     = Minimize nm              `fmap` mkGoal nm v
                            walk (Maximize   nm v)     = Maximize nm              `fmap` mkGoal nm v
                            walk (AssertSoft nm v mbP) = flip (AssertSoft nm) mbP `fmap` mkGoal nm v

                        obj' <- walk obj
                        liftIO $ modifyState st rOptGoals (obj' :)
                                           $ noInteractive [ "Adding an optimization objective:"
                                                           , "  Objective: " ++ show obj
                                                           ]

-- | Add a constraint with a given probability, and possibly a name
addSValConstraint :: Maybe String -> Maybe Double -> SVal -> SVal -> Symbolic ()
addSValConstraint mbNm Nothing  c _  = imposeConstraint mbNm c
addSValConstraint mbNm (Just t) c c'
  | t < 0 || t > 1
  = error $ "SBV: pConstrain: Invalid probability threshold: " ++ show t ++ ", must be in [0, 1]."
  | True
  = do st <- ask
       unless (isConcreteMode st) $ error "SBV: pConstrain only allowed in 'genTest' or 'quickCheck' contexts."
       case () of
         () | t > 0 && t < 1 -> liftIO (throwDice st) >>= \d -> imposeConstraint mbNm (if d <= t then c else c')
            | t > 0          -> imposeConstraint mbNm c
            | True           -> imposeConstraint mbNm c'

-- | Mark an interim result as an output. Useful when constructing Symbolic programs
-- that return multiple values, or when the result is programmatically computed.
outputSVal :: SVal -> Symbolic ()
outputSVal (SVal _ (Left c)) = do
  st <- ask
  sw <- liftIO $ newConst st c
  liftIO $ modifyState st routs (sw:) (return ())
outputSVal (SVal _ (Right f)) = do
  st <- ask
  sw <- liftIO $ uncache f st
  liftIO $ modifyState st routs (sw:) (return ())

---------------------------------------------------------------------------------
-- * Symbolic Arrays
---------------------------------------------------------------------------------

-- | Arrays implemented in terms of SMT-arrays: <http://smtlib.cs.uiowa.edu/theories-ArraysEx.shtml>
--
--   * Maps directly to SMT-lib arrays
--
--   * Reading from an unintialized value is OK and yields an unspecified result
--
--   * Can check for equality of these arrays
--
--   * Cannot quick-check theorems using @SArr@ values
--
--   * Typically slower as it heavily relies on SMT-solving for the array theory
--

data SArr = SArr (Kind, Kind) (Cached ArrayIndex)

-- | Read the array element at @a@
readSArr :: SArr -> SVal -> SVal
readSArr (SArr (_, bk) f) a = SVal bk $ Right $ cache r
  where r st = do arr <- uncacheAI f st
                  i   <- svToSW st a
                  newExpr st bk (SBVApp (ArrRead arr) [i])

-- | Reset all the elements of the array to the value @b@
resetSArr :: SArr -> SVal -> SArr
resetSArr (SArr ainfo f) b = SArr ainfo $ cache g
  where g st = do amap <- readIORef (rArrayMap st)
                  val <- svToSW st b
                  i <- uncacheAI f st
                  let j = IMap.size amap
                  j `seq` modifyState st rArrayMap (IMap.insert j ("array_" ++ show j, ainfo, ArrayReset i val))
                                      (noInteractive [ "An array reset:"
                                                     , "  Array info: " ++ show ainfo
                                                     ])
                  return j

-- | Update the element at @a@ to be @b@
writeSArr :: SArr -> SVal -> SVal -> SArr
writeSArr (SArr ainfo f) a b = SArr ainfo $ cache g
  where g st = do arr  <- uncacheAI f st
                  addr <- svToSW st a
                  val  <- svToSW st b
                  amap <- readIORef (rArrayMap st)
                  let j = IMap.size amap
                  j `seq` modifyState st rArrayMap (IMap.insert j ("array_" ++ show j, ainfo, ArrayMutate arr addr val))
                                      (noInteractive [ "An array update:"
                                                     , "  Array info: " ++ show ainfo
                                                     ])
                  return j

-- | Merge two given arrays on the symbolic condition
-- Intuitively: @mergeArrays cond a b = if cond then a else b@.
-- Merging pushes the if-then-else choice down on to elements
mergeSArr :: SVal -> SArr -> SArr -> SArr
mergeSArr t (SArr ainfo a) (SArr _ b) = SArr ainfo $ cache h
  where h st = do ai <- uncacheAI a st
                  bi <- uncacheAI b st
                  ts <- svToSW st t
                  amap <- readIORef (rArrayMap st)
                  let k = IMap.size amap
                  k `seq` modifyState st rArrayMap (IMap.insert k ("array_" ++ show k, ainfo, ArrayMerge ts ai bi))
                                      (noInteractive [ "An array merge:"
                                                     , "  Array info: " ++ show ainfo
                                                     ])
                  return k

-- | Create a named new array, with an optional initial value
newSArr :: (Kind, Kind) -> (Int -> String) -> Maybe SVal -> Symbolic SArr
newSArr ainfo mkNm mbInit = do
    st <- ask
    amap <- liftIO $ readIORef $ rArrayMap st
    let i = IMap.size amap
        nm = mkNm i
    actx <- liftIO $ case mbInit of
                       Nothing   -> return $ ArrayFree Nothing
                       Just ival -> svToSW st ival >>= \sw -> return $ ArrayFree (Just sw)
    liftIO $ modifyState st rArrayMap (IMap.insert i (nm, ainfo, actx))
                       $ noInteractive [ "A new array creation:"
                                       , "  Array info: " ++ show ainfo
                                       , "  Named     : " ++ show nm
                                       ]
    return $ SArr ainfo $ cache $ const $ return i

-- | Compare two arrays for equality
eqSArr :: SArr -> SArr -> SVal
eqSArr (SArr _ a) (SArr _ b) = SVal KBool $ Right $ cache c
  where c st = do ai <- uncacheAI a st
                  bi <- uncacheAI b st
                  newExpr st KBool (SBVApp (ArrEq ai bi) [])

---------------------------------------------------------------------------------
-- * Cached values
---------------------------------------------------------------------------------

-- | We implement a peculiar caching mechanism, applicable to the use case in
-- implementation of SBV's.  Whenever we do a state based computation, we do
-- not want to keep on evaluating it in the then-current state. That will
-- produce essentially a semantically equivalent value. Thus, we want to run
-- it only once, and reuse that result, capturing the sharing at the Haskell
-- level. This is similar to the "type-safe observable sharing" work, but also
-- takes into the account of how symbolic simulation executes.
--
-- See Andy Gill's type-safe obervable sharing trick for the inspiration behind
-- this technique: <http://ittc.ku.edu/~andygill/paper.php?label=DSLExtract09>
--
-- Note that this is *not* a general memo utility!
newtype Cached a = Cached (State -> IO a)

-- | Cache a state-based computation
cache :: (State -> IO a) -> Cached a
cache = Cached

-- | Uncache a previously cached computation
uncache :: Cached SW -> State -> IO SW
uncache = uncacheGen rSWCache

-- | An array index is simple an int value
type ArrayIndex = Int

-- | Uncache, retrieving array indexes
uncacheAI :: Cached ArrayIndex -> State -> IO ArrayIndex
uncacheAI = uncacheGen rAICache

-- | Generic uncaching. Note that this is entirely safe, since we do it in the IO monad.
uncacheGen :: (State -> IORef (Cache a)) -> Cached a -> State -> IO a
uncacheGen getCache (Cached f) st = do
        let rCache = getCache st
        stored <- readIORef rCache
        sn <- f `seq` makeStableName f
        let h = hashStableName sn
        case maybe Nothing (sn `lookup`) (h `IMap.lookup` stored) of
          Just r  -> return r
          Nothing -> do r <- f st
                        r `seq` R.modifyIORef' rCache (IMap.insertWith (++) h [(sn, r)])
                        return r

-- | Representation of SMTLib Program versions. As of June 2015, we're dropping support
-- for SMTLib1, and supporting SMTLib2 only. We keep this data-type around in case
-- SMTLib3 comes along and we want to support 2 and 3 simultaneously.
data SMTLibVersion = SMTLib2
                   deriving (Bounded, Enum, Eq, Show)

-- | The extension associated with the version
smtLibVersionExtension :: SMTLibVersion -> String
smtLibVersionExtension SMTLib2 = "smt2"

-- | Representation of an SMT-Lib program. In between pre and post goes the refuted models
data SMTLibPgm = SMTLibPgm SMTLibVersion [String]

instance NFData SMTLibVersion where rnf a               = a `seq` ()
instance NFData SMTLibPgm     where rnf (SMTLibPgm v p) = rnf v `seq` rnf p `seq` ()

instance Show SMTLibPgm where
  show (SMTLibPgm _ pre) = intercalate "\n" pre

-- Other Technicalities..
instance NFData CW where
  rnf (CW x y) = x `seq` y `seq` ()

instance NFData GeneralizedCW where
  rnf (ExtendedCW e) = e `seq` ()
  rnf (RegularCW  c) = c `seq` ()

#if MIN_VERSION_base(4,9,0)
#else
-- Can't really force this, but not a big deal
instance NFData CallStack where
  rnf _ = ()
#endif

instance NFData Result where
  rnf (Result kindInfo qcInfo cgs inps consts tbls arrs uis axs pgm cstr tacs goals asserts outs)
        = rnf kindInfo `seq` rnf qcInfo  `seq` rnf cgs  `seq` rnf inps
                       `seq` rnf consts  `seq` rnf tbls `seq` rnf arrs
                       `seq` rnf uis     `seq` rnf axs  `seq` rnf pgm
                       `seq` rnf cstr    `seq` rnf tacs `seq` rnf goals
                       `seq` rnf asserts `seq` rnf outs
instance NFData Kind         where rnf a          = seq a ()
instance NFData ArrayContext where rnf a          = seq a ()
instance NFData SW           where rnf a          = seq a ()
instance NFData SBVExpr      where rnf a          = seq a ()
instance NFData Quantifier   where rnf a          = seq a ()
instance NFData SBVType      where rnf a          = seq a ()
instance NFData SBVPgm       where rnf a          = seq a ()
instance NFData (Cached a)   where rnf (Cached f) = f `seq` ()
instance NFData SVal         where rnf (SVal x y) = rnf x `seq` rnf y `seq` ()

instance NFData SMTResult where
  rnf (Unsatisfiable _ uc) = rnf uc `seq` ()
  rnf (Satisfiable _   xs) = rnf xs `seq` ()
  rnf (SatExtField _   xs) = rnf xs `seq` ()
  rnf (Unknown _       xs) = rnf xs `seq` ()
  rnf (ProofError _    xs) = rnf xs `seq` ()
  rnf TimeOut{}            = ()

instance NFData SMTModel where
  rnf (SMTModel objs assocs) = rnf objs `seq` rnf assocs `seq` ()

instance NFData SMTScript where
  rnf (SMTScript b m) = rnf b `seq` rnf m `seq` ()

-- | Translation tricks needed for specific capabilities afforded by each solver
data SolverCapabilities = SolverCapabilities {
         capSolverName              :: String  -- ^ Name of the solver
       , supportsDefineFun          :: Bool    -- ^ Does the solver understand SMT-Lib2 define-funs?
       , supportsProduceModels      :: Bool    -- ^ Does the solver understand produce-models option setting
       , supportsQuantifiers        :: Bool    -- ^ Does the solver understand SMT-Lib2 style quantifiers?
       , supportsUninterpretedSorts :: Bool    -- ^ Does the solver understand SMT-Lib2 style uninterpreted-sorts
       , supportsUnboundedInts      :: Bool    -- ^ Does the solver support unbounded integers?
       , supportsReals              :: Bool    -- ^ Does the solver support reals?
       , supportsFloats             :: Bool    -- ^ Does the solver support single-precision floating point numbers?
       , supportsDoubles            :: Bool    -- ^ Does the solver support double-precision floating point numbers?
       , supportsOptimization       :: Bool    -- ^ Does the solver support optimization routines?
       , supportsPseudoBooleans     :: Bool    -- ^ Does the solver support pseudo-boolean operations?
       , supportsUnsatCores         :: Bool    -- ^ Does the solver support extraction of unsat-cores?
       , supportsProofs             :: Bool    -- ^ Does the solver support extraction of proofs?
       , supportsCustomQueries      :: Bool    -- ^ Does the solver support interactive queries per SMT-Lib?
       }

-- | Rounding mode to be used for the IEEE floating-point operations.
-- Note that Haskell's default is 'RoundNearestTiesToEven'. If you use
-- a different rounding mode, then the counter-examples you get may not
-- match what you observe in Haskell.
data RoundingMode = RoundNearestTiesToEven  -- ^ Round to nearest representable floating point value.
                                            -- If precisely at half-way, pick the even number.
                                            -- (In this context, /even/ means the lowest-order bit is zero.)
                  | RoundNearestTiesToAway  -- ^ Round to nearest representable floating point value.
                                            -- If precisely at half-way, pick the number further away from 0.
                                            -- (That is, for positive values, pick the greater; for negative values, pick the smaller.)
                  | RoundTowardPositive     -- ^ Round towards positive infinity. (Also known as rounding-up or ceiling.)
                  | RoundTowardNegative     -- ^ Round towards negative infinity. (Also known as rounding-down or floor.)
                  | RoundTowardZero         -- ^ Round towards zero. (Also known as truncation.)
                  deriving (Eq, Ord, Show, Read, G.Data, Bounded, Enum)

-- | 'RoundingMode' kind
instance HasKind RoundingMode

-- | Solver configuration. See also 'z3', 'yices', 'cvc4', 'boolector', 'mathSAT', etc. which are instantiations of this type for those solvers, with
-- reasonable defaults. In particular, custom configuration can be created by varying those values. (Such as @z3{verbose=True}@.)
--
-- Most fields are self explanatory. The notion of precision for printing algebraic reals stems from the fact that such values does
-- not necessarily have finite decimal representations, and hence we have to stop printing at some depth. It is important to
-- emphasize that such values always have infinite precision internally. The issue is merely with how we print such an infinite
-- precision value on the screen. The field 'printRealPrec' controls the printing precision, by specifying the number of digits after
-- the decimal point. The default value is 16, but it can be set to any positive integer.
--
-- When printing, SBV will add the suffix @...@ at the and of a real-value, if the given bound is not sufficient to represent the real-value
-- exactly. Otherwise, the number will be written out in standard decimal notation. Note that SBV will always print the whole value if it
-- is precise (i.e., if it fits in a finite number of digits), regardless of the precision limit. The limit only applies if the representation
-- of the real value is not finite, i.e., if it is not rational.
--
-- The 'printBase' field can be used to print numbers in base 2, 10, or 16. If base 2 or 16 is used, then floating-point values will
-- be printed in their internal memory-layout format as well, which can come in handy for bit-precise analysis.
data SMTConfig = SMTConfig {
         verbose          :: Bool                      -- ^ Debug mode
       , timing           :: Timing                    -- ^ Print timing information on how long different phases took (construction, solving, etc.)
       , sBranchTimeOut   :: Maybe Int                 -- ^ How much time to give to the solver for each call of 'sBranch' check. (In seconds. Default: No limit.)
       , timeOut          :: Maybe Int                 -- ^ How much time to give to the solver. (In seconds. Default: No limit.)
       , printBase        :: Int                       -- ^ Print integral literals in this base (2, 10, and 16 are supported.)
       , printRealPrec    :: Int                       -- ^ Print algebraic real values with this precision. (SReal, default: 16)
       , solverTweaks     :: [String]                  -- ^ Additional lines of script to give to the solver (user specified)
       , optimizeArgs     :: [String]                  -- ^ Additional commands to pass before check-sat is issued
       , satCmd           :: String                    -- ^ Usually "(check-sat)". However, users might tweak it based on solver characteristics.
       , isNonModelVar    :: String -> Bool            -- ^ When constructing a model, ignore variables whose name satisfy this predicate. (Default: (const False), i.e., don't ignore anything)
       , smtFile          :: Maybe FilePath            -- ^ If Just, the generated SMT script will be put in this file (for debugging purposes mostly)
       , smtLibVersion    :: SMTLibVersion             -- ^ What version of SMT-lib we use for the tool
       , solver           :: SMTSolver                 -- ^ The actual SMT solver.
       , roundingMode     :: RoundingMode              -- ^ Rounding mode to use for floating-point conversions
       , solverSetOptions :: [SMTOption]               -- ^ Options to set as we start the solver
       , customQuery      :: Maybe (Query [SMTResult]) -- ^ Custom user-given query
       }

-- We're just seq'ing top-level here, it shouldn't really matter. (i.e., no need to go deeper.)
instance NFData SMTConfig where
  rnf SMTConfig{} = ()

instance Show SMTConfig where
  show = show . solver

-- | A model, as returned by a solver
data SMTModel = SMTModel {
        modelObjectives :: [(String, GeneralizedCW)]  -- ^ Mapping of symbolic values to objective values.
     ,  modelAssocs     :: [(String, CW)]             -- ^ Mapping of symbolic values to constants.
     }
     deriving Show

-- | The result of an SMT solver call. Each constructor is tagged with
-- the 'SMTConfig' that created it so that further tools can inspect it
-- and build layers of results, if needed. For ordinary uses of the library,
-- this type should not be needed, instead use the accessor functions on
-- it. (Custom Show instances and model extractors.)
data SMTResult = Unsatisfiable SMTConfig (Maybe [String]) -- ^ Unsatisfiable, with unsat-core if requested
               | Satisfiable   SMTConfig SMTModel         -- ^ Satisfiable with model
               | SatExtField   SMTConfig SMTModel         -- ^ Prover returned a model, but in an extension field containing Infinite/epsilon
               | Unknown       SMTConfig SMTModel         -- ^ Prover returned unknown, with a potential (possibly bogus) model
               | ProofError    SMTConfig [String]         -- ^ Prover errored out
               | TimeOut       SMTConfig                  -- ^ Computation timed out (see the 'timeout' combinator)

-- | A script, to be passed to the solver.
data SMTScript = SMTScript {
          scriptBody  :: String   -- ^ Initial feed
        , scriptModel :: [String] -- ^ Continuation script, to extract results
        }

-- | An SMT engine
type SMTEngine = SMTConfig                     -- ^ current configuration
               -> QueryContext                 -- ^ the context in which queries will be run (if any)
               -> Bool                         -- ^ is sat?
               -> Maybe (OptimizeStyle, Int)   -- ^ if optimizing, the style and #of objectives
               -> [(Quantifier, NamedSymVar)]  -- ^ quantified inputs
               -> [Either SW (SW, [SW])]       -- ^ skolem map
               -> String                       -- ^ program
               -> IO [SMTResult]

-- | Solvers that SBV is aware of
data Solver = Z3
            | Yices
            | Boolector
            | CVC4
            | MathSAT
            | ABC
            deriving (Show, Enum, Bounded)

-- | An SMT solver
data SMTSolver = SMTSolver {
         name           :: Solver             -- ^ The solver in use
       , executable     :: String             -- ^ The path to its executable
       , options        :: [String]           -- ^ Options to provide to the solver
       , engine         :: SMTEngine          -- ^ The solver engine, responsible for interpreting solver output
       , capabilities   :: SolverCapabilities -- ^ Various capabilities of the solver
       }

instance Show SMTSolver where
   show = show . name

{-# ANN type FPOp ("HLint: ignore Use camelCase" :: String) #-}
{-# ANN type PBOp ("HLint: ignore Use camelCase" :: String) #-}