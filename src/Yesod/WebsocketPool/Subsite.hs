{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
module Yesod.WebsocketPool.Subsite (getWebsocketWatcherR) where

import ClassyPrelude
import Yesod
import Yesod.WebSockets as WS
import Yesod.WebsocketPool.Types
import Data.Aeson (encode)
import Text.Julius
import qualified Data.ByteString.Lazy.Internal as Lazy
--import qualified Text.Blaze.Html5 as B

getWebsocketWatcherR :: (Yesod master, YesodWebsocketPool master) 
    => SubHandlerFor WebsocketPool master Html
getWebsocketWatcherR = do render <- getUrlRender
                          let wsurl = "ws" <> dropWhile (/= ':') (render $ liftWebsocketPool WebsocketWatcherR)
                          webSockets updateBroadcaster
                          liftHandler $ defaultLayout $ do
                              toWidget $ updateReceiver wsurl
                              getWebsocketWatcherWidget

updateReceiver :: Text -> JavascriptUrl url
updateReceiver url = [julius|
    var url = "#{rawJS url}";
    console.log("#{rawJS url}");
    var wsList = document.getElementById("wsList")
    var watcher = new WebSocket(url);
    watcher.onopen = function (e) {
        watcher.send("ready!");
    };
    watcher.onmessage = function (e) {
        var poolObj = JSON.parse(e.data);
        console.log(poolObj)
        wsList.innerHTML = "";
        for (key in poolObj) {
            var info = document.createElement("li");
            var connections = document.createElement("ul");
            var chan = document.createElement("span");
            chan.innerHTML = key;
            wsList.appendChild(info);
            info.appendChild(chan);
            info.appendChild(connections);
            for (channel in poolObj[key]) {
                for (connection in channel) {
                    var con = document.createElement("li");
                    console.log(connection)
                    con.innerHTML = poolObj[key][connection]["originName"];
                    connections.appendChild(con);
                };
            };
        };
    };
|]

updateBroadcaster :: YesodWebsocketPool master => WebSocketsT (SubHandlerFor WebsocketPool master) ()
updateBroadcaster = do wsMonitor <- lift (liftHandler getWebsocketMonitor)
                       chanPool <- lift (liftHandler getChannelPool)
                       fromMonitor <- atomically (dupTChan wsMonitor)
                       WS.race_
                           (forever $ receiveDataMessageE >> atomically (writeTChan wsMonitor "ping"))
                           (forever $ atomically (readTChan fromMonitor) >> atomically (readTVar chanPool) 
                                                                         >>= chanTableEncode
                                                                         >>= sendTextData)

chanTableEncode :: MonadIO m => ChanTable -> m Lazy.ByteString
chanTableEncode ct = liftIO $ encode <$> mapM checkRow ct
    where checkRow (WebsocketChannel _ roster _) = atomically $ readTVar roster 

instance (Yesod master, YesodWebsocketPool master) => YesodSubDispatch WebsocketPool master where
    yesodSubDispatch = $(mkYesodSubDispatch resourcesWebsocketPool)
