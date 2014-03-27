-- ------------------------------------------------------ --
-- Copyright © 2012, 2014 AlephCloud Systems, Inc.
-- ------------------------------------------------------ --

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

-- | A minimal ccs client context. This context only provides
-- means for low-level connections to the CCS.
--
module AlephCloud.Logging.Class
(
  LogLevel(..)
, Logger
, LogLabels
, MonadLog(..)
, liftOp_
, loggE
) where

import AlephCloud.Logging.Configuration
import AlephCloud.Logging.Internal

import Control.Monad.Trans.Class
import Control.Monad.Trans.Control
import Control.Monad.List
import Control.Monad.Reader
import Control.Monad.State
import qualified Control.Monad.State.Strict as Strict
import Control.Monad.Error
import Control.Monad.Writer
import qualified Control.Monad.Writer.Strict as Strict
import Control.Monad.RWS
import qualified Control.Monad.RWS.Strict as Strict

import Data.Monoid.Unicode ((⊕))
import Data.Text (Text)

type Logger = LogLevel → Text → IO ()

class Monad λ ⇒ MonadLog λ where

    -- Write a log message
    logg ∷ LogLevel → Text → λ ()

    -- Locally open a sub-log (by appending a new label)
    subLog ∷ Text → λ α → λ α

    -- Locally set log labels
    withLogLabel ∷ LogLabels → λ α → λ α

    -- Locally set log level
    withLogLevel ∷ LogLevel → λ α → λ α

    -- Locally set log level and log labels
    withLogger ∷ LogLevel → LogLabels → λ α → λ α
    withLogger level labels = withLogLevel level . withLogLabel labels

loggE ∷ (MonadLog μ, Show ε) ⇒ LogLevel → Text → Either ε α → μ (Either ε α)
loggE level pref = either
    (\e → logg level (pref ⊕ " - " ⊕ tshow e) >> return (Left e))
    (return . Right)

-- -------------------------------------------------------------------------- --
-- Standard transformer instances

instance (MonadLog μ) ⇒ MonadLog (ListT μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (MonadLog μ) ⇒ MonadLog (ReaderT γ μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (MonadLog μ) ⇒ MonadLog (StateT σ μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (MonadLog μ) ⇒ MonadLog (Strict.StateT σ μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (Error ε, MonadLog μ) ⇒ MonadLog (ErrorT ε μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (Monoid ω, MonadLog μ) ⇒ MonadLog (WriterT ω μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (Monoid ω, MonadLog μ) ⇒ MonadLog (Strict.WriterT ω μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (Monoid ω, MonadLog μ) ⇒ MonadLog (RWST ρ ω σ μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

instance (Monoid ω, MonadLog μ) ⇒ MonadLog (Strict.RWST ρ ω σ μ) where
    logg level = lift . logg level
    subLog label = liftOp_ (subLog label)
    withLogLabel labels = liftOp_ (withLogLabel labels)
    withLogLevel level = liftOp_ (withLogLevel level)
    withLogger level labels = liftOp_ (withLogger level labels)

-- -------------------------------------------------------------------------- --
-- Utils for propagating MonadLog through a transformer stack

controlT ∷ (Monad μ, Monad (τ μ), MonadTransControl τ)
         ⇒ (Run τ → μ (StT τ β))
         → τ μ β
controlT f = liftWith f >>= restoreT . return

liftOp_ ∷ (Monad ν, Monad (τ μ), Monad μ, MonadTransControl τ)
        ⇒ (ν (StT τ b1)
        → μ (StT τ β))
        → τ ν b1
        → τ μ β
liftOp_ f = \m → controlT $ \runInBase → f $ runInBase m
