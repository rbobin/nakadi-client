{-|
Module      : Network.Nakadi.Subscriptions.Events
Description : Implementation of Nakadi Subscription Events API
Copyright   : (c) Moritz Clasmeier 2017, 2018
License     : BSD3
Maintainer  : mtesseract@silverratio.net
Stability   : experimental
Portability : POSIX

This module implements a high level interface for the
@\/subscriptions\/SUBSCRIPTIONS\/events@ API.
-}

{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE RecordWildCards       #-}

module Network.Nakadi.Subscriptions.Events
  ( subscriptionProcessConduit
  , subscriptionProcess
  , subscriptionSource
  , subscriptionSourceEvents
  )
where

import           Network.Nakadi.Internal.Prelude

import           Control.Monad.IO.Unlift
import           Control.Concurrent.STM.TBMQueue
                                                ( TBMQueue
                                                , newTBMQueue
                                                , writeTBMQueue
                                                , closeTBMQueue
                                                , readTBMQueue
                                                )
import           UnliftIO.STM                   ( TBQueue
                                                , TVar
                                                , newTBQueue
                                                , writeTBQueue
                                                , readTBQueue
                                                , atomically
                                                , modifyTVar
                                                , newTVar
                                                , readTVar
                                                , swapTVar
                                                )

import           Conduit                 hiding ( throwM )
import qualified Control.Concurrent.Async.Timer
                                               as Timer
import           Control.Concurrent.STM         ( retry )
import           Control.Lens
import           Control.Monad.Logger
import           Data.Aeson
import           Control.Monad.Trans.Resource   ( allocate )
import qualified Data.Conduit.List             as Conduit
                                                ( mapM_ )
import           Data.HashMap.Strict            ( HashMap )
import qualified Data.HashMap.Strict           as HashMap
import qualified Data.Vector                   as Vector
import           Network.HTTP.Client            ( responseBody )
import           Network.HTTP.Simple
import           Network.HTTP.Types
import           Network.Nakadi.Internal.Config
import           Network.Nakadi.Internal.Conversions
import           Network.Nakadi.Internal.Http
import qualified Network.Nakadi.Internal.Lenses
                                               as L
import           Network.Nakadi.Subscriptions.Cursors

import           UnliftIO.Async

-- | Consumes the specified subscription using the commit strategy
-- contained in the configuration. Each consumed batch of subscription
-- events is provided to the provided batch processor action. If this
-- action throws an exception, subscription consumption will terminate.
subscriptionProcess
  :: (MonadNakadi b m, MonadUnliftIO m, MonadMask m, FromJSON a)
  => SubscriptionId                           -- ^ Subscription to consume
  -> (SubscriptionEventStreamBatch a -> m ()) -- ^ Batch processor action
  -> m ()
subscriptionProcess subscriptionId processor = subscriptionProcessConduit subscriptionId conduit
  where conduit = iterMC processor

-- | Conduit based interface for subscription consumption. Consumes
-- the specified subscription using the commit strategy contained in
-- the configuration. Each consumed event batch is then processed by
-- the provided conduit. If an exception is thrown inside the conduit,
-- subscription consumption will terminate.
subscriptionProcessConduit
  :: ( MonadNakadi b m
     , MonadUnliftIO m
     , MonadMask m
     , FromJSON a
     , batch ~ SubscriptionEventStreamBatch a
     )
  => SubscriptionId            -- ^ Subscription to consume
  -> ConduitM batch batch m () -- ^ Conduit processor.
  -> m ()
subscriptionProcessConduit subscriptionId processor = do
  config <- nakadiAsk
  let queryParams = buildConsumeQueryParameters config
  httpJsonBodyStream
      ok200
      [(status404, errorSubscriptionNotFound)]
      (includeFlowId config . setRequestPath path . setRequestQueryParameters queryParams)
    $ subscriptionProcessHandler subscriptionId processor
  where path = "/subscriptions/" <> subscriptionIdToByteString subscriptionId <> "/events"

-- | Derive a 'SubscriptionEventStream' from the provided
-- 'SubscriptionId' and Nakadi streaming response.
buildSubscriptionEventStream
  :: MonadThrow m => SubscriptionId -> Response a -> m SubscriptionEventStream
buildSubscriptionEventStream subscriptionId response =
  case listToMaybe (getResponseHeader "X-Nakadi-StreamId" response) of
    Just streamId -> pure SubscriptionEventStream
      { _streamId       = StreamId (decodeUtf8 streamId)
      , _subscriptionId = subscriptionId
      }
    Nothing -> throwM StreamIdMissing

-- | This function processes a subscription, taking care of applying
-- the configured committing strategy.
subscriptionProcessHandler
  :: ( MonadNakadi b m
     , MonadUnliftIO m
     , MonadMask m
     , FromJSON a
     , batch ~ (SubscriptionEventStreamBatch a)
     )
  => SubscriptionId                         -- ^ Subscription ID required for committing.
  -> ConduitM batch batch m ()              -- ^ User provided Conduit for stream.
  -> Response (ConduitM () ByteString m ()) -- ^ Streaming response from Nakadi
  -> m ()
subscriptionProcessHandler subscriptionId processor response = do
  config      <- nakadiAsk
  eventStream <- buildSubscriptionEventStream subscriptionId response
  let producer = responseBody response .| linesUnboundedAsciiC .| conduitDecode config .| processor
  case config ^. L.commitStrategy of
    CommitSync ->
      -- Synchronous case: Simply use a Conduit sink that commits
      -- every cursor.
      runConduit $ producer .| subscriptionSink eventStream
    CommitAsync bufferingStrategy -> do
      -- Asynchronous case: Create a new queue and spawn a cursor
      -- committer thread depending on the configured commit buffering
      -- method. Then execute the provided Conduit processor with a
      -- sink that sends cursor information to the queue. The cursor
      -- committer thread reads from this queue and processes the
      -- cursors.
      queue <- atomically $ newTBQueue 1024
      withAsync (subscriptionCommitter bufferingStrategy eventStream queue) $ \asyncHandle -> do
        link asyncHandle
        runConduit $ producer .| Conduit.mapM_ (sendToQueue queue)
 where
  sendToQueue queue batch = atomically $ do
    let cursor  = batch ^. L.cursor
        events  = fromMaybe Vector.empty (batch ^. L.events)
        nEvents = length events
    writeTBQueue queue (nEvents, cursor)

-- | Sink which can be used as sink for Conduits processing
-- subscriptions events. This sink takes care of committing events. It
-- can consume any values which contain Subscription Cursors.
subscriptionSink
  :: (MonadIO m, MonadNakadi b m)
  => SubscriptionEventStream
  -> ConduitM (SubscriptionEventStreamBatch a) void m ()
subscriptionSink eventStream = do
  config <- lift nakadiAsk
  awaitForever $ \batch -> lift $ do
    let cursor = batch ^. L.cursor
    catchAny (commitOneCursor eventStream cursor) $ \exn ->
      nakadiLiftBase $ case config ^. L.logFunc of
        Just logFunc ->
          logFunc "nakadi-client" LevelWarn
            $  toLogStr
            $  "Failed to synchronously commit cursor: "
            <> tshow exn
        Nothing -> pure ()

type CursorsMap = HashMap (EventTypeName, PartitionName) (Int, SubscriptionCursor)

emptyCursorsMap :: CursorsMap
emptyCursorsMap = HashMap.empty

cursorKey :: SubscriptionCursor -> (EventTypeName, PartitionName)
cursorKey cursor = (cursor ^. L.eventType, cursor ^. L.partition)

-- | Implementation for the 'CommitNoBuffer' strategy: We simply read
-- every cursor and commit it in order.
unbufferedCommitLoop
  :: (MonadNakadi b m, MonadIO m)
  => SubscriptionEventStream
  -> TBQueue (Int, SubscriptionCursor)
  -> m ()
unbufferedCommitLoop eventStream queue = do
  config <- nakadiAsk
  forever $ do
    (_nEvents, cursor) <- atomically . readTBQueue $ queue
    catchAny (subscriptionCursorCommit eventStream [cursor]) $ \exn ->
      nakadiLiftBase $ case config ^. L.logFunc of
        Just logFunc ->
          logFunc "nakadi-client" LevelWarn
            $  toLogStr
            $  "Failed to commit cursor "
            <> tshow cursor
            <> ": "
            <> tshow exn
        Nothing -> pure ()

cursorBufferSize :: Config m -> Int
cursorBufferSize conf = case _maxUncommittedEvents conf of
  Nothing -> 1
  Just n  -> n & fromIntegral & (* safetyFactor) & round
  where safetyFactor = 0.5

-- | Main function for the cursor committer thread. Logic depends on
-- the provided buffering strategy.
subscriptionCommitter
  :: (MonadNakadi b m, MonadUnliftIO m, MonadMask m)
  => CommitBufferingStrategy
  -> SubscriptionEventStream
  -> TBQueue (Int, SubscriptionCursor)
  -> m ()

-- | Implementation for the 'CommitNoBuffer' strategy: We simply read
-- every cursor and commit it in order.
subscriptionCommitter CommitNoBuffer eventStream queue = unbufferedCommitLoop eventStream queue

-- | Implementation of the 'CommitTimeBuffer' strategy: We use an
-- async timer for committing cursors at specified intervals.
subscriptionCommitter (CommitTimeBuffer millis) eventStream queue = do
  let timerConf = Timer.defaultConf & Timer.setInitDelay (fromIntegral millis) & Timer.setInterval
        (fromIntegral millis)
  cursorsMap <- liftIO . atomically $ newTVar emptyCursorsMap
  withAsync (cursorConsumer cursorsMap) $ \asyncCursorConsumer -> do
    link asyncCursorConsumer
    Timer.withAsyncTimer timerConf $ \timer -> forever $ do
      Timer.wait timer
      commitAllCursors eventStream cursorsMap
 where -- | The cursorsConsumer drains the cursors queue and adds each
        -- cursor to the provided cursorsMap.
  cursorConsumer cursorsMap = forever . liftIO . atomically $ do
    (_, cursor) <- readTBQueue queue
    modifyTVar cursorsMap (HashMap.insert (cursorKey cursor) (0, cursor))

-- | Implementation of the 'CommitSmartBuffer' strategy: We use an
-- async timer for committing cursors at specified intervals, but if
-- the number of uncommitted events reaches some threshold before the
-- next scheduled commit, a commit is being done right away and the
-- timer is resetted.
subscriptionCommitter CommitSmartBuffer eventStream queue = do
  config <- nakadiAsk
  let
    millisDefault = 1000
    nMaxEvents    = cursorBufferSize config
    timerConf =
      Timer.defaultConf & Timer.setInitDelay (fromIntegral millisDefault) & Timer.setInterval
        (fromIntegral millisDefault)
  if nMaxEvents > 1
    then do
      cursorsMap <- liftIO . atomically $ newTVar emptyCursorsMap
      withAsync (cursorConsumer cursorsMap) $ \asyncCursorConsumer -> do
        link asyncCursorConsumer
        Timer.withAsyncTimer timerConf $ cursorCommitter cursorsMap nMaxEvents
    else unbufferedCommitLoop eventStream queue
 where -- | The cursorsConsumer drains the cursors queue and adds
        -- each cursor to the provided cursorsMap.
  cursorConsumer cursorsMap = forever . liftIO . atomically $ do
    (nEvents, cursor) <- readTBQueue queue
    modifyTVar cursorsMap $ HashMap.insertWith updateCursor (cursorKey cursor) (nEvents, cursor)

  -- | Adds the old number of events to the new entry in the
  -- cursors map.
  updateCursor cursorNew (nEventsOld, _) = cursorNew & _1 %~ (+ nEventsOld)

  -- | Committer loop.
  cursorCommitter cursorsMap nMaxEvents timer =
    forever
      $   race (Timer.wait timer) (maxEventsReached cursorsMap nMaxEvents)
      >>= \case
            Left _ ->
              -- Timer has elapsed, simply commit all currently
              -- buffered cursors.
              commitAllCursors eventStream cursorsMap
            Right _ -> do
              -- Events processed since last cursor commit have
              -- crosses configured threshold for at least one
              -- partition. Commit cursors on all such partitions.
              Timer.reset timer
              commitAllCursors eventStream cursorsMap

  -- | Returns list of cursors that should be committed
  -- considering the number of events processed on the
  -- respective partition since the last commit. Blocks until at
  -- least one such cursor is found.
  maxEventsReached cursorsMap nMaxEvents = liftIO . atomically $ do
    cursorsList <- HashMap.toList <$> readTVar cursorsMap
    let cursorsCommit = filter (shouldBeCommitted nMaxEvents) cursorsList
    if null cursorsCommit then retry else pure ()

  -- | Returns True if the provided cursor should be committed.
  shouldBeCommitted nMaxEvents cursor = cursor ^. _2 . _1 >= nMaxEvents

-- | This function commits all cursors in the provided cursorsMap.
commitAllCursors
  :: (MonadNakadi b m, MonadIO m) => SubscriptionEventStream -> TVar CursorsMap -> m ()
commitAllCursors eventStream cursorsMap = do
  cursors <- liftIO . atomically $ swapTVar cursorsMap emptyCursorsMap
  forM_ cursors $ \(_nEvents, cursor) -> commitOneCursor eventStream cursor

-- | This function takes care of committing a single cursor. Exceptions will be
-- catched and logged, but the failure will NOT be propagated. This means that
-- Nakadi itself is in control of disconnecting us.
commitOneCursor
  :: (MonadIO m, MonadNakadi b m) => SubscriptionEventStream -> SubscriptionCursor -> m ()
commitOneCursor eventStream cursor = do
  config <- nakadiAsk
  catchAny (subscriptionCursorCommit eventStream [cursor])
    $ \exn -> nakadiLiftBase $ case config ^. L.logFunc of
        Just logFunc ->
          logFunc "nakadi-client" LevelWarn
            $  toLogStr
            $  "Failed to commit cursor "
            <> tshow cursor
            <> ": "
            <> tshow exn
        Nothing -> pure ()

-- | Experimental API.
--
-- Creates a Conduit source from a subscription ID. The source will produce subscription
-- event stream batches. Note the batches will be asynchronously committed irregardless of
-- any event processing logic. Use this function only if the guarantees provided by Nakadi
-- for event processing and cursor committing are not required or not desired.
subscriptionSource
  :: forall a b m
   . (MonadNakadi b m, MonadUnliftIO m, MonadMask m, MonadResource m, FromJSON a)
  => SubscriptionId                                    -- ^ Subscription to consume.
  -> ConduitM () (SubscriptionEventStreamBatch a) m () -- ^ Conduit source.
subscriptionSource subscriptionId = do
  UnliftIO {..}              <- lift askUnliftIO
  streamLimit                <- lift nakadiAsk <&> (fmap fromIntegral . view L.streamLimit)
  queue                      <- atomically $ newTBMQueue queueSize
  (_releaseKey, asyncHandle) <- allocate
    (unliftIO (async (subscriptionConsumer streamLimit queue)))
    cancel
  link asyncHandle
  drain queue
 where
  queueSize = 2048
  drain queue = atomically (readTBMQueue queue) >>= \case
    Just a  -> yield a >> drain queue
    Nothing -> pure ()

  subscriptionConsumer :: Maybe Int -> TBMQueue (SubscriptionEventStreamBatch a) -> m ()
  subscriptionConsumer maybeStreamLimit queue = go `finally` atomically (closeTBMQueue queue)
   where
    go = do
      subscriptionProcess subscriptionId (void . atomically . writeTBMQueue queue)
      -- We only reconnect automatically when no stream limit is set.
      -- This effectively means that we don't try to reach @streamLimit@ events exactly.
      -- We simply regard @streamLimit@ as an upper bound and in case Nakadi disconnects us
      -- earlier or the connection breaks, we produce less than @streamLimit@ events.
      when (isNothing maybeStreamLimit) go

-- | Experimental API.
--
-- Similar to `subscriptionSource`, but the created Conduit source provides events instead
-- of event batches.
subscriptionSourceEvents
  :: (MonadNakadi b m, MonadUnliftIO m, MonadMask m, MonadResource m, FromJSON a)
  => SubscriptionId     -- ^ Subscription to consume
  -> ConduitM () a m () -- ^ Conduit processor.
subscriptionSourceEvents subscriptionId =
  subscriptionSource subscriptionId .| concatMapC (\batch -> fromMaybe mempty (batch & _events))
