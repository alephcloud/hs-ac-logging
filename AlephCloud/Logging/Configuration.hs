{-# LANGUAGE DeriveDataTypeable #-}
module AlephCloud.Logging.Configuration
  (LogBackend(..),
   LogConfiguration(..),
   LogLabels,
   LogLevel(..),
   SyslogServiceName)
  where

import qualified Data.ByteString as ByteString
import Data.Data
import qualified Data.Text as Text


type Port = Int
type Hostname = ByteString.ByteString

-- -------------------------------------------------------------------------- --
-- Log Configuration

type LogLabels = [Text.Text]

type SyslogServiceName = String

data LogLevel = None
              | Warn
              | Request
              | Info
              | Body
              | Debug
    deriving (Show, Eq, Ord, Enum, Typeable, Data, Read)

data LogBackend
    = LogSyslogUdp SyslogServiceName Hostname Port
    -- ^ Sent log message to a syslog daemon over UDP
    | LogSyslog SyslogServiceName
    -- ^ On POSIX systems write log messages to system syslog daemon using syslog (3)
    | LogFile FilePath (Maybe (Int, Int))
    -- ^ Append log messages to the given file. Maybe (max_file_size_in_bytes, number_of_files_for_rotation)
    | LogStdout
    -- ^ Write log message to stdout
    | LogStderr
    -- ^ Write log messages to stderr
    deriving (Show, Eq, Typeable, Data)

data LogConfiguration = LogConfiguration
    { logBackend :: LogBackend
    -- ^ The logger backend
    , logLevel :: LogLevel
    -- ^ The severity threshold for which logs are generated
    , logLabels :: LogLabels
    -- ^ Optional list of labels that are prepended to the labels in the log messages
    } deriving (Show, Eq, Typeable)
