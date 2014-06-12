-- ------------------------------------------------------ --
-- Copyright © 2012, 2013, 2014 AlephCloud Systems, Inc.
-- ------------------------------------------------------ --

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE UndecidableInstances #-} -- MonadBaseControl β (LoggerT μ)

#define POSIX_HOST_OS darwin_HOST_OS==1 || linux_HOST_OS==1

module AlephCloud.Logging
(
  logToHandle
, logRequest
, logErrResult
, logRequestBody
, withLogFile
, LogLabels
, LogMessage
, LoggerCtx (loggerLevel, loggerLabels)
, withFileLoggerCtx
, withHandleLoggerCtx
, withLoggerCtx
, runLoggerT
, LoggerT
, logIO
, subLogCtx
) where

import AlephCloud.Logging.Class
import qualified AlephCloud.Logging.Configuration as Conf
import AlephCloud.Logging.Internal

import Blaze.ByteString.Builder (toByteString)

import Control.Applicative (Applicative, (<$>), (<*>), (<|>))
import Control.Concurrent.Async.Lifted (withAsync, cancel)
import Control.Concurrent
import qualified Control.Concurrent.BoundedChan as BC
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TBQueue
import Control.Exception (IOException, bracket, throw)
import Control.Exception.Lifted(catch)
import Control.Monad.Trans
import Control.Monad.Reader.Class
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Error
import Control.Monad.State
import Control.Monad.Trans.Control
import Control.Monad.Base

import qualified Data.ByteString.Char8 as B8
import Data.Conduit (Flush(..), ($$))
import qualified Data.Conduit.List as C (consume, sourceList)
import Data.Default (def)
import Data.Maybe
import Data.Monoid.Unicode ((⊕))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.Time (getCurrentTime, UTCTime)  -- (getZonedTime, ZonedTime)

import qualified Network.HTTP.Types.Status as HTTP
import qualified Network.Wai as WAI (responseStatus, Request(..), responseSource, responseToSource, Middleware)
import Network.Wai.Middleware.RequestLogger (mkRequestLogger, Destination(..), destination, OutputFormat(..), outputFormat, IPAddrSource(..))

import Prelude.Unicode

import Safe

import System.Directory
import System.IO (Handle, stdout, stderr, IOMode(AppendMode), openFile, hClose, hFileSize, hFlush)
import System.IO.Unsafe

#if POSIX_HOST_OS
import qualified System.Posix.Syslog as Syslog
#endif

logMessageQueueSize ∷ Int
logMessageQueueSize = 32768

-- -------------------------------------------------------------------------- --
-- Wai Logger

logToHandle ∷ Handle → WAI.Middleware
logToHandle h = unsafePerformIO $ mkRequestLogger def { outputFormat = Apache FromSocket, destination = Handle h }

-- | This logs requests and the HTTP status of the result
--
logRequest
    ∷ LoggerCtx
    → LogLevel
    → WAI.Middleware
logRequest ctx level app req
    | loggerLevel ctx < level = app req
    | otherwise = do
        logIO ctx level $! "|"
                        ⊕ T.decodeUtf8 (WAI.requestMethod req) ⊕ " "
                        ⊕ T.decodeUtf8 (WAI.rawPathInfo req)
                        ⊕ T.decodeUtf8 (WAI.rawQueryString req)
        response ← app req
        logIO ctx level $! "|" ⊕ tshowStatus (WAI.responseStatus response)
        return response

