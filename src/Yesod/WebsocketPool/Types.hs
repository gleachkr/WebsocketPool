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
import Data.List as L
--import Data.Text
import qualified Data.ByteString.Lazy.Internal as Lazy
--import Data.Conduit
import GHC.Generics (Generic)
--import Control.Monad.Reader
import Network.WebSockets  as NWS (ConnectionException(..))

data WebsocketConnection = WebsocketConnection 
                         { origin :: WebsocketOrigin
                         , websocketChannel :: WebsocketChannel
                         } 

data WebsocketOrigin = WebsocketOrigin { originName :: Text }
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

type WebsocketsSubHandler master = HandlerT WebsocketPool (HandlerT master IO)

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
        getWebsocketPool :: Monad m => HandlerT app m WebsocketPool
        getWebsocketMonitor :: Monad m => HandlerT app m Channel
        getWebsocketMonitor = monitorChannel <$> getWebsocketPool
        getChannelPool :: Monad m => HandlerT app m ChannelPool
        getChannelPool = channelPool <$> getWebsocketPool
        getWebsocketWatcherWidget ::  WidgetT app IO ()
        getWebsocketWatcherWidget = [whamlet|
                                    <h1> Open Websockets
                                    <ul#wsList>
                                    |]


instance YesodWebsocketPool WebsocketPool where
        getWebsocketPool = ask

getMonitorChannel :: (YesodWebsocketPool app, Monad m) => HandlerT app m Channel
getMonitorChannel = monitorChannel <$> getWebsocketPool

getAppChannels :: (YesodWebsocketPool app, MonadIO m) => HandlerT app m ChanTable
getAppChannels = (channelPool <$> getWebsocketPool) >>= (atomically . readTVar) 

connectToChannel ::(YesodWebsocketPool app, MonadIO m) =>
    Text -> Text ->  HandlerT app m WebsocketConnection
connectToChannel txt name = do
        wsChannels <- getChannelPool
        wsMonitor <- getWebsocketMonitor
        atomically $ do 
           chanMap <- readTVar wsChannels
           case M.lookup txt chanMap of
                Just wsc@(WebsocketChannel _ roster _) -> do 
                        modifyTVar roster ((:) (WebsocketOrigin name)) 
                        writeTChan wsMonitor $ "JOINED"
                        return $ WebsocketConnection (WebsocketOrigin name) wsc
                Nothing -> do tchan <- newBroadcastTChan
                              roster <- newTVar [WebsocketOrigin name] 
                              let wsc = WebsocketChannel { keyOf = txt
                                                         , rosterOf = roster
                                                         , channelOf = tchan}
                              writeTVar wsChannels (M.insert txt wsc chanMap)
                              writeTChan wsMonitor $ "CREATED"
                              return $ WebsocketConnection (WebsocketOrigin name) wsc

plugInWebsocketChannel :: (YesodWebsocketPool app, MonadBaseControl IO m, MonadCatch m, MonadIO m) =>
     WebsocketConnection -> MsgHandler -> ErrHandler -> WebSocketsT (HandlerT app m) ()
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

