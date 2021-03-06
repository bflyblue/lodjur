{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE EmptyDataDecls #-}
module Lodjur.Process
  ( Process
  , receive
  , terminate
  , Message
  , Sync
  , Async
  , Ref
  , ActorNotAliveException(..)
  , (!)
  , (?)
  , spawn
  , kill
  ) where

import Control.Concurrent
import Control.Exception

class Process a where
  type Message a :: * -> *
  receive :: Ref a -> (a, Message a r) -> IO (ReceiveType a r)
  terminate :: a -> IO ()

data Sync r
data Async

data QueuedMessage m where
  SyncMessage :: m (Sync r) -> MVar (Either SomeException r) -> QueuedMessage m
  AsyncMessage :: m Async -> QueuedMessage m
  PoisonPill :: QueuedMessage m

type family ReceiveType a r where
  ReceiveType a Async = a
  ReceiveType a (Sync r) = (a, r)

data Ref a = Ref { inbox :: Chan (QueuedMessage (Message a))
                 , alive :: MVar Bool
                 }

data ActorNotAliveException = ActorNotAliveException deriving (Show)

instance Exception ActorNotAliveException

requireAlive :: Ref a -> IO b -> IO b
requireAlive ref action = do
  isAlive <- readMVar (alive ref)
  if isAlive then action else throwIO ActorNotAliveException

(!) :: Process a => Ref a -> Message a Async -> IO ()
(!) receiver msg =
  requireAlive receiver $
    writeChan (inbox receiver) (AsyncMessage msg)

(?) :: Process a => Ref a -> Message a (Sync r) -> IO r
(?) receiver msg = requireAlive receiver $ do
    res <- newEmptyMVar
    writeChan (inbox receiver) (SyncMessage msg res)
    either throwIO return =<< takeMVar res

spawn :: Process a => a -> IO (Ref a)
spawn initialState = do
  inbox' <- newChan
  aliveVar <- newMVar True
  let ref = Ref inbox' aliveVar
  _ <- forkIO (receiveLoop ref initialState)
  return ref
 where
  receiveLoop ref state =
    readChan (inbox ref) >>= \case
      SyncMessage msg sender -> do
        (state', response) <-
          ( do (state', response) <- receive ref (state, msg)
               return (state', Right response)
          ) `catch` \e -> return (state, Left e)
        putMVar     sender response
        receiveLoop ref    state'
      AsyncMessage msg -> do
        state' <- receive ref (state, msg)
        receiveLoop ref state'
      PoisonPill -> do
        terminate state
        modifyMVar_ (alive ref) (const (return False))

kill :: Process a => Ref a -> IO ()
kill receiver = writeChan (inbox receiver) PoisonPill
