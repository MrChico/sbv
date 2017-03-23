-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Tools.GenTest
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Test generation from symbolic programs
-----------------------------------------------------------------------------

module Data.SBV.Tools.GenTest (
        -- * Test case generation
        genTest, TestVectors, getTestValues, renderTest, TestStyle(..)
        ) where

import Data.Bits     (testBit)
import Data.Char     (isAlpha, toUpper)
import Data.Function (on)
import Data.List     (intercalate, groupBy)
import Data.Maybe    (fromMaybe)
import System.Random

import Data.SBV.BitVectors.AlgReals
import Data.SBV.BitVectors.Data
import Data.SBV.BitVectors.PrettyNum

-- | Type of test vectors (abstract)
newtype TestVectors = TV [([CW], [CW])]

-- | Retrieve the test vectors for further processing. This function
-- is useful in cases where 'renderTest' is not sufficient and custom
-- output (or further preprocessing) is needed.
getTestValues :: TestVectors -> [([CW], [CW])]
getTestValues (TV vs) = vs

-- | Generate a set of concrete test values from a symbolic program. The output
-- can be rendered as test vectors in different languages as necessary. Use the
-- function 'output' call to indicate what fields should be in the test result.
-- (Also see 'constrain' and 'pConstrain' for filtering acceptable test values.)
genTest :: Outputtable a => Int -> Symbolic a -> IO TestVectors
genTest n m = gen 0 []
  where gen i sofar
         | i == n = return $ TV $ reverse sofar
         | True   = do g <- newStdGen
                       t <- tc g
                       gen (i+1) (t:sofar)
        tc g = do (_, Result _ tvals _ _ cs _ _ _ _ _ cstrs _ _ os) <- runSymbolic' (Concrete g) (m >>= output)
                  let cval = fromMaybe (error "Cannot generate tests in the presence of uninterpeted constants!") . (`lookup` cs)
                      cond = all (cwToBool . cval) cstrs
                  if cond
                     then return (map snd tvals, map cval os)
                     else tc g  -- try again, with the same set of constraints

-- | Test output style
data TestStyle = Haskell String                     -- ^ As a Haskell value with given name
               | C       String                     -- ^ As a C array of structs with given name
               | Forte   String Bool ([Int], [Int]) -- ^ As a Forte/Verilog value with given name.
                                                    -- If the boolean is True then vectors are blasted big-endian, otherwise little-endian
                                                    -- The indices are the split points on bit-vectors for input and output values

-- | Render the test as a Haskell value with the given name @n@.
renderTest :: TestStyle -> TestVectors -> String
renderTest (Haskell n)    (TV vs) = haskell n vs
renderTest (C n)          (TV vs) = c       n vs
renderTest (Forte n b ss) (TV vs) = forte   n b ss vs

haskell :: String -> [([CW], [CW])] -> String
haskell vname vs = intercalate "\n" $ [ "-- Automatically generated by SBV. Do not edit!"
                                      , ""
                                      , "module " ++ modName ++ "(" ++ n ++ ") where"
                                      , ""
                                      ]
                                   ++ imports
                                   ++ [ n ++ " :: " ++ getType vs
                                      , n ++ " = [ " ++ intercalate ("\n" ++ pad ++  ", ") (map mkLine vs), pad ++ "]"
                                      ]
  where n | null vname                 = "testVectors"
          | not (isAlpha (head vname)) = "tv" ++ vname
          | True                       = vname
        imports
          | null vs               = []
          | needsInt && needsWord = ["import Data.Int", "import Data.Word", ""]
          | needsInt              = ["import Data.Int", ""]
          | needsWord             = ["import Data.Word", ""]
          | needsRatio            = ["import Data.Ratio"]
          | True                  = []
          where ((is, os):_) = vs
                params       = is ++ os
                needsInt     = any isSW params
                needsWord    = any isUW params
                needsRatio   = any isR params
                isR cw       = case kindOf cw of
                                 KReal -> True
                                 _     -> False
                isSW cw      = case kindOf cw of
                                 KBounded True _ -> True
                                 _               -> False
                isUW cw      = case kindOf cw of
                                 KBounded False sz -> sz > 1
                                 _                 -> False
        modName = let (f:r) = n in toUpper f : r
        pad = replicate (length n + 3) ' '
        getType []         = "[a]"
        getType ((i, o):_) = "[(" ++ mapType typeOf i ++ ", " ++ mapType typeOf o ++ ")]"
        mkLine  (i, o)     = "("  ++ mapType valOf  i ++ ", " ++ mapType valOf  o ++ ")"
        mapType f cws = mkTuple $ map f $ groupBy ((==) `on` kindOf) cws
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        typeOf []    = "()"
        typeOf [x]   = t x
        typeOf (x:_) = "[" ++ t x ++ "]"
        valOf  []    = "()"
        valOf  [x]   = s x
        valOf  xs    = "[" ++ intercalate ", " (map s xs) ++ "]"
        t cw = case kindOf cw of
                 KBool             -> "Bool"
                 KBounded False 8  -> "Word8"
                 KBounded False 16 -> "Word16"
                 KBounded False 32 -> "Word32"
                 KBounded False 64 -> "Word64"
                 KBounded True  8  -> "Int8"
                 KBounded True  16 -> "Int16"
                 KBounded True  32 -> "Int32"
                 KBounded True  64 -> "Int64"
                 KUnbounded        -> "Integer"
                 KFloat            -> "Float"
                 KDouble           -> "Double"
                 KReal             -> error $ "SBV.renderTest: Unsupported real valued test value: " ++ show cw
                 KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                 _                 -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        s cw = case kindOf cw of
                  KBool             -> take 5 (show (cwToBool cw) ++ repeat ' ')
                  KBounded sgn   sz -> let CWInteger w = cwVal cw in shex  False True (sgn, sz) w
                  KUnbounded        -> let CWInteger w = cwVal cw in shexI False True           w
                  KFloat            -> let CWFloat w   = cwVal cw in showHFloat w
                  KDouble           -> let CWDouble w  = cwVal cw in showHDouble w
                  KReal             -> let CWAlgReal w = cwVal cw in algRealToHaskell w
                  KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us

