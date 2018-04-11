{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
module Lodjur.Web (Port, runServer) where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class          (liftIO)
import           Control.Monad.Reader
import           Crypto.Hash
import           Crypto.MAC.HMAC
import           Data.Aeson
import           Data.Aeson.Types
import qualified Data.Binary.Builder             as Binary
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString.Base16          as Base16
import qualified Data.ByteString.Lazy            as LByteString
import qualified Data.ByteString.Lazy.Char8      as C8
import qualified Data.HashMap.Strict             as HashMap
import qualified Data.List                       as List
import           Data.Maybe                      (maybeToList)
import           Data.Semigroup
import           Data.String
import           Data.Text                       (Text)
import qualified Data.Text                       as Text
import qualified Data.Text.Encoding              as Text
import qualified Data.Text.Lazy                  as LText
import           Data.Time.Clock                 (UTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX
import           Data.Time.Format                (defaultTimeLocale, formatTime)
import           GHC.Generics                    (Generic)
import           Lucid.Base                      (Html, toHtml)
import qualified Lucid.Base                      as Html
import           Lucid.Bootstrap
import           Lucid.Html5
import           Network.HTTP.Types.Status
import           Network.Wai                     (rawPathInfo)
import           Network.Wai.Middleware.HttpAuth (AuthSettings (..), CheckCreds,
                                                  basicAuth)
import           Network.Wai.Middleware.Static   (Policy, addBase, staticPolicy,
                                                  policy, (>->))
import           Web.Scotty.Trans

import           Lodjur.Deployment.Deployer
import           Lodjur.Events.EventLogger
import           Lodjur.Git.GitAgent
import           Lodjur.Git.GitReader
import           Lodjur.Output.OutputLogger
import           Lodjur.Output.OutputLoggers
import           Lodjur.Output.OutputStreamer
import           Lodjur.Process

data Env = Env
  { envDeployer          :: Ref Deployer
  , envEventLogger       :: Ref EventLogger
  , envOutputLoggers     :: Ref OutputLoggers
  , envOutputStreamer    :: Ref OutputStreamer
  , envGitAgent          :: Ref GitAgent
  , envGitReader         :: Ref GitReader
  , envGithubRepos       :: [Text]
  , envGithubSecretToken :: ByteString
  }

type Action = ActionT LText.Text (ReaderT Env IO)

readState :: Action DeployState
readState = lift (asks envDeployer) >>= liftIO . (? GetCurrentState)

renderHtml :: Html () -> Action ()
renderHtml = html . Html.renderText

formatUTCTime :: UTCTime -> String
formatUTCTime = formatTime defaultTimeLocale "%c"

hourMinSec :: UTCTime -> String
hourMinSec = formatTime defaultTimeLocale "%H:%M:%S"

renderLayout :: Html () -> [Html ()] -> Html () -> Action ()
renderLayout title breadcrumbs contents =
  renderHtml $ doctypehtml_ $ html_ $ do
    head_ $ do
      title_ title
      link_ [rel_ "stylesheet", href_ (static "bootstrap/css/bootstrap.min.css")]
      link_ [rel_ "stylesheet", href_ (static "lodjur.css")]
      Html.termRawWith "script" [src_ (static "job.js"), Html.makeAttribute "defer" "defer"] mempty
    body_ $ do
      nav_ [class_ "navbar navbar-dark bg-dark"] $
        div_ [class_ "container"] $
          a_ [class_ "navbar-brand", href_ "/"] "Lodjur"
      nav_ [class_ "breadcrumb-nav"] $
        div_ [class_ "container"] $
          ol_ [class_ "breadcrumb"] (toBreadcrumbItems (homeLink : breadcrumbs))
      container_ contents
 where
  toBreadcrumbItems :: [Html ()] -> Html ()
  toBreadcrumbItems []       = return ()
  toBreadcrumbItems elements = do
    foldMap (li_ [class_ "breadcrumb-item"])  (init elements)
    li_     [class_ "breadcrumb-item active"] (last elements)
  homeLink = a_ [href_ "/"] "Home"

renderEventLog :: EventLog -> Html ()
renderEventLog []       = p_ [class_ "text-secondary"] "No events available."
renderEventLog eventLog = table_ [class_ "table"] $ do
  tr_ $ do
    th_ "Event"
    th_ "Time"
    th_ "Description"
  mapM_ renderEvent eventLog
 where
  renderEvent :: JobEvent -> Html ()
  renderEvent event = tr_ $ case event of
    JobRunning startedAt -> do
      td_ $ span_ [class_ "text-primary"] "Started"
      td_ (toHtml (formatUTCTime startedAt))
      td_ ""
    JobFinished JobSuccessful finishedAt -> do
      td_ $ span_ [class_ "text-success"] "Finished"
      td_ (toHtml (formatUTCTime finishedAt))
      td_ ""
    JobFinished (JobFailed e) finishedAt -> do
      td_ $ span_ [class_ "text-danger"] "Failed"
      td_ (toHtml (formatUTCTime finishedAt))
      td_ [style_ "color: red;"] (toHtml e)

renderDeployJobs :: DeploymentJobs -> Html ()
renderDeployJobs []   = p_ [class_ "text-secondary"] "No jobs available."
renderDeployJobs jobs = div_ [class_ "card"] $ do
  div_ [class_ "card-header"] "Latest Jobs"
  table_ [class_ "table mb-0"] $ do
    tr_ $ do
      th_ "Job"
      th_ "Deployment"
      th_ "Tag"
      th_ "Created At"
      th_ "Result"
    mapM_ renderJob jobs
 where
  renderJob :: (DeploymentJob, Maybe JobResult) -> Html ()
  renderJob (job, r) = tr_ $ do
    td_ (jobLink job)
    td_ (toHtml (unDeploymentName (deploymentName job)))
    td_ (toHtml (unTag (deploymentTag job)))
    td_ (toHtml (formatUTCTime (deploymentTime job)))
    case r of
      Just JobSuccessful      -> td_ [class_ "text-success"] "Successful"
      Just (JobFailed reason) -> td_ [class_ "text-danger"] (toHtml reason)
      Nothing                 -> td_ [class_ "text-primary"] "Running"

renderCurrentState :: DeployState -> Html ()
renderCurrentState state = div_ [class_ "card"] $ do
  div_ [class_ "card-header"] "Current State"
  div_ [class_ "card-body text-center"] $ case state of
    Idle          -> span_ [class_ "text-muted h3"] "Idle"
    Deploying job -> do
      div_ [class_ "text-warning h3"] "Deploying"
      a_ [href_ (jobHref job), class_ "text-warning"] $ do
        toHtml (unTag (deploymentTag job))
        " to "
        toHtml (unDeploymentName (deploymentName job))

successfulJobsByDeploymentName
  :: [DeploymentName]
  -> DeploymentJobs
  -> [(DeploymentName, DeploymentJob)]
successfulJobsByDeploymentName deploymentNames jobs = foldMap
  (\name -> (name,) . fst <$> take 1 (List.filter (successfulJobIn name) jobs))
  deploymentNames
 where
  successfulJobIn n = \case
    (job, Just JobSuccessful) -> deploymentName job == n
    _                         -> False

-- TODO: Convert this to a database query.
renderLatestSuccessful :: [DeploymentName] -> DeploymentJobs -> Html ()
renderLatestSuccessful deploymentNames jobs =
  div_ [class_ "card"] $ do
    div_ [class_ "card-header text-success"] "Latest Successful"
    case successfulJobsByDeploymentName deploymentNames jobs of
      [] -> div_ [class_ "card-body text-muted"] "No successful jobs yet."
      successfulJobs ->
        table_ [class_ "table table-bordered mb-0"] $
          forM_ successfulJobs $ \(name, job) -> tr_ $ do
            td_ (toHtml (unDeploymentName name))
            td_ (toHtml (unTag (deploymentTag job)))
            td_ (jobLink job)

renderDeployCard :: [DeploymentName] -> [Tag] -> DeployState -> Html ()
renderDeployCard deploymentNames tags state = case state of
  Idle -> div_ [class_ "card"] $ do
    div_ [class_ "card-header"] "New Deploy"
    div_ [class_ "card-body"]
      $ form_ [method_ "post", action_ "/jobs"]
      $ div_ [class_ "row"]
      $ do
          div_ [class_ "col"] $ do
            select_ [name_ "deployment-name", class_ "form-control"]
              $ forM_ deploymentNames
              $ \(unDeploymentName -> n) ->
                  option_ [value_ (Text.pack n)] (toHtml n)
            small_ [class_ "text-muted"]
                   "Name of the Nixops deployment to target."
          div_ [class_ "col"] $ do
            select_ [name_ "tag", class_ "form-control"]
              $ forM_ tags
              $ \(unTag -> tag) -> option_ [value_ tag] (toHtml tag)
            small_ [class_ "text-muted"] "Which git tag to deploy."
          div_ [class_ "col"]
            $ input_
                [ class_ "btn btn-primary form-control"
                , type_ "submit"
                , value_ "Deploy"
                ]
  Deploying _ -> return ()

notFoundAction :: Action ()
notFoundAction = do
  status status404
  renderLayout "Not Found" [] $ do
    h1_ [class_ "mt-5"] "Not Found"
    p_ [class_ "lead"] $ do
      "The requested page could not be found. Try "
      a_ [href_ "/"] "going back to the start page"
      "."

badRequestAction :: Html () -> Action ()
badRequestAction message = do
  status status400
  renderLayout "Bad request!" [] $ do
    h1_ [class_ "mt-5"] "Bad request!"
    p_  [class_ "lead"] message

jobIdHref :: JobId -> Text
jobIdHref jobId = "/jobs/" <> jobId

jobHref :: DeploymentJob -> Text
jobHref = jobIdHref . jobId

jobIdLink :: JobId -> Html ()
jobIdLink jobId = a_ [href_ (jobIdHref jobId)] (toHtml jobId)

jobLink :: DeploymentJob -> Html ()
jobLink = jobIdLink . jobId

homeAction :: Action ()
homeAction = do
  deployer        <- lift (asks envDeployer)
  gitReader       <- lift (asks envGitReader)
  deploymentNames <- liftIO $ deployer ? GetDeploymentNames
  tags            <- liftIO $ gitReader ? GetTags
  deployState     <- liftIO $ deployer ? GetCurrentState
  jobs            <- liftIO $ deployer ? GetJobs
  renderLayout "Lodjur Deployment Manager" [] $ do
    div_ [class_ "row mt-5"] $ do
      div_ [class_ "col col-4"] $ renderCurrentState deployState
      div_ [class_ "col"] $ renderLatestSuccessful deploymentNames jobs
    div_ [class_ "row mt-5"] $ div_ [class_ "col"] $ renderDeployJobs jobs
    div_ [class_ "row mt-5 mb-5"] $ div_ [class_ "col"] $ renderDeployCard
      deploymentNames
      tags
      deployState

newDeployAction :: Action ()
newDeployAction = readState >>= \case
  Idle -> do
    deployer <- lift (asks envDeployer)
    dName    <- DeploymentName <$> param "deployment-name"
    tag      <- Tag <$> param "tag"
    now      <- liftIO getCurrentTime
    liftIO (deployer ? Deploy dName tag now) >>= \case
      Just job -> do
        status status302
        setHeader "Location" (LText.fromStrict (jobHref job))
      Nothing -> badRequestAction "Could not deploy!"
  Deploying job ->
    badRequestAction $ "Already deploying " <> jobLink job <> "."

getJobLogs :: JobId -> Action (Maybe [Output])
getJobLogs jobId = do
  outputLoggers <- lift (asks envOutputLoggers)
  liftIO $ do
    logger <- outputLoggers ? SpawnOutputLogger jobId
    logs <- logger ? GetOutputLogs
    kill logger
    return (HashMap.lookup jobId logs)

showJobAction :: Action ()
showJobAction = do
  jobId         <- param "job-id"
  eventLogger   <- lift (asks envEventLogger)
  deployer      <- lift (asks envDeployer)
  job           <- liftIO $ deployer ? GetJob jobId
  eventLogs     <- liftIO $ eventLogger ? GetEventLogs
  outputLog     <- getJobLogs jobId
  case (job, HashMap.lookup jobId eventLogs) of
    (Just (job', _), Just eventLog) ->
      renderLayout "Job Details" ["Jobs", jobIdLink jobId] $ do
        div_ [class_ "row mt-5 mb-5"] $ div_ [class_ "col"] $ do
          "Deploy of tag "
          em_ $ toHtml (unTag (deploymentTag job'))
          " to "
          em_ $ toHtml (unDeploymentName (deploymentName job'))
          "."
        div_ [class_ "row mt-3"] $ div_ [class_ "col"] $ do
          h2_ [class_ "mb-3"] "Event Log"
          renderEventLog eventLog
        div_ [class_ "row mt-3 mb-5"] $ div_ [class_ "col"] $ do
          h2_ [class_ "mb-3"] "Command Output"
          let lineAttr = data_ "last-line-at" . lastLineAt <$> outputLog
              allAttrs = maybeToList lineAttr <> [class_ "command-output", data_ "job-id" jobId]
          div_ allAttrs $ pre_ $
            case outputLog of
              Just outputs -> foldM_ displayOutput Nothing outputs
              Nothing -> mempty
    _ -> notFoundAction
 where
  displayOutput :: Maybe UTCTime -> Output -> Html (Maybe UTCTime)
  displayOutput previousTime output = div_ [class_ "line"] $ do
    case previousTime of
      Just t
        | t `sameSecond` outputTime output -> return ()
      _ -> time_ $ toHtml (hourMinSec (outputTime output))
    toHtml (unlines (outputLines output))
    return (Just (outputTime output))
  sameSecond t1 t2 = toSeconds t1 == toSeconds t2
  toSeconds :: UTCTime -> Integer
  toSeconds = round . utcTimeToPOSIXSeconds
  lastLineAt =
    \case
      [] -> ""
      outputLog -> Text.pack (show $ outputIndex (last outputLog))

data OutputEvent = OutputLineEvent
  { outputEventIndex :: Integer
  , outputEventTime  :: UTCTime
  , outputEventLines :: [String]
  } deriving (Generic, ToJSON)

maybeParam :: Parsable a => LText.Text -> Action (Maybe a)
maybeParam name = rescue (Just <$> param name) (const $ return Nothing)

streamOutputAction :: Action ()
streamOutputAction = do
  jobId <- param "job-id"
  from  <- maybeParam "from"
  outputStreamer <- lift (asks envOutputStreamer)
  chan <- liftIO newChan
  liftIO $ outputStreamer ! SubscribeOutputLog jobId from chan
  setHeader "Content-Type" "text/event-stream"
  setHeader "Cache-Control" "no-cache"
  setHeader "X-Accel-Buffering" "no"
  stream (streamLog outputStreamer chan jobId)

 where
    streamLog outputStreamer chan jobId send flush = do
      moutput <- liftIO $ readChan chan
      case moutput of
        NextOutput output -> do
          void . send $ Binary.fromByteString "event: output\n"
          let event = OutputLineEvent { outputEventIndex = outputIndex output
                                      , outputEventTime = outputTime output
                                      , outputEventLines = outputLines output
                                      }
          void . send $ Binary.fromLazyByteString ("data: " <> encode event <> "\n")
          void . send $ Binary.fromByteString "\n"
          void flush
          streamLog outputStreamer chan jobId send flush
        Fence -> do
          void . send $ Binary.fromByteString "event: end\n"
          void flush
          void . liftIO $ outputStreamer ? UnsubscribeOutputLog jobId chan

data GithubRepository = GithubRepository
  { repositoryId       :: Integer
  , repositoryName     :: Text
  , repositoryFullName :: Text
  } deriving (Eq, Show)

instance FromJSON GithubRepository where
  parseJSON (Object o) = do
    repositoryId        <- o .: "id"
    repositoryName      <- o .: "name"
    repositoryFullName  <- o .: "full_name"
    return GithubRepository {..}
  parseJSON invalid = typeMismatch "GithubRepository" invalid

data GithubPushEvent = GithubPushEvent
  { pushRef        :: Text
  , pushRepository :: GithubRepository
  } deriving (Eq, Show)

instance FromJSON GithubPushEvent where
  parseJSON (Object o) = do
    pushRef         <- o .: "ref"
    pushRepository  <- o .: "repository"
    return GithubPushEvent {..}
  parseJSON invalid = typeMismatch "GithubPushEvent" invalid

data GithubCreateEvent = GithubCreateEvent
  { createRef        :: Text
  , createRepository :: GithubRepository
  } deriving (Eq, Show)

instance FromJSON GithubCreateEvent where
  parseJSON (Object o) = do
    createRef        <- o .: "ref"
    createRepository <- o .: "repository"
    return GithubCreateEvent {..}
  parseJSON invalid = typeMismatch "GithubCreateEvent" invalid

data GithubDeleteEvent = GithubDeleteEvent
  { deleteRef        :: Text
  , deleteRepository :: GithubRepository
  } deriving (Eq, Show)

instance FromJSON GithubDeleteEvent where
  parseJSON (Object o) = do
    deleteRef        <- o .: "ref"
    deleteRepository <- o .: "repository"
    return GithubDeleteEvent {..}
  parseJSON invalid = typeMismatch "GithubDeleteEvent" invalid

secureJsonData :: FromJSON a => Action a
secureJsonData = do
  key <- lift (asks envGithubSecretToken)
  message <- body
  xhubsig <- header "X-HUB-SIGNATURE" >>= maybe (raise "Github didn't send a valid X-HUB-SIGNATURE") return
  signature <- maybe (raise "Github X-HUB-SIGNATURE didn't start with 'sha1='") return
                 (LText.stripPrefix "sha1=" xhubsig)
  digest <- maybe (raise "Invalid SHA1 digest sent in X-HUB-SIGNATURE") return
              (digestFromByteString $ fst $ Base16.decode $ Text.encodeUtf8 $ LText.toStrict signature)
  unless (hmac key (LByteString.toStrict message) == HMAC (digest :: Digest SHA1)) $
    raise "Signatures don't match"
  either (\e -> raise $ stringError $ "jsonData - no parse: " ++ e ++ ". Data was:" ++ C8.unpack message) return
    (eitherDecode message)

matchRepo :: [Text] -> Text -> Bool
matchRepo [] _ = True
matchRepo rs r = r `elem` rs

refreshTagsAction :: Action ()
refreshTagsAction = do
  event <- header "X-GitHub-Event"
  case event of
    Just "push" -> do
      payload <- secureJsonData
      refresh (repositoryFullName $ pushRepository payload)
    Just "create" -> do
      payload <- secureJsonData
      refresh (repositoryFullName $ createRepository payload)
    Just "delete" -> do
      payload <- secureJsonData
      refresh (repositoryFullName $ deleteRepository payload)
    _ ->
      raise "Unsupported event"
 where
  refresh repo = do
    repos <- lift (asks envGithubRepos)
    if matchRepo repos repo
      then do
        gitAgent <- lift (asks envGitAgent)
        liftIO (gitAgent ! FetchTags)
        text "Queued FetchTags"
      else
        text "Ignored refresh request for uninteresting repository"

type Port = Int

authSettings :: AuthSettings
authSettings = "Lodjur" { authIsProtected = isProtected }
  where
    isProtected req = return (rawPathInfo req `notElem` unauthorizedRoutes)
    unauthorizedRoutes = ["/tags/refresh"]

checkCredentials :: (ByteString, ByteString) -> CheckCreds
checkCredentials (cUser, cPass) user pass =
  return (user == cUser && pass == cPass)

staticPrefix :: String
staticPrefix = "static/"

static :: (Data.String.IsString a, Semigroup a) => a -> a
static x = "/static/" <> x

redirectStatic :: String -> Policy
redirectStatic staticBase =
  policy (List.stripPrefix staticPrefix) >-> addBase staticBase

runServer
  :: Port
  -> (ByteString, ByteString)
  -> String
  -> Ref Deployer
  -> Ref EventLogger
  -> Ref OutputLoggers
  -> Ref OutputStreamer
  -> Ref GitAgent
  -> Ref GitReader
  -> ByteString
  -> [Text]
  -> IO ()
runServer port authCreds staticBase envDeployer envEventLogger envOutputLoggers envOutputStreamer envGitAgent envGitReader envGithubSecretToken envGithubRepos =
  scottyT port (`runReaderT` Env {..}) $ do
    -- Middleware
    middleware (basicAuth (checkCredentials authCreds) authSettings)
    middleware (staticPolicy (redirectStatic staticBase))
    -- Routes
    get  "/"                    homeAction
    post "/jobs"                newDeployAction
    get  "/jobs/:job-id"        showJobAction
    get  "/jobs/:job-id/output" streamOutputAction
    post "/tags/refresh"        refreshTagsAction
    -- Fallback
    notFound notFoundAction
