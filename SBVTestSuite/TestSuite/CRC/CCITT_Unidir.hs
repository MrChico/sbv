-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.CRC.CCITT_Unidir
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Test suite for Examples.CRC.CCITT_Unidir
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}

module TestSuite.CRC.CCITT_Unidir(tests) where

import Data.SBV.Tools.Polynomial
import Utils.SBVTestFramework

-- Test suite
tests :: TestTree
tests =
  testGroup "CCITT_Unidir"
    [   testCase "ccitHDis3" (assertIsThm   (crcUniGood 3))
      , testCase "ccitHDis4" (assertIsntThm (crcUniGood 4))
    ]

extendData :: SWord 48 -> SWord64
extendData msg = fromBitsBE $ blastBE msg ++ replicate 16 sFalse

mkFrame :: SWord 48 -> SWord64
mkFrame msg = fromBitsBE $ blastBE msg ++ blastBE (crc_48_16 msg)

crc_48_16 :: SWord 48 -> SWord16
crc_48_16 msg = res
  where msg64, divisor :: SWord64
        msg64   = extendData msg
        divisor = polynomial [16, 12, 5, 0]
        crc64 = pMod msg64 divisor
        (_, res) = split (snd (split crc64))

diffCount :: [SBool] -> [SBool] -> SWord8
diffCount xs ys = count $ zipWith (.==) xs ys
  where count []     = 0
        count (b:bs) = let r = count bs in ite b r (1+r)

-- returns true if there's a 0->1 error (1->0 is ok)
nonUnidir :: [SBool] -> [SBool] -> SBool
nonUnidir []     _      = sFalse
nonUnidir _      []     = sTrue
nonUnidir (a:as) (b:bs) = (sNot a .&& b) .|| nonUnidir as bs

crcUniGood :: SWord8 -> SWord 48 -> SWord 48 -> SBool
crcUniGood hd sent received =
     sent ./= received .=> nonUnidir frameSent frameReceived .|| diffCount frameSent frameReceived .> hd
   where frameSent     = blastLE $ mkFrame sent
         frameReceived = blastLE $ mkFrame received

{-# ANN crc_48_16 ("HLint: ignore Use camelCase" :: String) #-}
