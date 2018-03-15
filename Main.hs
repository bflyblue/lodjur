{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import qualified Data.HashSet        as HashSet
import           Data.Semigroup      ((<>))
import           Options.Applicative

import qualified Lodjur.Deployer     as Deployer
import           Lodjur.Deployment
import qualified Lodjur.EventLogger  as EventLogger
import qualified Lodjur.OutputLogger as OutputLogger
import           Lodjur.Process
import           Lodjur.Web

main :: IO ()
main = startServices =<< execParser opts
 where
  opts = info
    (lodjur <**> helper)
    ( fullDesc <> progDesc "Lodjur" <> header
      "Mpowered's Nixops Deployment Frontend"
    )

  startServices Options {..} = do
    let deploymentNames = HashSet.fromList nixopsDeployments
    eventLogger  <- spawn =<< EventLogger.newEventLogger databaseName
    outputLogger <- spawn =<< OutputLogger.newOutputLogger databaseName
    deployer     <- spawn
      (Deployer.initialize eventLogger outputLogger deploymentNames gitWorkingDir)
    runServer port deployer eventLogger

data Options = Options
  { gitWorkingDir     :: FilePath
  , nixopsDeployments :: [DeploymentName]
  , port              :: Port
  , databaseName      :: FilePath
  }

lodjur :: Parser Options
lodjur =
  Options
    <$> strOption
          ( long "git-working-dir" <> metavar "PATH" <> short 'g' <> help
            "Path to Git directory containing deployment expressions"
          )
    <*> many
          ( strOption
            ( long "deployment" <> metavar "NAME" <> short 'd' <> help
              "Names of nixops deployments to support"
            )
          )
    <*> option
          auto
          (  long "port"
          <> metavar "PORT"
          <> short 'p'
          <> help "Port to run the web server on"
          <> showDefault
          <> value 4000
          )
    <*> strOption
          ( long "database" <> metavar "FILE" <> help
            "Path to database"
          <> showDefault
          <> value ":memory:"
          )