-- | This logs responses with all 4** and 5** status codes. In order to
-- due so it must consume the response from the pipe and reinject it into
-- the pipe. This is expensive, but happens only for response with the
-- status respective.
--
logErrResult ∷ LoggerCtx → LogLevel → WAI.Middleware
logErrResult ctx level app req
    | loggerLevel ctx < level = app req
    | otherwise = do
        response ← app req
        let (stat, hdrs, src) = WAI.responseToSource response
        if HTTP.statusIsClientError stat ∨ HTTP.statusIsServerError stat
            then do
                res' ← src ($$ C.consume)
                let msg = hideSecrets ∘ T.concat ∘ map (T.decodeUtf8 ∘ unflush) $ res'
                logIO ctx level $! "Result [" ⊕ tshowStatus stat ⊕ "]: " ⊕ msg
                return $ WAI.responseSource stat hdrs (C.sourceList res')
            else return response
    where
    unflush Flush = ""
    unflush (Chunk a) = toByteString a

-- | This is expensive, since it consumes all requests from the stream
-- and reinjects them back into the stream. Use this only in Debugging
-- mode!
--
logRequestBody ∷ LoggerCtx → LogLevel → WAI.Middleware
logRequestBody ctx level app req
    | loggerLevel ctx < level = app req
    | otherwise = do
        when (level < Body) $ logIO ctx Warn warning
        body' ← (WAI.requestBody req) $$ C.consume
        let msg = hideSecrets ∘ T.concat ∘ map T.decodeUtf8 $ body'
        logIO ctx level $! "|"
                        ⊕ T.decodeUtf8 (WAI.requestMethod req) ⊕ " "
                        ⊕ T.decodeUtf8 (WAI.rawPathInfo req)
                        ⊕ T.decodeUtf8 (WAI.rawQueryString req) ⊕ "| "
                        ⊕ msg
        app req { WAI.requestBody = C.sourceList body' }
    where
    warning = "Logging all request bodies is expensive. Using the request logger with an log-level other than body is strongly discouraged."

-- -------------------------------------------------------------------------- --
-- Logger Backend

class LogQueueC α where
    newLogQueue ∷ (Functor μ, Applicative μ, MonadIO μ) ⇒ Int → μ α
    popLogQueue ∷ (Functor μ, Applicative μ, MonadIO μ) ⇒ α → μ LogMessage
    pushLogQueue ∷ (Functor μ, Applicative μ, MonadIO μ) ⇒ α → LogMessage → μ ()
    isEmptyLogQueue ∷ (Functor μ, Applicative μ, MonadIO μ) ⇒ α → μ Bool

instance LogQueueC (TBQueue LogMessage) where
    newLogQueue = liftIO ∘ newTBQueueIO
    popLogQueue = liftIO ∘ atomically ∘ readTBQueue
    pushLogQueue queue msg@LogMessage{..} = liftIO $ do
        result ← atomically $ Just <$> writeTBQueue queue msg <|> return Nothing
        when (isNothing result) $ do
            T.hPutStrLn stderr ∘ formatMessage $! fullQueueWarning logTime
            -- We put the following into separate transaction, because we care more
            -- about submitting the warning than atomicity.
            atomically $ writeTBQueue queue $! fullQueueWarning logTime
            atomically $ writeTBQueue queue $! msg
      where
        fullQueueWarning now = LogMessage now ["Logger Backend"] Warn
            "Task blocked on full logger backend queue. Something is wrong. Maybe you are using loglevel \"debug\" or \"body\" for production?"
    isEmptyLogQueue queue = liftIO $ do
        maybeResult ← atomically $ tryPeekTBQueue queue
        case maybeResult of
            Nothing → return True
            Just _ → return False

instance LogQueueC (BC.BoundedChan LogMessage) where
    newLogQueue = liftIO ∘ BC.newBoundedChan
    popLogQueue = liftIO ∘ BC.readChan
    pushLogQueue q = liftIO ∘ BC.writeChan q
    isEmptyLogQueue = liftIO ∘ BC.isEmptyChan

data FairTBQueue α = FairTBQueue
    { fairTBQueueQueue ∷ !(TBQueue α)
    , fairTBQueueLock ∷ !(MVar ())
    }

instance LogQueueC (FairTBQueue LogMessage) where
    newLogQueue i = FairTBQueue <$> newLogQueue i <*> (liftIO $ newMVar ())
    popLogQueue = popLogQueue ∘ fairTBQueueQueue
    pushLogQueue FairTBQueue{..} !msg = liftIO $ do
        withMVar fairTBQueueLock $ \_ → do
            pushLogQueue fairTBQueueQueue msg
    isEmptyLogQueue FairTBQueue{..} = liftIO $ isEmptyLogQueue fairTBQueueQueue

flushLogQueue ∷ (Functor μ, Applicative μ, MonadIO μ, LogQueueC α) ⇒ α → μ ()
flushLogQueue queue = do
    isEmpty ← isEmptyLogQueue queue
    if isEmpty
      then return ()
      else do
        liftIO $ threadDelay 100000
        flushLogQueue queue

-- FIXME
--
-- * Using a queue is not optimal. Instead we would like to see the log
--   promptly and directly being written to the backend.
--
-- * Make sure that the program never blocks due to slow logging.
--
-- * Instead of a concret TBQueue the Backend should provide an abstract
--   interface.

data LogMessage = LogMessage
    { logTime ∷ !UTCTime  -- ZonedTime
    , logLabels ∷ !LogLabels
    , logLevel ∷ !LogLevel
    , logMessage ∷ !T.Text
    } deriving (Show)

-- FIXME introduce log rotation (we should use openFile instead)
--
withLogFile ∷ (Functor μ, Applicative μ, MonadIO μ, MonadBaseControl IO μ) ⇒ Maybe FilePath → (Handle → μ α) → μ α
withLogFile file = case file of
    Nothing → ($ stdout)
    Just f → liftBaseOp (bracket (openFile f AppendMode) hClose)

withFileLoggerCtx ∷ (MonadIO μ, MonadBaseControl IO μ) ⇒ LogLabels → LogLevel → Maybe FilePath → Maybe (Int, Int) → (LoggerCtx → μ α) → μ α
withFileLoggerCtx labels level file rotateOptions act = case (file, rotateOptions) of
    (Just f, Just (sz, num)) → cont (RotateFile f sz num)
    (Just f, Nothing) → liftBaseOp (bracket (openFile f AppendMode) hClose) $ cont ∘ RegularHandle
    (Nothing, _) → cont (RegularHandle stdout)
    where
    cont h = withMyHandleLoggerCtx labels level h act


withHandleLoggerCtx ∷ (MonadIO μ, MonadBaseControl IO μ) ⇒ LogLabels → LogLevel → Handle → (LoggerCtx → μ α) → μ α
withHandleLoggerCtx labels level = withMyHandleLoggerCtx labels level ∘ RegularHandle

-- runBackend will be spawned once when service using this logger starts, and will run in the background available to all the threads that the service might spin up.
-- See Service.hs (function service) and ccs.hs.
withMyHandleLoggerCtx ∷ (MonadIO μ, MonadBaseControl IO μ) ⇒ LogLabels → LogLevel → MyHandle → (LoggerCtx → μ α) → μ α
withMyHandleLoggerCtx labels level myHandle act = do
    logQueue ← newLogQueue logMessageQueueSize
    let ctx = LoggerCtx logQueue level labels
    -- withAsync cancels the async for us on termination or error.
    withAsync (runBackend myHandle (loggerLevel ctx) logQueue) $ \backend → do
        r ← act ctx
        flushLogQueue logQueue
        cancel backend
        return r
    where
    runBackend h _ctxLevel logQueue = liftIO $ case h of
        (RegularHandle handle) → forever $ getMsg handle
        (RotateFile f size numFiles) → myLoop (map show [0 .. numFiles])
            where
            myLoop suffixes = do
                let suffix = fromMaybe "" $ headMay suffixes
                    suffixes' | null suffixes = []
                              | otherwise = drop 1 suffixes ++ [suffix]
                liftBaseOp (bracket (openFile f AppendMode) hClose) (\handle → hFileSize handle >>= \n → go suffix (fromInteger n) handle)  -- (go suffix 0)
                myLoop suffixes'
            go suffix n handle = do
                msgOut ← getMsg handle
                let n' = n + B8.length msgOut + 1  -- + 1 for the newline
                if n' >= size
                    then hClose handle >> renameFile f (f ++ suffix)
                    else go suffix n' handle
        where
        getMsg handle = do
            msg ← popLogQueue logQueue
            let msgOut = T.encodeUtf8 $ formatMessage msg
            B8.hPutStrLn handle msgOut
            hFlush handle
            return msgOut

data MyHandle = RegularHandle Handle
              | RotateFile FilePath Int Int -- ^ file name, max log file size, number of old files
{-

[0,1,2] file --> rename file file0 --> open file --> [1,2,0] file --> rename file file1 --> open file
file, file0 file

-}

#if POSIX_HOST_OS
withSyslogLoggerCtx
    ∷ (MonadIO μ, MonadBaseControl IO μ)
    ⇒ Conf.SyslogServiceName
    -- ^ name of the service that is used with syslog
    → LogLabels
    -- ^ list of initial labels for the 'LoggerCtx'
    → LogLevel
    -- ^ the initial logging threshold for the 'LoggerCtx'
    → (LoggerCtx → μ α)
    → μ α
withSyslogLoggerCtx serviceName labels level act = do
    logQueue ← newLogQueue logMessageQueueSize
    let ctx = LoggerCtx logQueue level labels
    -- withAsync cancels the async for us on termination or error.
    withAsync (runBackend (loggerLevel ctx) logQueue) $ \backend → do
        r ← act ctx
        flushLogQueue logQueue
        cancel backend
        return r
    where
    -- FIXME catch exceptions and restart log backend
    runBackend _ctxLevel logQueue = liftIO ∘ Syslog.withSyslog serviceName [] Syslog.USER $
        forever $ do
            msg ← popLogQueue logQueue
            Syslog.syslog (level2Priority (logLevel msg)) $ T.unpack (formatMessage msg)
    level2Priority l = case l of
        None → Syslog.Emergency
        Warn → Syslog.Error
        Request → Syslog.Notice
        Info → Syslog.Info
        Body → Syslog.Debug
        Debug → Syslog.Debug

#endif

formatMessage
    ∷ LogMessage
    → T.Text
formatMessage LogMessage{..} =
    tshow logTime
    ⊕ " [" ⊕ tshow logLevel ⊕ "] [" ⊕ T.intercalate "|" logLabels ⊕ "] "
    ⊕ hideSecrets logMessage

withLoggerCtx
    ∷ (MonadIO μ, MonadBaseControl IO μ)
    ⇒ Conf.LogConfiguration
    -- ^ logging configuration
    → LogLabels
    -- ^ extra labels that will be append to the labels defined in the configuration
    → (LoggerCtx → μ α)
    → μ α
withLoggerCtx Conf.LogConfiguration{..} extraLabels action = do
  let labels = logLabels ⊕ extraLabels

      go preActMay = case logBackend of
#if POSIX_HOST_OS
                 Conf.LogSyslog serviceName → withSyslogLoggerCtx serviceName labels logLevel act
#else
                 Conf.LogSyslog _ → error "Log backend \"Syslog\" is not supported on this operating system."
#endif
                 Conf.LogSyslogUdp _serviceName _host _port → error "Syslog via UDP is not yet implemented"
                 Conf.LogFile path rotateOptions → withFileLoggerCtx labels logLevel (Just path) rotateOptions act
                 Conf.LogStdout → withHandleLoggerCtx labels logLevel stdout act
                 Conf.LogStderr → withHandleLoggerCtx labels logLevel stderr act
               `catch` \(e ∷ IOException) → do
                   liftIO $ T.hPutStrLn stderr $ "withLoggerCtx failed with error: " ⊕ tshow e
                   throw e
        where act = maybe action (\preAct ctx → preAct ctx >> action ctx) preActMay
  go Nothing


logIO ∷ (MonadIO μ) ⇒ LoggerCtx → LogLevel → T.Text → μ ()
logIO LoggerCtx{..} level msg = liftIO $
    when (loggerLevel ≥ level) $ do
        now ← getCurrentTime  -- getZonedTime
        postLog loggerQueue $! LogMessage now loggerLabels level msg

postLog ∷ LogQueue → LogMessage → IO ()
postLog queue msg = pushLogQueue queue $! msg

-- -------------------------------------------------------------------------- --
-- Logger

type LogQueue = FairTBQueue LogMessage
-- type LogQueue = TBQueue LogMessage
-- type LogQueue = BC.BoundedChan LogMessage

data LoggerCtx = LoggerCtx
    { loggerQueue ∷ !LogQueue
    , loggerLevel ∷ !LogLevel
    , loggerLabels ∷ !LogLabels
    }

subLogCtx ∷ T.Text → LoggerCtx → LoggerCtx
subLogCtx label ctx = ctx { loggerLabels = loggerLabels ctx ⊕ [label] }

newtype LoggerT μ α = LoggerT { unLoggerT ∷ ReaderT LoggerCtx μ α  }
    deriving (Applicative, Functor, Monad, MonadIO, (MonadReader LoggerCtx), MonadTrans)

runLoggerT ∷ LoggerCtx → LoggerT μ α → μ α
runLoggerT ctx = (flip runReaderT) ctx ∘ unLoggerT

-- Standard Transformer instances
deriving instance MonadWriter α μ ⇒ MonadWriter α (LoggerT μ)
deriving instance MonadState α μ ⇒ MonadState α (LoggerT μ)
deriving instance MonadError α μ ⇒ MonadError α (LoggerT μ)

-- Monad Control Instances
deriving instance MonadBase β μ ⇒ MonadBase β (LoggerT μ)

instance MonadTransControl LoggerT where
    newtype StT LoggerT a = StLoggerT {unStLoggerT ∷ StT (ReaderT LoggerCtx) a}
    liftWith = defaultLiftWith LoggerT unLoggerT StLoggerT
    restoreT = defaultRestoreT LoggerT unStLoggerT

instance (MonadBase IO μ, MonadBaseControl IO μ) ⇒ MonadBaseControl IO (LoggerT μ) where
     newtype StM (LoggerT μ) α = StMT {unStMT ∷ ComposeSt LoggerT μ α}
     liftBaseWith = defaultLiftBaseWith StMT
     restoreM     = defaultRestoreM   unStMT

instance (MonadIO μ) ⇒ MonadLog (LoggerT μ) where

    logg level msg = do
        LoggerCtx{..} ← ask
        when (loggerLevel ≥ level) ∘ liftIO $ do
            now ← getCurrentTime  -- getZonedTime
            postLog loggerQueue $ LogMessage now loggerLabels level msg

    subLog label = local (subLogCtx label)

    withLogLevel level = local $ \ctx → ctx { loggerLevel = level }

    withLogLabel labels = local $ \ctx → ctx { loggerLabels = labels }
