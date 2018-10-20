{-# LANGUAGE OverloadedStrings #-}

module Lib where

import Control.Concurrent (MVar, newMVar, modifyMVar_, modifyMVar, readMVar)
import Control.Exception (finally)
import Control.Monad (forever, forM_)

import Data.Char (isSpace)
import Data.UUID (UUID, toText)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as T

import System.Random (randomIO)

import qualified Network.WebSockets as WS

type Client = (UUID, WS.Connection)
type Room = T.Text

type ServerState = M.Map Room [Client]

mainApplication :: IO ()
mainApplication = do
    state <- newMVar newServerState
    putStrLn "Starting server on localhost port 9160..."
    WS.runServer "127.0.0.1" 9160 $ application state

newServerState :: ServerState
newServerState = M.empty

addClientToRoom :: Client -> Room -> ServerState -> ServerState
addClientToRoom client room state = M.alter (pure . insertOrAdd client) room state
    where
        insertOrAdd :: a -> Maybe [a] -> [a]
        insertOrAdd a (Just as) = a:as
        insertOrAdd a Nothing = [a]

removeClientFromRoom :: Client -> Room -> ServerState -> ServerState
removeClientFromRoom (uuid, _) room state = M.adjust (filter ((/= uuid) . fst)) room state

sendError :: WS.Connection -> T.Text -> IO ()
sendError conn msg = WS.sendTextData conn $ "Error: " <> msg

application :: MVar ServerState -> WS.ServerApp
application state pending = do
    conn <- WS.acceptRequest pending
    WS.forkPingThread conn 30

    uuid <- (randomIO :: IO UUID)
    let client = (uuid, conn)

    T.putStrLn $ "Connected to " <> (toText uuid)

    requestedRoom <- WS.receiveData conn
    case requestedRoom of
        _ | any ($ requestedRoom) [T.any isSpace, (/= 10) . T.length] ->
              sendError conn "Invalid room id"
          | otherwise -> flip finally (disconnect client requestedRoom) $ do
              modifyMVar_ state $ \s -> do
                  let s' = addClientToRoom client requestedRoom s
                  WS.sendTextData conn $ toText uuid
                  return s'
              listenForeverToClientInRoom client requestedRoom state

    where
        disconnect client room = modifyMVar_ state (pure . removeClientFromRoom client room)

broadcastToRoom :: Room -> UUID -> T.Text -> ServerState -> IO ()
broadcastToRoom room uuid message state = do
    let conns = filter ((/= uuid) . fst) $ M.findWithDefault [] room state
    T.putStrLn (room <> " (" <> (T.pack . show $ 1 + length conns) <> " members): " <> message)
    forM_ conns $ \(_, conn) -> WS.sendTextData conn message

listenForeverToClientInRoom :: Client -> Room -> MVar ServerState -> IO ()
listenForeverToClientInRoom (uuid, conn) room state = forever $ do
    msg <- WS.receiveData conn
    readMVar state >>= broadcastToRoom room uuid msg

