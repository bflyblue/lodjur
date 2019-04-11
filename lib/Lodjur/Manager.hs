{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Lodjur.Manager
  ( Manager(..)
  , ConnectInfo(..)
  , newManager
  , cancelManager
  , submitRequest
  , waitReply
  , parseManagerURI
  , fromURI
  , runManagerClient
  , sendMsg
  , receiveMsg
  )
where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Error
import           Control.Exception
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson                     ( FromJSON, ToJSON, encode, decode' )
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as LB
import           Data.Default.Class
import           Data.Text                      ( Text )
import qualified Network.Connection            as NC
import           Network.Socket                 ( PortNumber )
import qualified Network.URI                   as URI
import           Network.WebSockets      hiding ( runClient )
import           Network.WebSockets.Stream
import qualified Data.HashMap.Strict           as HM
import qualified Lodjur.Manager.Messages       as Msg
import           Text.Read                      ( readMaybe )

import           Lodjur.Manager.Client
import           Lodjur.Manager.State

data Manager a = Manager
  { managerThread       :: ThreadId
  , managerWebServerApp :: ServerApp
  , managerState        :: State a
  }

type ClientMap a = HM.HashMap ClientId (Client a)

data ConnectInfo = ConnectInfo
  { connectSecure       :: Bool     -- Use TLS
  , connectHost         :: String
  , connectPort         :: PortNumber
  , connectPath         :: String
  }

newManager :: IO (Manager a)
newManager = do
  requestQueue      <- newTQueueIO
  replyQueue        <- newTQueueIO
  registeredClients <- newTVarIO HM.empty
  let managerState = State{..}
  managerThread   <- forkIO $ manager managerState
  return Manager { managerWebServerApp = wsapp managerState
                 , .. }

cancelManager :: Manager a -> IO ()
cancelManager mgr =
  killThread (managerThread mgr)

manager :: State a -> IO ()
manager State{..} =
  forever $ atomically $ do
    req <- readTQueue requestQueue
    client <- idleClient registeredClients
    putTMVar (clientRequest client) req

submitRequest :: Manager a -> Msg.Request -> a -> IO ()
submitRequest mgr req a =
  atomically $
    writeTQueue (requestQueue . managerState $ mgr) (req, a)

waitReply :: Manager a -> IO (Msg.Reply, a)
waitReply mgr =
  atomically $
    readTQueue (replyQueue . managerState $ mgr)

idleClient :: TVar (ClientMap a) -> STM (Client a)
idleClient clients = do
  c <- readTVar clients
  idle <- filterM (isEmptyTMVar . clientRequest) (HM.elems c)
  case headMay idle of
    Nothing -> retry
    Just client -> return client

registerClient :: TVar (ClientMap a) -> Client a -> STM (Maybe (Client a))
registerClient clients client = do
  c <- readTVar clients
  writeTVar clients $! HM.insert (clientId client) client c
  return $! HM.lookup (clientId client) c

deregisterClient :: TVar (ClientMap a) -> Client a -> STM ()
deregisterClient clients client =
  modifyTVar' clients $! HM.delete (clientId client)

cancelClient :: Client a -> Text -> IO ()
cancelClient client =
  sendClose (clientConnection client)

wsapp :: State a -> ServerApp
wsapp state pending_conn =
  if validRequest (pendingRequest pending_conn)
    then accept pending_conn state
    else reject pending_conn
  where validRequest _ = True

  -- where validRequest RequestHead {..} = requestPath == "/manager"

data AppError
  = UnexpectedReply
  deriving (Show, Exception)

reject :: PendingConnection -> IO ()
reject pending_conn = rejectRequest pending_conn "Authorization failed"

clientHandshake :: Connection -> IO (Client a)
clientHandshake conn = do
  sendMsg conn Msg.Greet
  msg <- receiveMsg conn
  case msg of
    Msg.Register clientid -> Client clientid conn <$> newEmptyTMVarIO

accept :: PendingConnection -> State a -> IO ()
accept pending_conn State{..} = do
  (conn, client) <- start
  existing <- atomically $ registerClient registeredClients client
  case existing of
    Just c -> cancelClient c "Another client with the same name registered"
    Nothing -> return ()
  serve conn client `finally` cleanup client
 where
  start = do
    putStrLn "Accepted"
    conn <- acceptRequest pending_conn
    forkPingThread conn 30
    client <- clientHandshake conn
    return (conn, client)

  cleanup client = atomically $ do
    req <- tryTakeTMVar (clientRequest client)
    case req of
      Just (_, a) -> writeTQueue replyQueue (Msg.Disconnected, a)
      Nothing -> return ()
    deregisterClient registeredClients client

  serve conn client = forever $ do
    (req, a) <- atomically $ readTMVar (clientRequest client)
    sendMsg conn req
    rep <- receiveMsg conn
    atomically $ do
      _ <- takeTMVar (clientRequest client)
      writeTQueue replyQueue (rep, a)

receiveMsg :: (FromJSON a, MonadIO m) => Connection -> m a
receiveMsg conn = liftIO $ do
  d <- receiveData conn
  putStrLn $ "Recv: " ++ show d
  case decode' d of
    Nothing  -> throwIO UnexpectedReply
    Just msg -> return msg

sendMsg :: (ToJSON a, MonadIO m) => Connection -> a -> m ()
sendMsg conn msg = liftIO $ do
  putStrLn $ "Send: " ++ show (encode msg)
  sendTextData conn . encode $ msg

parseManagerURI :: String -> Maybe ConnectInfo
parseManagerURI = fromURI <=< URI.parseURI

fromURI :: URI.URI -> Maybe ConnectInfo
fromURI uri = do
  guard $ URI.uriIsAbsolute uri
  connectSecure <- case URI.uriScheme uri of
    "ws:"  -> return False
    "wss:" -> return True
    _      -> mzero
  guard $ URI.uriQuery uri == ""
  guard $ URI.uriFragment uri == ""
  auth <- URI.uriAuthority uri
  guard $ URI.uriUserInfo auth == ""
  let connectHost = URI.uriRegName auth
  connectPort <- readMaybe (dropWhile (== ':') $ URI.uriPort auth)
  let connectPath = URI.uriPath uri
  return ConnectInfo { .. }

runManagerClient :: ConnectInfo -> ClientApp a -> IO a
runManagerClient ci app = do
  ctx <- NC.initConnectionContext
  nc  <- NC.connectTo ctx params
  s   <- makeConnectionStream nc
  runClientWithStream s fullhost (connectPath ci) opts [] app
 where
  port = toInteger (connectPort ci)
  fullhost =
    if port == 80 then connectHost ci else connectHost ci ++ ":" ++ show port
  opts   = defaultConnectionOptions
  params = NC.ConnectionParams { connectionHostname  = connectHost ci
                               , connectionPort      = connectPort ci
                               , connectionUseSecure = secure
                               , connectionUseSocks  = Nothing
                               }
  secure = if connectSecure ci then Just def else Nothing

makeConnectionStream :: NC.Connection -> IO Stream
makeConnectionStream conn = makeStream r s
 where
  r = do
    bs <- NC.connectionGetChunk conn
    return $ if B.null bs then Nothing else Just bs

  s Nothing = NC.connectionClose conn
    `Control.Exception.catch` \(_ :: IOException) -> return ()
  s (Just bs) = NC.connectionPut conn (LB.toStrict bs)