{-|
Module      : Network.Nakadi.Subscriptions.Stats
Description : Implementation of Nakadi Subscription API
Copyright   : (c) Moritz Schulte 2017
License     : BSD3
Maintainer  : mtesseract@silverratio.net
Stability   : experimental
Portability : POSIX

This module implements the @\/subscriptions@ API.
-}

{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections         #-}

module Network.Nakadi.Subscriptions
  ( module Network.Nakadi.Subscriptions.Cursors
  , module Network.Nakadi.Subscriptions.Events
  , module Network.Nakadi.Subscriptions.Stats
  , module Network.Nakadi.Subscriptions.Subscription
  , subscriptionCreate'
  , subscriptionCreateR'
  , subscriptionCreate
  , subscriptionCreateR
  , subscriptionsList'
  , subscriptionsListR'
  , subscriptionsSource
  , subscriptionsSourceR
  , subscriptionsList
  , subscriptionsListR
  ) where

import           Network.Nakadi.Internal.Prelude

import           Conduit
import qualified Control.Exception.Safe                    as Safe
import           Control.Lens
import qualified Data.Text                                 as Text
import           Network.Nakadi.Internal.Http
import qualified Network.Nakadi.Internal.Lenses            as L
import           Network.Nakadi.Internal.Util
import           Network.Nakadi.Subscriptions.Cursors
import           Network.Nakadi.Subscriptions.Events
import           Network.Nakadi.Subscriptions.Stats
import           Network.Nakadi.Subscriptions.Subscription

path :: ByteString
path = "/subscriptions"

-- | @POST@ to @\/subscriptions@. Creates a new subscription. Low
-- level interface.
subscriptionCreate' :: MonadNakadi b m
                    => Config' b
                    -> Subscription
                    -> m Subscription
subscriptionCreate' config subscription =
  runNakadiT config $ subscriptionCreateR' subscription

-- | @POST@ to @\/subscriptions@. Creates a new subscription. Low
-- level interface. Retrieves configuration from the environment.
subscriptionCreateR' ::
  MonadNakadiEnv b m
  => Subscription
  -> m Subscription
subscriptionCreateR' subscription =
  httpJsonBody status201 [(ok200, errorSubscriptionExistsAlready)]
  (setRequestMethod "POST"
   . setRequestPath path
   . setRequestBodyJSON subscription)

-- | @POST@ to @\/subscriptions@. Creates a new subscription. Does not
-- fail if the requested subscription does already exist.
subscriptionCreate :: MonadNakadi b m
                   => Config' b
                   -> Subscription
                   -> m Subscription
subscriptionCreate config subscription =
  runNakadiT config $ subscriptionCreateR subscription

-- | @POST@ to @\/subscriptions@. Creates a new subscription. Does not
-- fail if the requested subscription does already exist. Retrieves
-- configuration from the environment.
subscriptionCreateR ::
  MonadNakadiEnv b m
  => Subscription
  -> m Subscription
subscriptionCreateR subscription = do
  Safe.catchJust exceptionPredicate (subscriptionCreateR' subscription) return

  where exceptionPredicate (SubscriptionExistsAlready s) = Just s
        exceptionPredicate _                             = Nothing

-- | @GET@ to @\/subscriptions@. Internal low-level interface.
subscriptionsGet ::
  MonadNakadi b m
  => Config' b
  -> [(ByteString, ByteString)]
  -> m SubscriptionsListResponse
subscriptionsGet config queryParameters =
  runNakadiT config $ subscriptionsGetR queryParameters

-- | @GET@ to @\/subscriptions@. Internal low-level interface.
subscriptionsGetR ::
  MonadNakadiEnv b m
  => [(ByteString, ByteString)]
  -> m SubscriptionsListResponse
subscriptionsGetR queryParameters =
  httpJsonBody ok200 []
  (setRequestMethod "GET"
   . setRequestPath path
   . setRequestQueryParameters queryParameters)

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. Low-level interface using pagination.
subscriptionsList' :: MonadNakadi b m
                   => Config' b
                   -> Maybe ApplicationName
                   -> Maybe [EventTypeName]
                   -> Maybe Limit
                   -> Maybe Offset
                   -> m SubscriptionsListResponse
subscriptionsList' config maybeOwningApp maybeEventTypeNames maybeLimit maybeOffset =
  runNakadiT config $
  subscriptionsListR' maybeOwningApp maybeEventTypeNames maybeLimit maybeOffset

buildQueryParameters :: Maybe ApplicationName
                     -> Maybe [EventTypeName]
                     -> Maybe Limit
                     -> Maybe Offset
                     -> [(ByteString, ByteString)]
buildQueryParameters maybeOwningApp maybeEventTypeNames maybeLimit maybeOffset =
  catMaybes $
  [ ("owning_application",) . encodeUtf8 . unApplicationName <$> maybeOwningApp
  , ("limit",) . encodeUtf8 . tshow <$> maybeLimit
  , ("offset",) . encodeUtf8 . tshow <$> maybeOffset ]
  ++ case maybeEventTypeNames of
       Just eventTypeNames -> map (Just . ("event_type",) . encodeUtf8 . unEventTypeName) eventTypeNames
       Nothing -> []

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. Uses configuration contained in the
-- environment.
subscriptionsListR' ::
  (MonadNakadiEnv b m)
  => Maybe ApplicationName
  -> Maybe [EventTypeName]
  -> Maybe Limit
  -> Maybe Offset
  -> m SubscriptionsListResponse
subscriptionsListR' maybeOwningApp maybeEventTypeNames maybeLimit maybeOffset = do
  subscriptionsGetR queryParameters
  where queryParameters =
          buildQueryParameters maybeOwningApp maybeEventTypeNames maybeLimit maybeOffset

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. High-level Conduit interface.
subscriptionsSource :: (MonadNakadi b m, MonadIO n, MonadCatch n, MonadSub b n)
                    => Config' b
                    -> Maybe ApplicationName
                    -> Maybe [EventTypeName]
                    -> m (ConduitM () [Subscription] n ())
subscriptionsSource config maybeOwningApp maybeEventTypeNames =
  runNakadiT config $ subscriptionsSourceR maybeOwningApp maybeEventTypeNames

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. High-level Conduit interface,
-- obtaining the configuration from the environment.
subscriptionsSourceR :: (MonadNakadiEnv b m, MonadIO n, MonadSub b n, MonadCatch n)
                     => Maybe ApplicationName
                     -> Maybe [EventTypeName]
                     -> m (ConduitM () [Subscription] n ())
subscriptionsSourceR maybeOwningApp maybeEventTypeNames = do
  config <- nakadiAsk
  pure $ nextPage config initialQueryParameters

  where nextPage config queryParameters = do
          resp <- lift $ subscriptionsGet config queryParameters
          yield (resp^.L.items)
          let maybeNextPath = Text.unpack . (view L.href) <$> (resp^.L.links.L.next)
          case maybeNextPath >>= extractQueryParametersFromPath  of
            Just nextQueryParameters -> do
              nextPage config nextQueryParameters
            Nothing ->
              return ()

        initialQueryParameters =
          buildQueryParameters maybeOwningApp maybeEventTypeNames Nothing Nothing

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. High-level list interface.
subscriptionsList ::
  MonadNakadi b m
  => Config' b
  -> Maybe ApplicationName
  -> Maybe [EventTypeName]
  -> m [Subscription]
subscriptionsList config maybeOwningApp maybeEventTypeNames =
  runNakadiT config $ subscriptionsListR maybeOwningApp maybeEventTypeNames

-- | @GET@ to @\/subscriptions@. Retrieves all subscriptions matching
-- the provided filter criteria. High-level Conduit interface,
-- obtaining the configuration from the environment.
subscriptionsListR ::
  MonadNakadiEnv b m
  => Maybe ApplicationName
  -> Maybe [EventTypeName]
  -> m [Subscription]
subscriptionsListR maybeOwningApp maybeEventTypeNames = do
  source <- subscriptionsSourceR maybeOwningApp maybeEventTypeNames
  runConduit $ source .| concatC .| sinkList
