module HaskellWorks.Data.Dsv.Lazy.Cursor
  ( DsvCursor (..)
  , makeCursor
  , snippet
  , trim
  , atEnd
  , nextField
  , advanceField
  , nextRow
  , nextPosition
  , toListVector
  , toVectorVector
  , selectListVector
  , getRowBetweenStrict
  , toListVectorStrict
  ) where

import Data.Function
import Data.Word
import GHC.Word                                      (Word8)
import HaskellWorks.Data.Drop
import HaskellWorks.Data.Dsv.Internal.BitString.Lazy
import HaskellWorks.Data.Dsv.Lazy.Cursor.Type
import HaskellWorks.Data.Positioning
import HaskellWorks.Data.RankSelect.Base.Rank1
import HaskellWorks.Data.RankSelect.Base.Select1
import Prelude                                       hiding (drop)

import qualified Data.ByteString                        as BS
import qualified Data.ByteString.Lazy                   as LBS
import qualified Data.Vector                            as DV
import qualified Data.Vector.Storable                   as DVS
import qualified HaskellWorks.Data.ByteString           as BS
import qualified HaskellWorks.Data.ByteString.Lazy      as LBS
import qualified HaskellWorks.Data.Dsv.Internal.Char    as C
import qualified HaskellWorks.Data.Dsv.Internal.Vector  as DVS
import qualified HaskellWorks.Data.Simd.ChunkString     as CS
import qualified HaskellWorks.Data.Simd.Comparison.Avx2 as SIMD

makeIndexes :: [DVS.Vector Word64] -> [DVS.Vector Word64] -> [DVS.Vector Word64] -> ([DVS.Vector Word64], [DVS.Vector Word64])
makeIndexes ds ns qs = unzip $ go 0 0 ds ns qs
  where go pc carry (dv:dvs) (nv:nvs) (qv:qvs) =
          let (dv', nv', pc', carry') = DVS.indexCsvChunk pc carry dv nv qv in
          (dv', nv'):go pc' carry' dvs nvs qvs
        go _ _ [] [] [] = []
        go _ _ _ _ _ = error "Unbalanced inputs"

makeCursor :: Word8 -> CS.ChunkString -> DsvCursor
makeCursor delimiter cs = DsvCursor
  { dsvCursorText      = LBS.toLazyByteString cs
  , dsvCursorMarkers   = toBitString ib
  , dsvCursorNewlines  = toBitString nls
  , dsvCursorPosition  = 0
  }
  where ibq = DVS.unsafeToVector64 <$> BS.toByteStrings (SIMD.cmpEqWord8s C.doubleQuote cs)
        ibn = DVS.unsafeToVector64 <$> BS.toByteStrings (SIMD.cmpEqWord8s C.newline     cs)
        ibd = DVS.unsafeToVector64 <$> BS.toByteStrings (SIMD.cmpEqWord8s delimiter     cs)
        (ib, nls) = makeIndexes ibd ibn ibq

