{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}

module Network.Nakadi.EventTypes.CursorsLag.Test where

import           ClassyPrelude

import qualified Data.Map                    as Map
import           Network.Nakadi
import           Network.Nakadi.Tests.Common
import           Test.Tasty
import           Test.Tasty.HUnit

testEventTypesCursorsLag :: Config -> TestTree
testEventTypesCursorsLag conf = testGroup "CursorsLag"
  [ testCase "CursorsLagZero" (testCursorsLagZero conf)
  -- , testCase "CursorsLag10" (testCursorsLagN conf 10)
  ]

testCursorsLagZero :: Config -> Assertion
testCursorsLagZero conf = do
  recreateEvent conf myEventTypeName myEventType
  partitions <- eventTypePartitions conf myEventTypeName
  let cursorsMap = Map.fromList $
        map (\Partition { .. } -> (_partition, _newestAvailableOffset)) partitions
  lagMap <- eventTypeCursorsLag conf myEventTypeName cursorsMap
  Map.size cursorsMap @=? Map.size lagMap
  forM_ (Map.toList lagMap) $ \(_, lag) ->
    lag @=? 0
