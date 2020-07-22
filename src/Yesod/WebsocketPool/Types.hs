{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Yesod.WebsocketPool.Types where

import ClassyPrelude
import Yesod
import Yesod.WebSockets as WS
import ClassyPrelude.Conduit
import Data.Aeson (ToJSON)
import Data.Map as M
import qualified Data.List as L
import qualified Data.ByteString.Lazy.Internal as Lazy
--import GHC.Generics (Generic)
import Network.WebSockets  as NWS (ConnectionException(..))

data WebsocketConnection = WebsocketConnection 
                         { origin :: WebsocketOrigin
                         , websocketChannel :: WebsocketChannel
                         } 

data WebsocketOrigin = WebsocketOrigin 
                     { originName :: Text -- name or identifier of the user originating the connection
                     , originRoute :: Text -- route from which this connection originates
                     }
    deriving (Eq,ToJSON,Generic)

data WebsocketChannel = WebsocketChannel 
                      { keyOf :: Text
                      , rosterOf :: TVar [WebsocketOrigin]
                      , channelOf :: Channel
                      }

type Channel = TChan Lazy.ByteString

type MsgHandler = Text -> Lazy.ByteString

data ErrHandler = ErrHandler { errReply :: Maybe (ConnectionException -> Lazy.ByteString) -- send an alert on the channel that the error occured on
                             , errReaction :: Maybe (ConnectionException -> IO ()) -- react to the error
                             }

type ChanTable = Map Text WebsocketChannel

type ChannelPool = TVar ChanTable

data WebsocketPool = WebsocketPool 
    { monitorChannel :: Channel --An server-only internal channel for monitoring the Channel Pool
    , channelPool :: ChannelPool --The pool of websocket channels
    }

mkYesodSubData "WebsocketPool" [parseRoutes|
/ WebsocketWatcherR GET
|]

initWebsockets :: IO WebsocketPool
initWebsockets = atomically $ WebsocketPool <$> newBroadcastTChan <*> newTVar mempty

class YesodWebsocketPool app where
        liftWebsocketPool :: Route WebsocketPool -> Route app
        getWebsocketPool :: HandlerFor app WebsocketPool
        getWebsocketMonitor :: HandlerFor app Channel
        getWebsocketMonitor = monitorChannel <$> getWebsocketPool
        getChannelPool :: HandlerFor app ChannelPool
        getChannelPool = channelPool <$> getWebsocketPool
        getWebsocketWatcherWidget :: WidgetFor app ()
        getWebsocketWatcherWidget = [whamlet|
                                    <h1> Open Websockets
                                    <ul#wsList>
                                    |]


instance YesodWebsocketPool WebsocketPool where
        getWebsocketPool = liftHandler getYesod
        liftWebsocketPool = id

getMonitorChannel :: YesodWebsocketPool app => HandlerFor app Channel
getMonitorChannel = monitorChannel <$> getWebsocketPool

getAppChannels :: YesodWebsocketPool app => HandlerFor app ChanTable
getAppChannels = (channelPool <$> getWebsocketPool) >>= (atomically . readTVar) 

connectToChannel :: YesodWebsocketPool app => Text -> Text -> HandlerFor app WebsocketConnection
connectToChannel txt name = do
        wsChannels <- getChannelPool
        wsMonitor <- getWebsocketMonitor
        route <- getCurrentRoute >>= maybe (setMessage "couldn't retrieve route" >> notFound) pure
        render <- getUrlRender
        let wsurl = "ws" <> dropWhile (/= ':') (render route)
        atomically $ do 
           chanMap <- readTVar wsChannels
           case M.lookup txt chanMap of
                Just wsc@(WebsocketChannel _ roster _) -> do 
                        modifyTVar roster ((:) (WebsocketOrigin name wsurl)) 
                        writeTChan wsMonitor $ "JOINED"
                        return $ WebsocketConnection (WebsocketOrigin name wsurl) wsc
                Nothing -> do tchan <- newBroadcastTChan
                              roster <- newTVar [WebsocketOrigin name wsurl] 
                              let wsc = WebsocketChannel { keyOf = txt
                                                         , rosterOf = roster
                                                         , channelOf = tchan}
                              writeTVar wsChannels (M.insert txt wsc chanMap)
                              writeTChan wsMonitor $ "CREATED"
                              return $ WebsocketConnection (WebsocketOrigin name wsurl) wsc

plugInWebsocketChannel :: YesodWebsocketPool app =>
     WebsocketConnection -> MsgHandler -> ErrHandler -> WebSocketsT (HandlerFor app) ()
plugInWebsocketChannel wscon msghandler errhandler = do
    wsChannels <- lift getChannelPool
    wsMonitor <- lift getWebsocketMonitor
    let toServer = channelOf (websocketChannel wscon)
    fromServer <- atomically (dupTChan toServer)
    WS.race_
        (forever $ atomically (readTChan fromServer) >>= sendTextData)
        (sourceWS $$ mapM_C (\msg ->
            atomically $ writeTChan toServer $ msghandler msg))
        `catch` (liftIO . handleConnectionException errhandler wsChannels wsMonitor wscon)

handleConnectionException :: 
    ErrHandler -> ChannelPool -> Channel -> WebsocketConnection -> ConnectionException -> IO ()
handleConnectionException errhandler wsChannels wsMonitor wscon e = do
        case errReaction errhandler of
            Just s -> s e
            Nothing -> return ()
        atomically $ 
            do let wsc = websocketChannel wscon
               n <- L.length <$> readTVar (rosterOf wsc)
               if n >= (1 :: Int)
                   then do case errReply errhandler of
                                Just s ->  writeTChan (channelOf wsc) $ s e
                                Nothing -> return ()
                           writeTChan wsMonitor $ "DEPARTED"
                           modifyTVar (rosterOf wsc) (L.delete (origin wscon))
                   else do modifyTVar wsChannels (M.delete (keyOf wsc))
                           writeTChan wsMonitor $ "DELETED"

