module HaskellWorks.Data.Dsv.Lazy.Cursor
  ( DsvCursor (..)
  , makeCursor
  , snippet
  , trim
  , atEnd
  , nextField
  , nextRow
  , nextPosition
  , getRowBetween
  , toListVector
  , toVectorVector
  ) where

import Data.Function
import Data.Word
import GHC.Word                                   (Word8)
import HaskellWorks.Data.Drop
import HaskellWorks.Data.Dsv.Internal.Bits
import HaskellWorks.Data.Dsv.Lazy.Cursor.Internal
import HaskellWorks.Data.Dsv.Lazy.Cursor.Type
import HaskellWorks.Data.Positioning
import HaskellWorks.Data.RankSelect.Base.Rank1
import HaskellWorks.Data.RankSelect.Base.Select1
import HaskellWorks.Data.Vector.AsVector64
import Prelude                                    hiding (drop)

import qualified Data.ByteString.Lazy                   as LBS
import qualified Data.Vector                            as DV
import qualified Data.Vector.Storable                   as DVS
import qualified HaskellWorks.Data.ByteString           as BS
import qualified HaskellWorks.Data.ByteString.Lazy      as LBS
import qualified HaskellWorks.Data.Dsv.Internal.Char    as C
import qualified HaskellWorks.Data.Dsv.Internal.Vector  as DVS
import qualified HaskellWorks.Data.Simd.ChunkString     as CS
import qualified HaskellWorks.Data.Simd.Comparison.Avx2 as SIMD
import qualified Prelude                                as P

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
  , dsvCursorMarkers   = ib
  , dsvCursorNewlines  = nls
  , dsvCursorPosition  = 0
  }
  where ibq = asVector64 <$> BS.rechunk 512 (BS.toByteStrings (SIMD.cmpEqWord8s C.doubleQuote cs))
        ibn = asVector64 <$> BS.rechunk 512 (BS.toByteStrings (SIMD.cmpEqWord8s C.newline     cs))
        ibd = asVector64 <$> BS.rechunk 512 (BS.toByteStrings (SIMD.cmpEqWord8s delimiter     cs))
        (ib, nls) = makeIndexes ibd ibn ibq

snippet :: DsvCursor -> LBS.ByteString
snippet c = LBS.take (len `max` 0) $ LBS.drop posC $ dsvCursorText c
  where d = nextField c
        posC = fromIntegral $ dsvCursorPosition c
        posD = fromIntegral $ dsvCursorPosition d
        len  = posD - posC
{-# INLINE snippet #-}

lvDrop :: DVS.Storable a => Int -> [DVS.Vector a] -> [DVS.Vector a]
lvDrop n (v:vs) = if n < DVS.length v
  then DVS.drop n v:vs
  else lvDrop (n - DVS.length v) vs
lvDrop _ [] = []

trim :: DsvCursor -> DsvCursor
trim c = if dsvCursorPosition c >= 512
  then trim c
    { dsvCursorText     = LBS.drop 512 (dsvCursorText c)
    , dsvCursorMarkers  = lvDrop 8 (dsvCursorMarkers c)
    , dsvCursorNewlines = lvDrop 8 (dsvCursorNewlines c)
    , dsvCursorPosition = dsvCursorPosition c - 512
    }
  else c
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
