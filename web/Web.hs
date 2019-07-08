{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE MultiWayIf             #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}

module Web where

import           Prelude                 hiding ( head )

import           Data.Binary.Builder            ( toLazyByteString )
import           Control.Monad.IO.Class
import           Data.ByteString                ( ByteString )
import           Data.Int                       ( Int32 )
import           Data.String.Conversions
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           GitHub                        as GH
import           GitHub.Endpoints.Users        as GH
import           Lucid
import           Servant
import           Servant.Auth.Server           as S
import           Servant.HTML.Lucid
import           Web.Cookie

import           Auth
import           Job
import           GithubAuth
import           Types

type Web
    = GetNoContent '[HTML] (Html ())
 :<|> Unprotected
 :<|> GHAuth '[GH AuthUser] AuthUser :> Protected

web :: ServerT Web AppM
web
    = home
 :<|> unprotected
 :<|> protected

type Unprotected
    = "login" :> Get '[HTML] (Html ())
 :<|> "auth" :> QueryParam "code" Text :> QueryParam "state" Text :> Get '[HTML] (Headers '[Header "Set-Cookie" SetCookie] (Html ()))
 :<|> "logout" :> Get '[HTML] (Headers '[Header "Set-Cookie" SetCookie] (Html ()))

type Protected
    = "jobs" :> Get '[HTML] (Html ())
 :<|> "job" :> Capture "jobid" Int32 :> Get '[HTML] (Html ())

unprotected :: ServerT Unprotected AppM
unprotected
    = login
 :<|> auth
 :<|> logout

protected :: AuthResult AuthUser -> ServerT Protected AppM
protected (Authenticated authuser)
    = getJobs authuser
 :<|> getJob authuser
protected _ = throwAll err302 { errHeaders = [("Location", "/login")] }

deferredScript :: Text -> Html ()
deferredScript src =
  script_ [src_ src, defer_ "defer"] ("" :: Text)

staticPath :: Text -> Text
staticPath = ("/static" <>)

staticRef :: Text -> Attribute
staticRef = href_ . staticPath

signin_ :: Monad m => HtmlT m ()
signin_ = icon "fas fa-fw fa-sign-in-alt"

signout_ :: Monad m => HtmlT m ()
signout_ = icon "fas fa-fw fa-sign-out-alt"

head :: Text -> Html ()
head title =
  head_ $ do
    title_ (toHtml title)
    meta_ [charset_ "UTF-8"]
    favicon
    fonts
    scripts
    stylesheets

