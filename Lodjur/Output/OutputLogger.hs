{-# LANGUAGE GADTs           #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies    #-}
module Lodjur.Output.OutputLogger
  ( Output (..)
  , OutputLogger
  , OutputLogMessage (..)
  , initialize
  , logCreateProcessWithExitCode
  ) where

import           Control.Concurrent
import           Control.Exception      (tryJust)
import           Control.Monad          (void)
import           Data.Time.Clock
import           System.Exit
import           System.IO
import           System.IO.Error        (isEOFError)
import           System.Process

import           Lodjur.Database        (DbPool)
import           Lodjur.Deployment      hiding (jobId)
import           Lodjur.Output
import qualified Lodjur.Output.Database as Database
import           Lodjur.Process

data OutputLogger = OutputLogger { dbPool :: DbPool , jobId :: JobId }

initialize :: DbPool -> JobId -> IO OutputLogger
initialize dbPool jobId = return OutputLogger {..}

data OutputLogMessage r where
  -- Public messages:
  AppendOutput :: [String] -> OutputLogMessage Async
  OutputFence :: OutputLogMessage Async
  GetOutputLog :: OutputLogMessage (Sync [Output])

instance Process OutputLogger where
  type Message OutputLogger = OutputLogMessage

  receive _self (logger, AppendOutput lines') = do
    now <- getCurrentTime
    Database.appendOutput (dbPool logger) (jobId logger) now lines'
    return logger

  receive _self (logger, OutputFence) = do
    Database.fence (dbPool logger) (jobId logger)
    return logger

  receive _self (logger, GetOutputLog) = do
    out <- Database.getOutputLog (dbPool logger) Nothing Nothing (jobId logger)
    return (logger, out)

  terminate _ = return ()

logCreateProcessWithExitCode
  :: Ref OutputLogger -> CreateProcess -> IO ExitCode
logCreateProcessWithExitCode outputLogger cp = do
  let cp_opts =
        cp { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }

  (_, Just hout, Just herr, ph) <- createProcess cp_opts
  outStreamDone <- newEmptyMVar
  errStreamDone <- newEmptyMVar
  void $ logStream outputLogger hout outStreamDone
  void $ logStream outputLogger herr errStreamDone
  code <- waitForProcess ph
  _ <- readMVar outStreamDone
  _ <- readMVar errStreamDone
  return code

logStream :: Ref OutputLogger -> Handle -> MVar () -> IO ThreadId
logStream logger h done = forkIO go
 where
  go = do
    next <- tryJust (\e -> if isEOFError e then Just () else Nothing)
                    (hGetLine h)
    case next of
      Left  _    -> putMVar done ()
      Right line -> do
        logger ! AppendOutput [line]
        go
