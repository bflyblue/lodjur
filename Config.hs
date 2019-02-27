{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RecordWildCards   #-}

module Config where

import           Data.Aeson                   as JSON
import           Data.ByteString              (ByteString)
import           Data.ByteString.Char8        as Char8
import           Data.Text                    (Text)
import           Data.Text.IO                 as Text
import           Data.Text.Encoding           as Text
import           Database.PostgreSQL.Simple
import           Network.OAuth.OAuth2
import           Text.Toml
import           URI.ByteString
import           URI.ByteString.QQ
import qualified Web.JWT                      as JWT

import           Lodjur.Auth
import qualified Lodjur.Build                 as Build
import qualified Lodjur.Git                   as Git
-- import qualified Lodjur.Database              as Database
-- import           Lodjur.Deployment
-- import qualified Lodjur.Deployment.Deployer   as Deployer
-- import qualified Lodjur.Events.EventLogger    as EventLogger
-- import qualified Lodjur.Git.GitAgent          as GitAgent
-- import qualified Lodjur.Git.GitReader         as GitReader
-- import qualified Lodjur.Output.OutputLoggers  as OutputLoggers
-- import qualified Lodjur.Output.OutputStreamer as OutputStreamer
-- import           Lodjur.Process
-- import           Lodjur.Web.Base

data Config = Config
  { workDir                 :: FilePath
  , httpPort                :: Int
  , databaseConnectInfo     :: ConnectInfo
  , githubSecretToken       :: ByteString
  , githubRepos             :: [Text]
  , githubOauth             :: OAuth2
  , githubTeamAuth          :: TeamAuthConfig
  , githubAppId             :: Int
  , githubAppSigner         :: JWT.Signer
  , githubInstallationId    :: Int
  , staticDirectory         :: FilePath
  , gitEnv                  :: Git.Env
  , buildEnv                :: Build.Env
  }

instance FromJSON Config where
  parseJSON = withObject "Configuration" $ \o -> do
    workDir <- o .: "work-dir"
    httpPort <- o .: "http-port"
    databaseConnectInfo <- o .: "database" >>= parseDatabaseConnectInfo
    githubSecretToken <- Char8.pack <$> (o .: "github-secret-token")
    githubRepos <- o .: "github-repos"
    githubAppId <- o .: "github-app-id"
    githubAppSigner <- o .: "github-app-private-key" >>= parsePrivateKey
    githubInstallationId <- o .: "github-installation-id"
    staticDirectory <- o .: "static-directory"
    gitEnv <- o .: "git"
    buildEnv <- o .: "nix-build"

    oauthClientId <- o .: "github-oauth-client-id"
    oauthClientSecret <- o .: "github-oauth-client-secret"
    oauthCallbackUrlStr <- o .: "github-oauth-callback-url"
    oauthCallback <- either (fail . show) (pure . pure) (parseURI strictURIParserOptions (Text.encodeUtf8 oauthCallbackUrlStr))
    let githubOauth = OAuth2
          { oauthOAuthorizeEndpoint = [uri|https://github.com/login/oauth/authorize|]
          , oauthAccessTokenEndpoint = [uri|https://github.com/login/oauth/access_token|]
          , ..
          }
    githubAuthTeam <- o .: "github-authorized-team"
    githubAuthOrg <- o .: "github-authorized-organization"
    let githubTeamAuth = TeamAuthConfig{..}

    return Config{..}
    where
      parseDatabaseConnectInfo o = do
        databaseHost <- o .: "host"
        databasePort <- o .: "port"
        databaseName <- o .: "name"
        databaseUser <- o .: "user"
        databasePassword <- o .: "password"
        return ConnectInfo
          { connectHost     = databaseHost
          , connectPort     = databasePort
          , connectDatabase = databaseName
          , connectUser     = databaseUser
          , connectPassword = databasePassword
          }
      parsePrivateKey key =
        maybe (fail "Invalid RSA secret.") (return . JWT.RSAPrivateKey) $
          JWT.readRsaSecret (Text.encodeUtf8 key)

readConfiguration :: FilePath -> IO Config
readConfiguration path = do
  f <- Text.readFile path
  case parseTomlDoc path f of
    Right toml -> case fromJSON (toJSON toml) of
      JSON.Success config -> pure config
      JSON.Error   e      -> fail e
    Left e -> fail (show e)