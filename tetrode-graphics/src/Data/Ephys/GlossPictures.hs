{-|
Module      : Data.Ephys.GlossPictures
Description : Gloss rendering for Ephys types
Copyright   : (c) Greg Hale, 2015
                  Shea Levy, 2015
License     : BSD3
Maintainer  : imalsogreg@gmail.com
Stability   : experimental
Portability : GHC, Linux
-}

{-# LANGUAGE NoMonomorphismRestriction #-}

module Data.Ephys.GlossPictures where

------------------------------------------------------------------------------
import           Control.Arrow (second)
import           Graphics.Gloss
import qualified Data.List      as List
import qualified Data.Map       as Map
import           Data.Ord       (comparing)
import qualified Data.Vector    as V
import           Control.Lens
import           Text.Printf
------------------------------------------------------------------------------
import           Data.Ephys.Position
import           Data.Ephys.TrackPosition
import           Data.Ephys.Spike



------------------------------------------------------------------------------
-- | Picture of a single track pos. (units: Meters)
trackPosPicture :: TrackPos -> Picture
trackPosPicture (TrackPos bin bir ecc) = trackBinFrame bin lineLoop

-- | Drawing-style flexible picture for a single track bin (units: Meters)
trackBinFrame :: TrackBin  -- ^ Bin to draw
              -> ([(Float,Float)] -> Picture) -- ^ Drawing method
              -> Picture
trackBinFrame b f = trackBinFrameDilated b f 1

-- | Draw a track bin widened (e.g. for 'out-of-bounds' pictures)
trackBinFrameDilated :: TrackBin -> ([(Float,Float)] -> Picture) -> Float
                        -> Picture
trackBinFrameDilated (TrackBin _ (Location lx ly _) dir bStart bEnd w caps)
  picType d =
  case caps of
    CapFlat (inAngle,outAngle) ->
      let inNudge   = r2 $ r2 w * 0.5 * sin inAngle * r2 d
          outNudge  = r2 $ r2 w * 0.5 * sin outAngle * r2 d
          backLow   = (r2 bStart + inNudge, r2 w /(-2) * d)
          backHigh  = (r2 bStart - inNudge, r2 w /2 * d)
          frontLow  = (r2 bEnd + outNudge,  r2 w /(-2) * d)
          frontHigh = (r2 bEnd - outNudge,  r2 w /2 * d)
      in Translate (r2 lx) (r2 ly) $ Rotate (rad2Deg $ r2 dir) $
         picType [backLow,backHigh,frontHigh,frontLow]
    CapCircle -> translate (r2 lx) (r2 ly) $ circle (r2 w)

-- | Draw all track bins an their outbound directions (units: Meters)
drawTrack :: Track -> Picture
drawTrack t =
  pictures $ map (flip trackBinFrame lineLoop) (t ^. trackBins) --  ++ map binArrow (t^. trackBins)
  where binArrow bin = drawArrowFloat (r2 $ bin^.binLoc.x, r2 $ bin^.binLoc.y)
                       ((r2 $ bin^.binZ - bin^.binA)/2)
                       (rad2Deg . r2 $ bin^.binDir) 0.01 0.08 0.04

-- | Draw an arrow
drawArrowFloat :: (Float,Float) -- ^ Origin
               -> Float         -- ^ Length
               -> Float         -- ^ Angle (radians)
               -> Float         -- ^ Thickness
               -> Float         -- ^ Head length
               -> Float         -- ^ Head thickness
               -> Picture
drawArrowFloat (baseX,baseY) mag ang thickness headLen headThickness =
  let body = Polygon [(0, - thickness/2)
                     ,(mag - headLen, - thickness/2)
                     ,(mag,0)
                     ,(mag - headLen, thickness/2)
                     ,(0, thickness/2)]
      aHead = Polygon [(mag - headLen, - headThickness/2)
                     ,(mag,0)
                     ,(mag - headLen, headThickness/2)]
  in Translate baseX baseY . Rotate ang $ pictures [body,aHead]

-- | Draw a single valued track pos
drawTrackPos :: TrackPos
             -> Float  -- ^ Value at pos (0 to 1)
             -> Picture
drawTrackPos (TrackPos bin dir ecc) alpha =
--  Color (setAlpha col alpha) $
  Color (setAlpha col (0.1)) $
  trackBinFrameDilated bin Polygon dilation
  where
    baseCol  = if dir == Outbound then blue    else red
    col      = if ecc == InBounds then baseCol else addColors baseCol green
    dilation = if ecc == InBounds then 1 else 2

-- | Draw rat's current position as an arrow (units: Meters)
drawPos :: Position -> Picture
drawPos p = drawArrowFloat
            (r2 $ p^.location.x, r2 $ p^.location.y)
            (r2 $ p^.speed) (rad2Deg . r2 $ p^.heading)
            0.01 0.08 0.04

-- | Draw an entire field (all valued track positions)
drawField :: LabeledField Double -> Picture
drawField field =
  pictures . map (uncurry drawTrackPos) $
  map (second r2) (V.toList field)

-- | Draw an entire field (all valued track positions),
--   first normalizing the sum of all values to 1
drawNormalizedField :: LabeledField Double -> Picture
drawNormalizedField field =
  pictures $ map (uncurry drawTrackPos .
    second ((*fMax) . r2)) $ V.toList field
    where fMax :: Float
          fMax = r2 $ 1 / V.foldl' (\a (_,v) -> max a v ) 0.1 field

labelNormalizedField :: LabeledField Double -> Picture
labelNormalizedField field =
  pictures . map labelTrackPos . V.toList $ field

------------------------------------------------------------------------------
labelTrackPos :: (TrackPos, Double) -> Picture
labelTrackPos (TrackPos (TrackBin _ (Location x y _) _ _ _ _ _ ) dir ecc,v) =
  translate (r2 x) (r2 y+offsetY)
  . scale 0.0006 0.0006 . Text . take 4
  $ show v
  where
    c = 0.04
    offsetY = case (dir,ecc) of
          (Outbound,InBounds)    ->  3 * c
          (Inbound, InBounds)    ->  1 * c
          (Outbound,OutOfBounds) -> -1 * c
          (Inbound, OutOfBounds) -> -3 * c

-- | Override a color's alpha component (0 to 1)
setAlpha :: Color -> Float -> Color
setAlpha c alpha = case rgbaOfColor c of
  (r,g,b,_) -> makeColor r g b alpha

writePos :: Position -> String
writePos pos = printf "Conf: %s  T: %f  x: %f  y: %f  (Pos)\n"
               (show $ pos^.posConfidence)(pos^.posTime)(pos^.location.x)(pos^.location.y)

writeField :: LabeledField Double -> String
writeField labeledField =
  printf "x: %f  y: %f  dir: %s (TrackPos)\n" tX tY tD
  where
    f = V.toList labeledField
    modePos = fst . List.head . List.sortBy (comparing snd) $ f
    tX = modePos^.trackBin.binLoc.x
    tY = modePos^.trackBin.binLoc.y
    tD = show $ modePos^.trackDir


------------------------------------------------------------------------------
rad2Deg :: Float -> Float
rad2Deg = (* (-180 / pi))

------------------------------------------------------------------------------
r2 :: (Real a, Fractional b) => a -> b
r2 = realToFrac
{-# SPECIALIZE r2 :: Double -> Float #-}
