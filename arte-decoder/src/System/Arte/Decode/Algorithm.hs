{-# LANGUAGE BangPatterns    #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE QuasiQuotes #-}

module System.Arte.Decode.Algorithm where

------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Lens
import           Control.Monad
import qualified Data.List                as L
import qualified Data.Map.Strict          as Map
import           Data.Time.Clock
import qualified Data.Vector.Unboxed      as U
import qualified Data.Vector              as V
import           System.IO
import           System.Mem (performGC)
import           Network.IP.Quoter
import           Network.Socket
import           Data.Serialize
import           Data.Fixed
------------------------------------------------------------------------------
import           Data.Ephys.EphysDefs
import           Data.Map.KDMap
import qualified Data.Map.KDMap                   as KDMap
import           Data.Ephys.PlaceCell
import           Data.Ephys.TrackPosition
import qualified System.Arte.Decode.Histogram    as H
import           System.Arte.Decode.Types
import           System.Arte.Decode.Config
import           System.Arte.TimeSync
import           System.Arte.NetworkTime
import           Network.Socket
import qualified Network.Socket.ByteString as BS


------------------------------------------------------------------------------
pcFieldRate :: Field -> Field -> Field
pcFieldRate occ field = V.zipWith (/) field occ


------------------------------------------------------------------------------
runClusterReconstruction :: DecoderArgs -> Double ->
                      TVar DecoderState -> Maybe Handle ->
                      IO ()
runClusterReconstruction args rTauSec dsT h = do
  ds <- readTVarIO $ dsT
  t0 <- getCurrentTime
  sock <- initSock
  let opts = undefined
  (timeSyncState, tID) <- setupTimeSync opts
  let occT = ds ^. occupancy
      Clustered clusteredTrodes = ds^.trodes
      go lastFields binStartTime = do
        let binEndTime = addUTCTime (realToFrac rTauSec) binStartTime
        -- H.timeAction (ds^.decodeProf) $ do  -- <-- Slow space leak here (why?)
        do
          (fields,counts) <- unzip <$> clusteredUnTVar clusteredTrodes
          occ <- readTVarIO occT
          let !estimate = clusteredReconstruction rTauSec lastFields counts occ
          atomically $ writeTVar (ds^.decodedPos) estimate

          let expTime = undefined -- TODO Placeholder
          let name = undefined
          let pack = Packet estimate expTime name
          streamData sock pack

          resetClusteredSpikeCounts clusteredTrodes
          tNow <- getCurrentTime
          maybe (return ()) (flip hPutStr (show tNow ++ ", ")) h
          maybe (return ()) (flip hPutStrLn (showPosterior estimate tNow)) h
          let timeRemaining = diffUTCTime binEndTime tNow

          threadDelay $ floor (timeRemaining * 1e6)
          go fields binEndTime
      fields0 = [] -- TODO: fix. (locks up if clusteredReconstrution doesn't
                   --             check for exactly this case)
    in
   go fields0 t0

timeToNextTick :: DiffTime -> TVar TimeSyncState -> IO DiffTime
timeToNextTick period stVar = do
  st@TimeSyncState{..} <- readTVarIO stVar
  ntNow <- flip sysTimeToNetworkTime st <$> getCurrentTime
  -- -(now - epoch) % period
  return $ (diffNetworkTime networkTimeEpoch ntNow) `mod'` period

------------------------------------------------------------------------------
-- P(x|n) = C(tau,N) * P(x) * Prod_i(f_i(x) ^ n_i) * exp (-tau * Sum_i( f_i(x) ))
--                                                               |sumFields|
clusteredReconstruction :: Double -> [Field] -> [Int] -> Field -> Field
clusteredReconstruction _        []            _           occ   =
  V.replicate (V.length occ) (1 / (fromIntegral $ V.length occ))
clusteredReconstruction rTauSecs clusterFields clusterCounts occ =
  let clusterFieldsGt0 = map gt0 clusterFields :: [Field]
      sumFields      = V.zipWith (/)
                       (L.foldl1' (V.zipWith (+)) clusterFieldsGt0)
                       occ
      bayesField f c = V.map (^c) (V.zipWith (/) f occ) :: Field
      prodPart       = L.foldl1' (V.zipWith (*))
                       (zipWith bayesField clusterFieldsGt0 clusterCounts)
      exponPart      = V.map (exp . (* negate rTauSecs)) sumFields
      likelihoodPart = V.zipWith (*) prodPart exponPart
      posteriorPart  = V.zipWith (*) occ likelihoodPart :: Field
      invPostSum     = 1 / V.sum  posteriorPart
  in
   V.map (* invPostSum) posteriorPart 


------------------------------------------------------------------------------
gt0 :: Field -> Field
gt0 = V.map (\x -> if x > 0 then x else 0.1)


------------------------------------------------------------------------------
normalize :: Field -> Field
normalize f = let fieldSum = V.foldl' (+) 0 f
                  coef = 1/fieldSum
              in  V.map (*coef) f
{-# INLINE normalize #-}

------------------------------------------------------------------------------
clusteredUnTVar :: Map.Map PlaceCellName PlaceCellTrode -> IO [(Field,Int)]
clusteredUnTVar pcMap = fmap concat $ atomically . mapM trodeFields . Map.elems $ pcMap
  where
    trodeFields :: PlaceCellTrode -> STM [(Field,Int)]
    trodeFields pct = mapM countsOneCell
                      (Map.elems . _dUnits $ pct)
    countsOneCell :: TVar DecodablePlaceCell -> STM (Field, Int)
    countsOneCell dpcT = do
      dpc <- readTVar dpcT
      return (dpc^.dpCell.countField, dpc^.dpCellTauN)


------------------------------------------------------------------------------
resetClusteredSpikeCounts :: Map.Map TrodeName PlaceCellTrode
                    -> IO ()
resetClusteredSpikeCounts clusteredTrodes =
  atomically $ mapM_ (\dpc -> resetOneTrode dpc) (Map.elems clusteredTrodes)
  where resetOneTrode t = mapM_ resetOneCell (Map.elems . _dUnits $ t)
        resetOneCell pc = modifyTVar pc $ dpCellTauN .~ 0



------------------------------------------------------------------------------
keyFilter :: (Ord k) => (k -> Bool) -> Map.Map k a -> Map.Map k a
keyFilter p m = Map.filterWithKey (\k _ -> p k) m

------------------------------------------------------------------------------
posteriorOut :: Field -> [Double]
posteriorOut f = V.toList f


------------------------------------------------------------------------------
showPosterior :: Field -> UTCTime -> String
showPosterior f (UTCTime _ sec) =
  let bound' (l,h) x = min h (max x l)
  in (take 10 $ show sec) ++ ", " ++
     L.intercalate ", " (map (show . bound' (0,100) ) $ posteriorOut f)


------------------------------------------------------------------------------
runClusterlessReconstruction :: ClusterlessOpts -> Double -> TVar DecoderState
                             -> Maybe Handle -> IO ()
runClusterlessReconstruction rOpts rTauSec dsT _ = do
  ds <- readTVarIO dsT
  t0 <- getCurrentTime
  go ds t0
  where go ds binStartTime = do
          let binEndTime = addUTCTime (realToFrac rTauSec) binStartTime
          H.timeAction (ds^.decodeProf) $ do
            !trodeEstimates <- forM
                              (Map.elems $ ds^.trodes._Clusterless) $
                              (stepTrode rOpts)
            let !fieldProduct = collectFields trodeEstimates
            atomically . writeTVar (ds^.decodedPos) .  normalize $ fieldProduct
          performGC
          tNow <- getCurrentTime
          let tRemaining = diffUTCTime tNow binEndTime
          threadDelay $ floor (tRemaining * 1e6)
          go ds binEndTime
  

------------------------------------------------------------------------------
-- TODO: Fix order. This add spikes then decodes.
--       Should decode, then add spikes
stepTrode :: ClusterlessOpts -> TVar ClusterlessTrode -> IO Field
stepTrode opts trode' = do
  
  (spikes,kde) <- atomically $ do -- TODO timeEvent encodeProf here
    trode <- readTVar trode'
    let spikesTimes = (trode^.dtTauN)
    let kde = (trode^.dtNotClust)
        f m k = KDMap.add m (kdClumpThreshold opts) (fst3 k) (snd3 k)
        spikesForField  = filter trd3 spikesTimes
    writeTVar trode' $
      ClusterlessTrode (L.foldl' f  kde spikesForField) []

    return $ (map fst3 spikesTimes,kde)

--  putStr $ show (length $ filter okAmp spikes) ++ "/" ++
--    show (length spikes) ++ " spikes. "

--  hFlush stdout

  return . collectFields $   -- TODO timeEvent decodeProf here
    map (\s -> sampleKDE opts s kde) (filter okAmp spikes)

  where fst3 (a,_,_) = a
        snd3 (_,b,_) = b
        trd3 (_,_,c) = c
        okAmp  p     = U.maximum (_pAmplitude p) >= amplitudeThreshold opts


------------------------------------------------------------------------------
collectFields :: [Field] -> Field
collectFields = normalize . V.map (exp)
                . L.foldl' (V.zipWith (+)) (zerosField defTrack)
                . map (V.map log)


------------------------------------------------------------------------------
sampleKDE :: ClusterlessOpts -> ClusterlessPoint -> NotClust -> Field
sampleKDE ClusterlessOpts{..} point points =
  let nearbyPoints   = map fst $ allInRange (sqrt cutoffDist2) point points :: [ClusterlessPoint]
      distExponent :: ClusterlessPoint -> Double
      distExponent p = (1 / ) $
                       exp((-1) * (pointDistSq p point :: Double)/(2*kernelVariance))
      expField :: ClusterlessPoint -> Field
      expField  p    = V.map (** distExponent p) (_pField p)
--      expField  p    = _pField p
--      scaledField :: Field -> Field
--      scaledField p  = V.map (/ (V.sum p)) p
--  in bound 0.1 1000 $
--     L.foldl' (V.zipWith (*)) emptyField $ map (normalize . bound 0.1 1000 . expField) nearbyPoints
  in normalize . collectFields . map expField $ nearbyPoints


------------------------------------------------------------------------------
closenessFromSample :: ClusterlessOpts -> ClusterlessPoint -> ClusterlessPoint
                       -> Double
closenessFromSample ClusterlessOpts{..} pointA pointB =
  exp((-1) * ((pointDistSq pointA pointB)/(2 *kernelVariance)))

------------------------------------------------------------------------------
data ClusterlessOpts = ClusterlessOpts {
    kernelVariance      :: !Double
  , cutoffDist2         :: !Double
  , amplitudeThreshold  :: !Voltage
  , spikeWidthThreshold :: !Int
  , kdClumpThreshold    :: !Double
  , accumulatorPort     :: !PortNumber
  , accumulatorAddr     :: !HostAddress
  } deriving (Eq, Show)

iNADDR_LOOPBACK :: HostAddress
iNADDR_LOOPBACK = [ip|127.0.0.1|]

defaultClusterlessOpts :: ClusterlessOpts
defaultClusterlessOpts =
  ClusterlessOpts { kernelVariance      = 200e-6
                  , cutoffDist2         = (60e-6)^(2::Int)
                  , amplitudeThreshold  = 40e-6
                  , spikeWidthThreshold = 13
                  , kdClumpThreshold    = 8e-6
                  , accumulatorPort     = 2139
                  , accumulatorAddr     = iNADDR_LOOPBACK
                  }


------------------------------------------------------------------------------
unZero :: Double -> Field -> Field
unZero baseline f = V.map (max baseline) f

unInf :: Double -> Field -> Field
unInf ceil f = V.map (min ceil) f

bound :: Double -> Double -> Field -> Field
bound l h = unInf h . unZero l


-- unused
liftTC :: (a -> b) -> TrodeCollection a -> TrodeCollection b
liftTC f tca = Map.map (Map.map f) tca



------------------sending stuff-----------------------

--remember to initialized myPort in ClusterlessOpts
--initialize ipAddy (String) remember inet_addr :: String -> IO Host Address
initSock :: IO (Socket)
initSock = withSocketsDo $ do
  sock <- socket AF_INET Datagram defaultProtocol --creates an IO socket with address family, socket type and prot number
  let saddr = SockAddrInet (fromIntegral 0) iNADDR_ANY --initializes a socket address with port number "0" (bind to any port) and takes a hostAddress that will take any port.
  bind sock saddr --binds the socket to the address.
  return sock


streamData :: Socket -> Packet -> IO ()
streamData sock p = withSocketsDo $ do
  BS.sendAll sock $ encode p --send packet over the scoket 




getFields :: IO (Field)
getFields = undefined

