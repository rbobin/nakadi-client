{-|
Module      : Network.Nakadi.Config
Description : Nakadi Client Configuration
Copyright   : (c) Moritz Schulte 2017
License     : BSD3
Maintainer  : mtesseract@silverratio.net
Stability   : experimental
Portability : POSIX

This module implements support for creating and manipulating Nakadi
client configurations.
-}

module Network.Nakadi.Config where

import           Network.Nakadi.Internal.Prelude

import           Control.Lens
import           Network.HTTP.Client
import           Network.HTTP.Client.TLS
import qualified Network.Nakadi.Internal.Lenses  as L

import           Network.Nakadi.Internal.Types

-- | Producs a new configuration, with mandatory HTTP manager, default
-- consumption parameters and HTTP request template.
newConfig' ::
  (MonadIO m, MonadThrow m)
  => Manager           -- ^ Manager Settings
  -> ConsumeParameters -- ^ Consumption Parameters
  -> Request           -- ^ Request Template
  -> m Config          -- ^ Resulting Configuration
newConfig' manager consumeParameters request =
  return Config { _consumeParameters              = consumeParameters
                , _manager                        = manager
                , _requestTemplate                = request
                , _requestModifier                = return
                , _deserializationFailureCallback = Nothing
                , _streamConnectCallback          = Nothing
                , _logFunc                        = Nothing }

-- | Produce a new configuration, with optional HTTP manager settings
-- and mandatory HTTP request template.
newConfig ::
  (MonadIO m, MonadThrow m)
  => Maybe ManagerSettings -- ^ Optional 'ManagerSettings'
  -> Request               -- ^ Request template for Nakadi requests
  -> m Config              -- ^ Resulting Configuration
newConfig mngrSettings request = do
  manager <- newTlsManagerWith (fromMaybe tlsManagerSettings mngrSettings)
  newConfig' manager defaultConsumeParameters request

-- | Install a request modifier in the provided configuration. This
-- can be used for e.g. including access tokens in HTTP requests to
-- Nakadi.
setRequestModifier :: (Request -> IO Request) -> Config -> Config
setRequestModifier = (L.requestModifier .~)

-- | Install a callback in the provided configuration to use in case
-- of deserialization failures when consuming events.
setDeserializationFailureCallback :: (ByteString -> IO ()) -> Config -> Config
setDeserializationFailureCallback cb = L.deserializationFailureCallback .~ Just cb

-- | Install a callback in the provided configuration which is used
-- after having successfully established a streaming Nakadi
-- connection.
setStreamConnectCallback :: StreamConnectCallback  -> Config -> Config
setStreamConnectCallback cb = L.streamConnectCallback .~ Just cb

-- | Install a logger callback in the provided configuration.
setLogFunc :: LogFunc -> Config -> Config
setLogFunc logFunc = L.logFunc .~ Just logFunc

-- | Default parameters for event consumption.
defaultConsumeParameters :: ConsumeParameters
defaultConsumeParameters = ConsumeParameters
  { _maxUncommittedEvents = Nothing
  , _batchLimit           = Nothing
  , _streamLimit          = Nothing
  , _batchFlushTimeout    = Nothing
  , _streamTimeout        = Nothing
  , _streamKeepAliveLimit = Nothing
  , _flowId               = Nothing
  }

-- | Set maximum number of uncommitted events in the provided value of
-- consumption parameters.
setMaxUncommittedEvents :: Int32 -> ConsumeParameters -> ConsumeParameters
setMaxUncommittedEvents n params = params & L.maxUncommittedEvents .~ Just n

-- | Set batch limit in the provided value of consumption parameters.
setBatchLimit :: Int32 -> ConsumeParameters -> ConsumeParameters
setBatchLimit n params = params & L.batchLimit .~ Just n

-- | Set stream limit in the provided value of consumption parameters.
setStreamLimit :: Int32 -> ConsumeParameters -> ConsumeParameters
setStreamLimit n params = params & L.streamLimit .~ Just n

-- | Set batch-flush-timeout limit in the provided value of
-- consumption parameters.
setBatchFlushTimeout :: Int32 -> ConsumeParameters -> ConsumeParameters
setBatchFlushTimeout n params = params & L.batchFlushTimeout .~ Just n

-- | Set stream timeout in the provided value of consumption parameters.
setStreamTimeout :: Int32 -> ConsumeParameters -> ConsumeParameters
setStreamTimeout n params = params & L.streamTimeout .~ Just n

-- | Set stream-keep-alive-limit in the provided value of consumption
-- parameters.
setStreamKeepAliveLimit :: Int32 -> ConsumeParameters -> ConsumeParameters
setStreamKeepAliveLimit n params = params & L.streamKeepAliveLimit .~ Just n

-- | Set flow ID in the provided value of value of consumption parameters.
setFlowId :: Text -> ConsumeParameters -> ConsumeParameters
setFlowId flowId = L.flowId .~ Just flowId