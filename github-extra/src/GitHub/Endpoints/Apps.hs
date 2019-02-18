-- The Github Users API, as described at
-- <http://developer.github.com/v3/apps/>.
--
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module GitHub.Endpoints.Apps (
    createInstallationToken,
    createInstallationTokenR,
    module GitHub.Data,
    ) where

import GitHub.Data
import GitHub.Extra
import GitHub.Internal.Prelude
import GitHub.Request
import Prelude ()

-- | Create a new installation token.
-- Requires a Bearer JWT token
createInstallationToken :: Auth -> Id Installation -> IO (Either Error AccessToken)
createInstallationToken auth = executeRequest auth . createInstallationTokenR

-- | Create a new installation token.
-- See <https://developer.github.com/v3/apps/##create-a-new-installation-token>
createInstallationTokenR :: Id Installation -> Request 'RW AccessToken
createInstallationTokenR instId =
  command Post ["app", "installations", toPathPart instId, "access_tokens" ] ""

