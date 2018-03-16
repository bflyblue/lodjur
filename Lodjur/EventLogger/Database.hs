{-# LANGUAGE OverloadedStrings #-}
module Lodjur.EventLogger.Database where

import           Control.Exception
import           Control.Monad              (void, foldM)
import           Data.Aeson
import qualified Data.HashMap.Strict        as HashMap
import           Data.Time.Clock            (UTCTime)
import           Database.PostgreSQL.Simple

import           Lodjur.Database
import           Lodjur.Deployment

initialize :: DbPool -> IO ()
initialize pool = withConn pool $ \conn ->
  void $ execute_ conn
    "CREATE TABLE IF NOT EXISTS event_log (time TIMESTAMPTZ NOT NULL, job_id TEXT NOT NULL, event JSONB NOT NULL)"

insertEvent :: DbPool -> UTCTime -> JobId -> JobEvent -> IO ()
insertEvent pool t jobid event = withConn pool $ \conn -> void $ execute
  conn
  "INSERT INTO event_log (time, job_id, event) VALUES (?, ?, ?)"
  (t, jobid, toJSON event)

getAllEventLogs :: DbPool -> IO EventLogs
getAllEventLogs pool = withConn pool $ \conn -> mkEventLog
  =<< query_ conn "SELECT job_id, event FROM event_log ORDER BY time ASC"
 where
  mkEventLog :: [(JobId, Value)] -> IO EventLogs
  mkEventLog = foldM mergeEvent mempty
  mergeEvent m (jobid, event) = case fromJSON event of
    Error   msg -> throwIO $ EventDecodeFailed msg
    Success e   -> return $ HashMap.insertWith (++) jobid [e] m