snippet :: DsvCursor -> LBS.ByteString
snippet c = LBS.take (len `max` 0) $ LBS.drop posC $ dsvCursorText c
  where d = nextField c
        posC = fromIntegral $ dsvCursorPosition c
        posD = fromIntegral $ dsvCursorPosition d
        len  = posD - posC
{-# INLINE snippet #-}

trim :: DsvCursor -> DsvCursor
trim c = if dsvCursorPosition c >= 512
  then trim c
    { dsvCursorText     = LBS.drop skipTextLen (dsvCursorText c)
    , dsvCursorMarkers  = drop (fromIntegral skipIdxLen) (dsvCursorMarkers c)
    , dsvCursorNewlines = drop (fromIntegral skipIdxLen) (dsvCursorNewlines c)
    , dsvCursorPosition = dsvCursorPosition c - fromIntegral skipTextLen
    }
  else c
  where skipTextLen = fromIntegral $ (dsvCursorPosition c `div` 512) * 512
        skipIdxLen  = skipTextLen `div` 64
{-# INLINE trim #-}

atEnd :: DsvCursor -> Bool
atEnd c = LBS.null (LBS.drop (fromIntegral (dsvCursorPosition c)) (dsvCursorText c))
{-# INLINE atEnd #-}

nextField :: DsvCursor -> DsvCursor
nextField cursor = cursor
  { dsvCursorPosition = newPos
  }
  where currentRank = rank1   (dsvCursorMarkers cursor) (dsvCursorPosition cursor)
        newPos      = select1 (dsvCursorMarkers cursor) (currentRank + 1) - 1
{-# INLINE nextField #-}

advanceField :: Count -> DsvCursor -> DsvCursor
advanceField n cursor = cursor
  { dsvCursorPosition = newPos
  }
  where currentRank = rank1   (dsvCursorMarkers cursor) (dsvCursorPosition cursor)
        newPos      = select1 (dsvCursorMarkers cursor) (currentRank + n) - 1
{-# INLINE advanceField #-}

nextRow :: DsvCursor -> DsvCursor
nextRow cursor = cursor
  { dsvCursorPosition = if newPos > dsvCursorPosition cursor
                          then newPos
                          else fromIntegral (LBS.length (dsvCursorText cursor))

  }
  where currentRank = rank1   (dsvCursorNewlines cursor) (dsvCursorPosition cursor)
        newPos      = select1 (dsvCursorNewlines cursor) (currentRank + 1) - 1
{-# INLINE nextRow #-}

nextPosition :: DsvCursor -> DsvCursor
nextPosition cursor = cursor
    { dsvCursorPosition = if LBS.null (LBS.drop (fromIntegral newPos) (dsvCursorText cursor))
                            then fromIntegral (LBS.length (dsvCursorText cursor))
                            else newPos
    }
  where newPos  = dsvCursorPosition cursor + 1
{-# INLINE nextPosition #-}

getRowBetween :: DsvCursor -> DsvCursor -> Bool -> DV.Vector LBS.ByteString
getRowBetween c d dEnd = DV.unfoldrN fields go c
  where cr  = rank1 (dsvCursorMarkers c) (dsvCursorPosition c)
        dr  = rank1 (dsvCursorMarkers d) (dsvCursorPosition d)
        c2d = fromIntegral (dr - cr)
        fields = if dEnd then c2d +1 else c2d
        go :: DsvCursor -> Maybe (LBS.ByteString, DsvCursor)
        go e = case nextField e of
          f -> case nextPosition f of
            g -> case snippet e of
              s -> Just (s, g)
        {-# INLINE go #-}
{-# INLINE getRowBetween #-}

toListVector :: DsvCursor -> [DV.Vector LBS.ByteString]
toListVector c = if dsvCursorPosition d > dsvCursorPosition c && not (atEnd c)
  then getRowBetween c d dEnd:toListVector (trim d)
  else []
  where nr = nextRow c
        d = nextPosition nr
        dEnd = atEnd nr
{-# INLINE toListVector #-}

toVectorVector :: DsvCursor -> DV.Vector (DV.Vector LBS.ByteString)
toVectorVector = DV.fromList . toListVector
{-# INLINE toVectorVector #-}

selectRowFrom :: [Int] -> DsvCursor -> [LBS.ByteString]
selectRowFrom sel c = go <$> sel
  where go :: Int -> LBS.ByteString
        go n = snippet nc
          where nc = nextPosition (advanceField (fromIntegral n) c)
        {-# INLINE go #-}
{-# INLINE selectRowFrom #-}

selectListVector :: [Int] -> DsvCursor -> [[LBS.ByteString]]
selectListVector sel c = if dsvCursorPosition d > dsvCursorPosition c && not (atEnd c)
  then selectRowFrom sel c:selectListVector sel (trim d)
  else []
  where nr = nextRow c
        d = nextPosition nr
{-# INLINE selectListVector #-}

getRowBetweenStrict :: DsvCursor -> DsvCursor -> Bool -> DV.Vector BS.ByteString
getRowBetweenStrict c d dEnd = DV.unfoldrN fields go c
  where bsA = fromIntegral $ dsvCursorPosition c
        bsZ = fromIntegral $ dsvCursorPosition d
        bsT = dsvCursorText c
        bs  = LBS.toStrict $ LBS.take (bsZ - bsA) (LBS.drop bsA bsT)

        cr  = rank1 (dsvCursorMarkers c) (dsvCursorPosition c)
        dr  = rank1 (dsvCursorMarkers d) (dsvCursorPosition d)
        c2d = fromIntegral (dr - cr)
        fields = if dEnd then c2d +1 else c2d
        go :: DsvCursor -> Maybe (BS.ByteString, DsvCursor)
        go e = case nextField e of
          f -> case nextPosition f of
            g -> case snippetStrict e (fromIntegral bsA) bs of
              s -> Just (s, g)
        {-# INLINE go #-}
{-# INLINE getRowBetweenStrict #-}

snippetStrict :: DsvCursor -> Int -> BS.ByteString -> BS.ByteString
snippetStrict c offset bs = BS.take (len `max` 0) $ BS.drop posC $ bs
  where d = nextField c
        posC = fromIntegral (dsvCursorPosition c) - offset
        posD = fromIntegral (dsvCursorPosition d) - offset
        len  = posD - posC
{-# INLINE snippetStrict #-}

toListVectorStrict :: DsvCursor -> [DV.Vector BS.ByteString]
toListVectorStrict c = if dsvCursorPosition d > dsvCursorPosition c && not (atEnd c)
  then getRowBetweenStrict c d dEnd:toListVectorStrict (trim d)
  else []
  where nr = nextRow c
        d = nextPosition nr
        dEnd = atEnd nr
{-# INLINE toListVectorStrict #-}
