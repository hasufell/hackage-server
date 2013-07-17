{-# LANGUAGE RankNTypes, NamedFieldPuns, RecordWildCards #-}
-- | Download counts
--
-- We maintain
--
-- 1. In-memory (ACID): today's download counts per package version
--
-- 2. In-memory (cache): total download count over the last 30 days per package
--    (across all versions). This is computed once per day from the on-disk
--    statistics (3).
--
-- 3. On-disk: total download per package per version per day. These are stored
--    in safe-copy format, one file per package; this allows to quickly load
--    the statistics for a given package to compute custom reports.
--
-- 4. On-disk: total download per package per version per day, stored as a single
--    CSV file that we append (1) to once per day. Strictly speaking this is
--    redundant, as this information is also stored in (3).
--
-- TODO: Check all stateDir and related paths
module Distribution.Server.Features.DownloadCount (
    DownloadFeature(..)
  , DownloadResource(..)
  , initDownloadFeature
  , RecentDownloads
  ) where

import Distribution.Server.Framework

import Distribution.Server.Features.DownloadCount.State
import Distribution.Server.Features.DownloadCount.Backup

import Distribution.Server.Features.Core

import Distribution.Package

import Data.Time.Calendar (Day, addDays)
import Data.Time.Clock (getCurrentTime, utctDay)
import Control.Concurrent.Chan
import Control.Concurrent (forkIO)
import Data.Map (Map)

data DownloadFeature = DownloadFeature {
    downloadFeatureInterface :: HackageFeature
  , downloadResource         :: DownloadResource
  , recentPackageDownloads   :: MonadIO m => m RecentDownloads
  }

instance IsHackageFeature DownloadFeature where
    getFeatureInterface = downloadFeatureInterface

data DownloadResource = DownloadResource {
    topDownloads :: Resource
  }

initDownloadFeature :: ServerEnv -> CoreFeature -> IO DownloadFeature
initDownloadFeature serverEnv@ServerEnv{serverStateDir, serverVerbosity = verbosity} core = do
    loginfo verbosity "Initialising download feature, start"

    recentRange    <- getRecentDayRange 30
    inMemState     <- inMemStateComponent  serverStateDir
    let onDiskState = onDiskStateComponent serverStateDir
    totalsCache    <- newMemStateWHNF =<< initRecentDownloads recentRange `liftM` getState onDiskState
    downChan       <- newChan

    let feature   = downloadFeature core serverEnv inMemState onDiskState totalsCache downChan

    registerHook (packageDownloadHook core) (writeChan downChan)
    loginfo verbosity "Initialising download feature, end"
    return feature

inMemStateComponent :: FilePath -> IO (StateComponent AcidState InMemStats)
inMemStateComponent stateDir = do
  initSt <- initInMemStats <$> getToday
  st <- openLocalStateFrom inMemPath initSt
  return StateComponent {
      stateDesc    = "Today's download counts"
    , stateHandle  = st
    , getState     = query st GetInMemStats
    , putState     = update st . ReplaceInMemStats
    , backupState  = inMemBackup
    , restoreState = inMemRestore
    , resetState   = inMemStateComponent
    }
  where
    inMemPath = stateDir </> "db" </> "InMemStats"

onDiskStateComponent :: FilePath -> StateComponent OnDiskState OnDiskStats
onDiskStateComponent stateDir = StateComponent {
      stateDesc    = "All time download counts"
    , stateHandle  = OnDiskState
    , getState     = readOnDiskStats  onDiskPath
    , putState     = writeOnDiskStats onDiskPath
    , backupState  = onDiskBackup
    , restoreState = onDiskRestore
    , resetState   = return . onDiskStateComponent
    }
  where
    onDiskPath = stateDir </> "db" </> "OnDiskStats"

downloadFeature :: CoreFeature
                -> ServerEnv
                -> StateComponent AcidState   InMemStats
                -> StateComponent OnDiskState OnDiskStats
                -> MemState RecentDownloads
                -> Chan PackageId
                -> DownloadFeature

downloadFeature CoreFeature{}
                ServerEnv{serverStateDir}
                inMemState
                onDiskState
                recentDownloadsCache
                downloadStream
  = DownloadFeature{..}
  where
    downloadFeatureInterface = (emptyHackageFeature "download") {
        featureResources = map ($ downloadResource) [topDownloads]
      , featurePostInit  = void $ forkIO registerDownloads
      , featureState     = [ abstractAcidStateComponent   inMemState
                           , abstractOnDiskStateComponent onDiskState
                           ]
      , featureCaches    = [
            CacheComponent {
              cacheDesc       = "recent package downloads cache",
              getCacheMemSize = memSize <$> readMemState recentDownloadsCache
            }
          ]
      }

    recentPackageDownloads :: MonadIO m => m RecentDownloads
    recentPackageDownloads = readMemState recentDownloadsCache

    registerDownloads = forever $ do
        pkg    <- readChan downloadStream
        today  <- getToday
        today' <- query (stateHandle inMemState) RecordedToday

        when (today /= today') $ do
          inMemStats  <- getState inMemState
          onDiskStats <- getState onDiskState
          putState inMemState  $ initInMemStats today
          putState onDiskState $ updateHistory inMemStats onDiskStats
          appendToLog (serverStateDir </> "DownloadCounts") inMemStats


        updateState inMemState $ RegisterDownload pkg

    downloadResource = DownloadResource {
        topDownloads = resourceAt "/packages/top.:format"
      }

{------------------------------------------------------------------------------
  Auxiliary
------------------------------------------------------------------------------}

getToday :: IO Day
getToday = utctDay <$> getCurrentTime

getRecentDayRange :: Integer -> IO DayRange
getRecentDayRange numDays = do
  lastDay <- getToday
  let firstDay  = addDays (negate numDays) lastDay
      secondDay = addDays 1 firstDay
  return [firstDay, secondDay .. lastDay]