favicon :: Html ()
favicon = do
  link_ [rel_ "apple-touch-icon", sizes_ "57x57", staticRef "/icon/apple-icon-57x57.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "60x60", staticRef "/icon/apple-icon-60x60.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "72x72", staticRef "/icon/apple-icon-72x72.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "76x76", staticRef "/icon/apple-icon-76x76.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "114x114", staticRef "/icon/apple-icon-114x114.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "120x120", staticRef "/icon/apple-icon-120x120.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "144x144", staticRef "/icon/apple-icon-144x144.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "152x152", staticRef "/icon/apple-icon-152x152.png"]
  link_ [rel_ "apple-touch-icon", sizes_ "180x180", staticRef "/icon/apple-icon-180x180.png"]
  link_ [rel_ "icon", type_ "image/png", sizes_ "192x192",  staticRef "/icon/android-icon-192x192.png"]
  link_ [rel_ "icon", type_ "image/png", sizes_ "96x96", staticRef "/icon/favicon-96x96.png"]
  link_ [rel_ "icon", type_ "image/png", sizes_ "32x32", staticRef "/icon/favicon-32x32.png"]
  link_ [rel_ "icon", type_ "image/png", sizes_ "16x16", staticRef "/icon/favicon-16x16.png"]
  link_ [rel_ "manifest", staticRef "/icon/manifest.json"]
  meta_ [name_ "msapplication-TileColor", content_ "#ffffff"]
  meta_ [name_ "msapplication-TileImage", content_ "/icon/ms-icon-144x144.png"]
  meta_ [name_ "theme-color", content_ "#ffffff"]

fonts :: Html ()
fonts = do
  link_ [rel_ "stylesheet", staticRef "/css/fa.css"]
  link_ [rel_ "stylesheet", href_ "https://fonts.googleapis.com/css?family=Roboto&display=swap"]
  link_ [rel_ "stylesheet", href_ "https://fonts.googleapis.com/css?family=Roboto+Condensed&display=swap"]
  link_ [rel_ "stylesheet", href_ "https://fonts.googleapis.com/css?family=Source+Code+Pro&display=swap"]

stylesheets :: Html ()
stylesheets =
  link_ [rel_ "stylesheet", staticRef "/css/lodjur.css"]

scripts :: Html ()
scripts = do
  deferredScript (staticPath "/js/jquery-3.4.1.min.js")
  deferredScript (staticPath "/js/underscore-min.js")
  deferredScript (staticPath "/js/moment.js")
  deferredScript "/js/api.js"
  deferredScript (staticPath "/js/lodjur.js")

redirects :: ByteString -> AppM a
redirects url = throwError err302 { errHeaders = [("Location", cs url)] }

viaShow :: Show a => a -> Text
viaShow = Text.pack . show

home :: AppM (Html ())
home = redirects "/jobs"

login :: AppM (Html ())
login = do
  clientId <- getEnv envGithubClientId
  let endpoint = "https://github.com/login/oauth/authorize?client_id=" <> cs clientId
  return $ doctypehtml_ $ html_ $ do
    head "Lodjur"
    body_ $ do
      div_ $ do
        -- div_ [ class_ "icon" ] signin_
        signin_
        a_ [ href_ endpoint ] "Login with GitHub"

auth :: Maybe Text -> Maybe Text -> AppM (Headers '[Header "Set-Cookie" SetCookie] (Html ()))
auth mcode _mstate = do
  code  <- maybe (throwError err401) return mcode
  token <- getAccessToken code
  muser <- liftIO $ userInfoCurrent' (OAuth token)
  user' <- either (const $ throwError err401) return muser
  pool  <- getEnv Types.envDbPool
  mauth <- liftIO $ userAuthenticated pool user' token
  case mauth of
    Just authuser -> do
      ghSettings <- getEnv envGHSettings
      mcookies <- liftIO $ acceptGHLogin ghSettings authuser
      cookie <- maybe (throwError err401) return mcookies
      throwError err302 { errHeaders = [("Location", "/"), ("Set-Cookie", cs $ toLazyByteString $ renderSetCookie cookie)] }
    Nothing -> throwError err401

logout :: AppM (Headers '[Header "Set-Cookie" SetCookie] (Html ()))
logout = do
  ghSettings <- getEnv envGHSettings
  let cookie = clearGHSession ghSettings
  return $ addHeader cookie $ doctypehtml_ $ html_ $ do
    head "Lodjur"
    body_ $ do
      div_ $ do
        div_ "Logged out."

user :: AuthUser -> Html ()
user u = do
  div_ [ class_ "menu" ] $ do
    div_ [ class_ "menutop user" ] $ do
      case authUserAvatar u of
        Just url -> img_ [ class_ "avatar", src_ url ]
        Nothing -> span_ [ class_ "far fa-user" ] ""
      div_ (toHtml $ authUserName u)
    div_ [ class_ "menuitem" ] $ do
      div_ [ class_ "icon" ] signout_
      a_ [ href_ "/logout" ] "Logout"

getJobs :: AuthUser -> AppM (Html ())
getJobs authuser = do
  return $ doctypehtml_ $ html_ $ do
    head "Lodjur"
    body_ $ do
      div_ [ class_ "app basic" ] $ do
        div_ [ class_ "title-box header" ] $ do
          div_ [ class_ "title" ] $ do
            b_ "Lodjur"
            "\160"
            "3.0"
        div_ [ class_ "user-box header" ] $ do
          user authuser
          -- div_ [ class_ "user"] $ span_ [ class_ "far fa-chevron-down" ] ""
          -- div_ [ class_ "user"] $ span_ [ class_ "far fa-user" ] ""
          -- div_ [ class_ "user"] "Shaun"
        div_ [ class_ "head-box header" ] $ do
          div_ [ class_ "head"] "Recent Jobs"
        div_ [ class_ "content" ] $ do
          div_ [ class_ "job-list card-list" ] ""
        div_ [ class_ "footer" ] ""

getJob :: AuthUser -> Int32 -> AppM (Html ())
getJob authuser jobid = do
  job <- runDb $ lookupJob jobid
  case job of
    Nothing -> throwError err404
    Just Job'{..} -> do
      return $ doctypehtml_ $ html_ $ do
        head "Lodjur"
        body_ $ do
          div_ [ class_ "app basic" ] $ do
            div_ [ class_ "title-box header" ] $ do
              div_ [ class_ "title" ] $ do
                b_ "Lodjur"
                "\160"
                "3.0"
            div_ [ class_ "user-box header" ] $ do
              user authuser
              -- div_ [ class_ "user"] $ span_ [ class_ "far fa-chevron-down" ] ""
              -- div_ [ class_ "user"] $ span_ [ class_ "far fa-user" ] ""
              -- div_ [ class_ "user"] "Shaun"
            div_ [ class_ "head-box header" ] $ do
              div_ [ class_ "head"] $
                toHtml ("Job " <> viaShow job'Id)
            div_ [ class_ "content" ] $ do
              div_ [ class_ "job-detail", data_ "job-id" (cs $ show job'Id) ] ""
              -- div_ [ class_ "job-log", data_ "job-id" (cs $ show job'Id) ] ""
              div_ [ class_ "job-rspec", data_ "job-id" (cs $ show job'Id) ] ""
            div_ [ class_ "footer" ] ""