c :: String -> [([CW], [CW])] -> String
c n vs = intercalate "\n" $
              [ "/* Automatically generated by SBV. Do not edit! */"
              , ""
              , "#include <stdio.h>"
              , "#include <inttypes.h>"
              , "#include <stdint.h>"
              , "#include <stdbool.h>"
              , "#include <string.h>"
              , "#include <math.h>"
              , ""
              , "/* The boolean type */"
              , "typedef bool SBool;"
              , ""
              , "/* The float type */"
              , "typedef float SFloat;"
              , ""
              , "/* The double type */"
              , "typedef double SDouble;"
              , ""
              , "/* Unsigned bit-vectors */"
              , "typedef uint8_t  SWord8 ;"
              , "typedef uint16_t SWord16;"
              , "typedef uint32_t SWord32;"
              , "typedef uint64_t SWord64;"
              , ""
              , "/* Signed bit-vectors */"
              , "typedef int8_t  SInt8 ;"
              , "typedef int16_t SInt16;"
              , "typedef int32_t SInt32;"
              , "typedef int64_t SInt64;"
              , ""
              , "typedef struct {"
              , "  struct {"
              ]
           ++ (if null vs then [] else zipWith (mkField "i") (fst (head vs)) [(0::Int)..])
           ++ [ "  } input;"
              , "  struct {"
              ]
           ++ (if null vs then [] else zipWith (mkField "o") (snd (head vs)) [(0::Int)..])
           ++ [ "  } output;"
              , "} " ++ n ++ "TestVector;"
              , ""
              , n ++ "TestVector " ++ n ++ "[] = {"
              ]
           ++ ["      " ++ intercalate "\n    , " (map mkLine vs)]
           ++ [ "};"
              , ""
              , "int " ++ n ++ "Length = " ++ show (length vs) ++ ";"
              , ""
              , "/* Stub driver showing the test values, replace with code that uses the test vectors. */"
              , "int main(void)"
              , "{"
              , "  int i;"
              , "  for(i = 0; i < " ++ n ++ "Length; ++i)"
              , "  {"
              , "    " ++ outLine
              , "  }"
              , ""
              , "  return 0;"
              , "}"
              ]
  where mkField p cw i = "    " ++ t ++ " " ++ p ++ show i ++ ";"
            where t = case kindOf cw of
                        KBool             -> "SBool"
                        KBounded False 8  -> "SWord8"
                        KBounded False 16 -> "SWord16"
                        KBounded False 32 -> "SWord32"
                        KBounded False 64 -> "SWord64"
                        KBounded True  8  -> "SInt8"
                        KBounded True  16 -> "SInt16"
                        KBounded True  32 -> "SInt32"
                        KBounded True  64 -> "SInt64"
                        KFloat            -> "SFloat"
                        KDouble           -> "SDouble"
                        KUnbounded        -> error "SBV.renderTest: Unbounded integers are not supported when generating C test-cases."
                        KReal             -> error "SBV.renderTest: Real values are not supported when generating C test-cases."
                        KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                        _                 -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        mkLine (is, os) = "{{" ++ intercalate ", " (map v is) ++ "}, {" ++ intercalate ", " (map v os) ++ "}}"
        v cw = case kindOf cw of
                  KBool           -> if cwToBool cw then "true " else "false"
                  KBounded sgn sz -> let CWInteger w = cwVal cw in shex  False True (sgn, sz) w
                  KUnbounded      -> let CWInteger w = cwVal cw in shexI False True           w
                  KFloat          -> let CWFloat w   = cwVal cw in showCFloat w
                  KDouble         -> let CWDouble w  = cwVal cw in showCDouble w
                  KUserSort us _  -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                  KReal           -> error "SBV.renderTest: Real values are not supported when generating C test-cases."
        outLine
          | null vs = "printf(\"\");"
          | True    = "printf(\"%*d. " ++ fmtString ++ "\\n\", " ++ show (length (show (length vs - 1))) ++ ", i"
                    ++ concatMap ("\n           , " ++ ) (zipWith inp is [(0::Int)..] ++ zipWith out os [(0::Int)..])
                    ++ ");"
          where (is, os) = head vs
                inp cw i = mkBool cw (n ++ "[i].input.i"  ++ show i)
                out cw i = mkBool cw (n ++ "[i].output.o" ++ show i)
                mkBool cw s = case kindOf cw of
                                KBool -> "(" ++ s ++ " == true) ? \"true \" : \"false\""
                                _     -> s
                fmtString = unwords (map fmt is) ++ " -> " ++ unwords (map fmt os)
        fmt cw = case kindOf cw of
                    KBool             -> "%s"
                    KBounded False  8 -> "0x%02\"PRIx8\""
                    KBounded False 16 -> "0x%04\"PRIx16\"U"
                    KBounded False 32 -> "0x%08\"PRIx32\"UL"
                    KBounded False 64 -> "0x%016\"PRIx64\"ULL"
                    KBounded True   8 -> "%\"PRId8\""
                    KBounded True  16 -> "%\"PRId16\""
                    KBounded True  32 -> "%\"PRId32\"L"
                    KBounded True  64 -> "%\"PRId64\"LL"
                    KFloat            -> "%f"
                    KDouble           -> "%f"
                    KUnbounded        -> error "SBV.renderTest: Unsupported unbounded integers for C generation."
                    KReal             -> error "SBV.renderTest: Unsupported real valued values for C generation."
                    _                 -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw

