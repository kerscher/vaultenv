{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad          (forM)
import Control.Lens           (reindexed, to)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Char
import Data.Either            (isLeft)
import Data.List              (findIndex, lookup)
import Data.Monoid            ((<>))
import Network.HTTP.Simple
import Options.Applicative    hiding (Parser, command)
import System.Environment
import System.Posix.Process
import System.IO              (stderr, hPutStrLn)
import Control.Monad.Reader   (ReaderT, runReaderT, asks)
import Control.Monad.Except   (ExceptT, MonadError, runExceptT, throwError)

import qualified Control.Concurrent.Async   as Async
import qualified Control.Exception          as Exception
import qualified Control.Retry              as Retry
import qualified Data.Aeson.Lens            as Lens (key, members, _String)
import qualified Data.Bifunctor             as Bifunctor
import qualified Data.ByteString.Char8      as SBS
import qualified Data.ByteString.Lazy       as LBS hiding (unpack)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Foldable              as Foldable
import qualified Data.Map                   as Map
import qualified Data.Map.Lens              as Lens (toMapOf)
import qualified Data.Text                  as Text
import qualified Options.Applicative        as O

--
-- Datatypes
--

data Options = Options
  { oVaultHost       :: String
  , oVaultPort       :: Int
  , oVaultToken      :: String
  , oSecretFile      :: FilePath
  , oCmd             :: String
  , oArgs            :: [String]
  , oConnectInsecure :: Bool
  , oInheritEnvOff   :: Bool
  } deriving (Eq, Show)

data Secret = Secret
  { sPath    :: String
  , sKey     :: String
  , sVarName :: String
  } deriving (Eq, Show)

type EnvVar = (String, String)

type ExecCtx = ([EnvVar], Options)

type VaultData = Map.Map String String

data VaultError
  = SecretNotFound    String
  | IOError           FilePath
  | ParseError        FilePath
  | KeyNotFound       Secret
  | BadRequest        LBS.ByteString
  | Forbidden
  | ServerError       LBS.ByteString
  | ServerUnavailable LBS.ByteString
  | ServerUnreachable HttpException
  | InvalidUrl        String
  | DuplicateVar      String
  | Unspecified       Int LBS.ByteString

--
-- Argument parsing
--

optionsParser :: [EnvVar] -> O.Parser Options
optionsParser env = Options
       <$> strOption
           (  long "host"
           <> metavar "HOST"
           <> value "localhost"
           <> help "Vault host, either an IP address or DNS name, defaults to localhost" )
       <*> option auto
           (  long "port"
           <> metavar "PORT"
           <> value 8200
           <> help "Vault port, defaults to 8200" )
       <*> strOption
           (  long "token"
           <> metavar "TOKEN"
           <> environ env "VAULT_TOKEN"
           <> help "token to authenticate to Vault with, defaults to the value of the VAULT_TOKEN environment variable if present")
       <*> strOption
           (  long "secrets-file"
           <> metavar "FILENAME"
           <> help "config file specifying which secrets to request" )
       <*> argument str
           (  metavar "CMD"
           <> help "command to run after fetching secrets")
       <*> many (argument str
           (  metavar "ARGS..."
           <> help "arguments to pass to CMD, defaults to nothing"))
       <*> switch
           (  long "no-connect-tls"
           <> help "don't use TLS when connecting to Vault (default: use TLS)")
       <*> switch
           (  long "no-inherit-env"
           <> help "don't merge the parent environment with the secrets file")
  where
    environ vars key = maybe mempty value (lookup key vars)

-- | Add metadata to the `options` parser so it can be used with execParser.
optionsInfo :: [EnvVar] -> ParserInfo Options
optionsInfo env =
  info
    (optionsParser env <**> helper)
    (fullDesc <> header "vaultenv - run programs with secrets from HashiCorp Vault")

-- | Retry configuration to use for network requests to Vault.
-- We use a limited exponential backoff with the policy
-- fullJitterBackoff that comes with the Retry package.
vaultRetryPolicy :: (MonadIO m) => Retry.RetryPolicyM m
vaultRetryPolicy =
  let
    -- Try at most 10 times in total
    maxRetries = 9
    -- The base delay is 40 milliseconds because, in testing,
    -- we found out that fetching 50 secrets takes roughly
    -- 200 milliseconds.
    baseDelayMicroSeconds = 40000
  in Retry.fullJitterBackoff baseDelayMicroSeconds
  <> Retry.limitRetries maxRetries

--
-- IO
--

main :: IO ()
main = do
  env <- getEnvironment
  opts <- execParser (optionsInfo env)

  eres <- runExceptT $ runReaderT vaultEnv (env, opts)
  case eres of
    Left err -> hPutStrLn stderr (vaultErrorLogMessage err)
    Right newEnv -> runCommand opts newEnv

vaultEnv :: ReaderT ExecCtx (ExceptT VaultError IO) [EnvVar]
vaultEnv = do
  secretFile <- asks (oSecretFile . snd)
  secrets <- readSecretList secretFile
  opts <- asks snd
  secretEnv <- requestSecrets opts secrets
  localEnv <- asks fst
  inheritEnvOff <- asks (oInheritEnvOff . snd)
  checkNoDuplicates (buildEnv localEnv secretEnv inheritEnvOff)
    where
      checkNoDuplicates :: MonadError VaultError m => [EnvVar] -> m [EnvVar]
      checkNoDuplicates e =
        either (throwError . DuplicateVar) (return . const e) $ dups (map fst e)

      -- We need to check duplicates in the environment and fail if
      -- there are any. `dups` runs in O(n^2),
      -- but this shouldn't matter for our small lists.
      --
      -- Equality is determined on the first element of the env var
      -- tuples.
      dups :: Eq a => [a] -> Either a ()
      dups [] = Right ()
      dups (x:xs) | isDup x xs = Left x
                  | otherwise = dups xs

      isDup x = foldr (\y acc -> acc || x == y) False

      buildEnv :: [EnvVar] -> [EnvVar] -> Bool -> [EnvVar]
      buildEnv local remote inheritEnvOff =
        if inheritEnvOff then remote else remote ++ local


parseSecret :: String -> Either String Secret
parseSecret line =
  let
    (name, pathAndKey) = case findIndex (== '=') line of
      Just index -> cutAt index line
      Nothing -> ("", line)
  in do
    (path, key) <- case findIndex (== '#') pathAndKey of
      Just index -> Right (cutAt index pathAndKey)
      Nothing -> Left $ "Secret path '" ++ pathAndKey ++ "' does not contain '#' separator."
    let
      varName = if name == ""
        then varNameFromKey path key
        else name
    pure Secret { sPath = path
                , sKey = key
                , sVarName = varName
                }


readSecretList :: (MonadError VaultError m, MonadIO m) => FilePath -> m [Secret]
readSecretList fname = do
  mfile <- liftIO $ safeReadFile
  maybe (throwError $ IOError fname) parseSecrets mfile
  where
    parseSecrets file =
      let
        esecrets = traverse parseSecret . lines $ file
      in
        either (throwError . ParseError) return esecrets

    safeReadFile =
      Exception.catch (Just <$> readFile fname)
        ((\_ -> return Nothing) :: Exception.IOException -> IO (Maybe String))


runCommand :: Options -> [EnvVar] -> IO a
runCommand options env =
  let
    command = oCmd options
    searchPath = False
    args = oArgs options
    env' = Just env
  in
    -- `executeFile` calls one of the syscalls in the execv* family, which
    -- replaces the current process with `command`. It does not return.
    executeFile command searchPath args env'

-- | Request all the data associated with a secret from the vault.
requestSecret :: Options -> String -> IO (Either VaultError VaultData)
requestSecret opts secretPath =
  let
    requestPath = "/v1/secret/" <> secretPath
    request = setRequestHeader "x-vault-token" [SBS.pack (oVaultToken opts)]
            $ setRequestPath (SBS.pack requestPath)
            $ setRequestPort (oVaultPort opts)
            $ setRequestHost (SBS.pack (oVaultHost opts))
            $ setRequestSecure (not $ oConnectInsecure opts)
            $ defaultRequest

    shouldRetry = const $ return . isLeft
    retryAction _retryStatus = doRequest secretPath request
  in
    Retry.retrying vaultRetryPolicy shouldRetry retryAction

-- | Request all the supplied secrets from the vault, but just once, even if
-- multiple keys are specified for a single secret. This is an optimization in
-- order to avoid unnecessary round trips and DNS requets.
requestSecrets :: (MonadError VaultError m, Traversable t, MonadIO m)
               => Options -> t Secret -> m (t EnvVar)
requestSecrets opts secrets = do
  let secretPaths = Foldable.foldMap (\x -> Map.singleton x x) $ fmap sPath secrets
  esecretData <- liftIO $ Async.mapConcurrently (requestSecret opts) secretPaths
  either throwError return $ sequence esecretData >>= lookupSecrets secrets

-- | Look for the requested keys in the secret data that has been previously fetched.
lookupSecrets :: (Traversable t) => t Secret -> Map.Map String VaultData -> Either VaultError (t EnvVar)
lookupSecrets secrets vaultData = forM secrets $ \secret ->
  let secretData = Map.lookup (sPath secret) vaultData
      secretValue = secretData >>= Map.lookup (sKey secret)
      toEnvVar val = (sVarName secret, val)
  in maybe (Left $ KeyNotFound secret) (Right . toEnvVar) $ secretValue

-- | Send a request for secrets to the vault and parse the response.
doRequest :: String -> Request -> IO (Either VaultError VaultData)
doRequest secretPath request = do
  respOrEx <- Exception.try . httpLBS $ request :: IO (Either HttpException (Response LBS.ByteString))
  return $ Bifunctor.first exToErr respOrEx >>= parseResponse secretPath
  where
    exToErr :: HttpException -> VaultError
    exToErr e@(HttpExceptionRequest _ _) = ServerUnreachable e
    exToErr (InvalidUrlException _ _) = InvalidUrl secretPath

--
-- HTTP response handling
--

parseResponse :: String -> Response LBS.ByteString -> Either VaultError VaultData
parseResponse secretPath response =
  let
    responseBody = getResponseBody response
    statusCode = getResponseStatusCode response
  in case statusCode of
    200 -> Right $ parseSuccessResponse responseBody
    403 -> Left Forbidden
    404 -> Left $ SecretNotFound secretPath
    500 -> Left $ ServerError responseBody
    503 -> Left $ ServerUnavailable responseBody
    _   -> Left $ Unspecified statusCode responseBody


parseSuccessResponse :: LBS.ByteString -> VaultData
parseSuccessResponse responseBody =
  let
    getter = Lens.key "data" . reindexed Text.unpack Lens.members . Lens._String . to Text.unpack
  in
    Lens.toMapOf getter responseBody

--
-- Utility functions
--

vaultErrorLogMessage :: VaultError -> String
vaultErrorLogMessage vaultError =
  let
    description = case vaultError of
      (SecretNotFound secretPath) ->
        "Secret not found: " <> secretPath
      (IOError fp) ->
        "An I/O error happened while opening: " <> fp
      (ParseError fp) ->
        "File " <> fp <> " could not be parsed"
      (KeyNotFound secret) ->
        "Key " <> (sKey secret) <> " not found for path " <> (sPath secret)
      (DuplicateVar varName) ->
        "Found duplicate environment variable \"" ++ varName ++ "\""
      (BadRequest resp) ->
        "Made a bad request: " <> (LBS.unpack resp)
      (Forbidden) ->
        "Invalid Vault token"
      (InvalidUrl secretPath) ->
        "Secret " <> secretPath <> " contains characters that are illegal in URLs"
      (ServerError resp) ->
        "Internal Vault error: " <> (LBS.unpack resp)
      (ServerUnavailable resp) ->
        "Vault is unavailable for requests. It can be sealed, " <>
        "under maintenance or enduring heavy load: " <> (LBS.unpack resp)
      (ServerUnreachable exception) ->
        "ServerUnreachable error: " <> show exception
      (Unspecified status resp) ->
        "Received an error that I don't know about (" <> show status
        <> "): " <> (LBS.unpack resp)
  in
    "[ERROR] " <> description


-- | Convert a secret name into the name of the environment variable that it
-- will be available under.
varNameFromKey :: String -> String -> String
varNameFromKey path key = fmap format (path ++ "_" ++ key)
  where underscore '/' = '_'
        underscore '-' = '_'
        underscore c   = c
        format         = toUpper . underscore

-- | Like @splitAt@, but also removes the character at the split position.
cutAt :: Int -> [a] -> ([a], [a])
cutAt index xs =
  let
    (first, second) = splitAt index xs
  in
    (first, drop 1 second)