forte :: String -> Bool -> ([Int], [Int]) -> [([CW], [CW])] -> String
forte vname bigEndian ss vs = intercalate "\n" $ [ "// Automatically generated by SBV. Do not edit!"
                                             , "let " ++ n ++ " ="
                                             , "   let c s = val [_, r] = str_split s \"'\" in " ++ blaster
                                             ]
                                          ++ [ "   in [ " ++ intercalate "\n      , " (map mkLine vs)
                                             , "      ];"
                                             ]
  where n | null vname                 = "testVectors"
          | not (isAlpha (head vname)) = "tv" ++ vname
          | True                       = vname
        blaster
         | bigEndian = "map (\\s. s == \"1\") (explode (string_tl r))"
         | True      = "rev (map (\\s. s == \"1\") (explode (string_tl r)))"
        toF True  = '1'
        toF False = '0'
        blast cw = case kindOf cw of
                     KBool             -> [toF (cwToBool cw)]
                     KBounded False 8  -> xlt  8 (cwVal cw)
                     KBounded False 16 -> xlt 16 (cwVal cw)
                     KBounded False 32 -> xlt 32 (cwVal cw)
                     KBounded False 64 -> xlt 64 (cwVal cw)
                     KBounded True 8   -> xlt  8 (cwVal cw)
                     KBounded True 16  -> xlt 16 (cwVal cw)
                     KBounded True 32  -> xlt 32 (cwVal cw)
                     KBounded True 64  -> xlt 64 (cwVal cw)
                     KFloat            -> error "SBV.renderTest: Float values are not supported when generating Forte test-cases."
                     KDouble           -> error "SBV.renderTest: Double values are not supported when generating Forte test-cases."
                     KReal             -> error "SBV.renderTest: Real values are not supported when generating Forte test-cases."
                     KUnbounded        -> error "SBV.renderTest: Unbounded integers are not supported when generating Forte test-cases."
                     _                 -> error $ "SBV.renderTest: Unexpected CW: " ++ show cw
        xlt s (CWInteger v)   = [toF (testBit v i) | i <- [s-1, s-2 .. 0]]
        xlt _ (CWFloat r)     = error $ "SBV.renderTest.Forte: Unexpected float value: " ++ show r
        xlt _ (CWDouble r)    = error $ "SBV.renderTest.Forte: Unexpected double value: " ++ show r
        xlt _ (CWAlgReal r)   = error $ "SBV.renderTest.Forte: Unexpected real value: " ++ show r
        xlt _ (CWUserSort r)  = error $ "SBV.renderTest.Forte: Unexpected uninterpreted value: " ++ show r
        mkLine  (i, o) = "("  ++ mkTuple (form (fst ss) (concatMap blast i)) ++ ", " ++ mkTuple (form (snd ss) (concatMap blast o)) ++ ")"
        mkTuple []  = "()"
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        form []     [] = []
        form []     bs = error $ "SBV.renderTest: Mismatched index in stream, extra " ++ show (length bs) ++ " bit(s) remain."
        form (i:is) bs
          | length bs < i = error $ "SBV.renderTest: Mismatched index in stream, was looking for " ++ show i ++ " bit(s), but only " ++ show i ++ " remains."
          | i == 1        = let b:r = bs
                                v   = if b == '1' then "T" else "F"
                            in v : form is r
          | True          = let (f, r) = splitAt i bs
                                v      = "c \"" ++ show i ++ "'b" ++ f ++ "\""
                            in v : form is r
