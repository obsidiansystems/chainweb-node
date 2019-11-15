{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
-- |
-- Module: Chainweb.Pact.Types
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Pact Types module for Chainweb
--
module Chainweb.Pact.Types
  ( PactDbStatePersist(..)
  , Transactions(..)
  , toCoinbaseOutput, fromCoinbaseOutput
  , GasSupply(..)
  , GasId(..)
  , PactServiceEnv(..)
  , PactServiceState(..)
  , EnforceCoinbaseFailure(..)

    -- * Transaction State
  , TransactionState(..)
  , transactionGasEnv
  , transactionLogs
  , transactionCache

    -- * Transaction Env
  , TransactionEnv(..)
  , txEntity
  , txMode
  , txDbEnv
  , txLogger
  , txPublicData
  , txSpvSupport
  , txNetworkId

    -- * Transaction Execution Monad
  , TransactionM(..)
  , runTransactionM
  , runTransactionM_
  , execTransactionM
  , evalTransactionM

    -- * types
  , ModuleCache
  , HashCommandResult
    -- * optics
  , pdbspRestoreFile
  , pdbspPactDbState
    -- * defaults
  , emptyPayload
  , noCoinbase
    -- * module exports
  , module Chainweb.Pact.Backend.Types
  ) where

import Control.Lens hiding ((.=))
import Control.Monad.Catch
import Control.Monad.Fail
import Control.Monad.Reader
import Control.Monad.State.Strict


import Data.Aeson
import Data.Default
import Data.HashMap.Strict
import Data.Tuple.Strict
import Data.Vector (Vector)

-- internal pact modules

import Pact.Gas
import Pact.Interpreter (PactDbEnv)
import Pact.Parse (ParsedDecimal)
import Pact.Types.Command
import Pact.Types.Exp
import Pact.Types.Gas
import qualified Pact.Types.Hash as H
import Pact.Types.Logger
import Pact.Types.PactValue
import Pact.Types.Persistence
import Pact.Types.Runtime
import Pact.Types.SPV
import Pact.Types.Term (ModuleName, PactId(..), Ref)

-- internal chainweb modules

import Chainweb.Miner.Pact
import Chainweb.Pact.Backend.Types
import Chainweb.Payload
import Chainweb.Utils


type HashCommandResult = CommandResult H.Hash

type ModuleCache = HashMap ModuleName (ModuleData Ref, Bool)

data Transactions = Transactions
    { _transactionPairs :: !(Vector (Transaction, HashCommandResult))
    , _transactionCoinbase :: !HashCommandResult
    } deriving (Eq, Show)


emptyPayload :: PayloadWithOutputs
emptyPayload = PayloadWithOutputs mempty miner coinbase h i o
  where
    (BlockPayload h i o) = newBlockPayload miner coinbase mempty
    miner = MinerData $ encodeToByteString noMiner
    coinbase = toCoinbaseOutput noCoinbase

noCoinbase :: CommandResult a
noCoinbase = CommandResult (RequestKey H.pactInitialHash) Nothing
             (PactResult (Right (PLiteral (LString "NO_COINBASE"))))
             0 Nothing Nothing Nothing

toCoinbaseOutput :: HashCommandResult -> CoinbaseOutput
toCoinbaseOutput = CoinbaseOutput . encodeToByteString

fromCoinbaseOutput :: MonadThrow m => CoinbaseOutput -> m HashCommandResult
fromCoinbaseOutput = decodeStrictOrThrow' . _coinbaseOutput

data PactDbStatePersist = PactDbStatePersist
    { _pdbspRestoreFile :: !(Maybe FilePath)
    , _pdbspPactDbState :: !PactDbState
    }
makeLenses ''PactDbStatePersist

-- | Indicates a computed gas charge (gas amount * gas price)
newtype GasSupply = GasSupply { _gasSupply :: ParsedDecimal }
   deriving (Eq,Ord,Num,Real,Fractional,ToJSON,FromJSON)
instance Show GasSupply where show (GasSupply g) = show g

newtype GasId = GasId PactId deriving (Eq, Show)

-- | Whether to ignore coinbase failures, or "enforce" (fail block)
-- Backward-compat fix is to enforce in new block, but ignore in validate.
--
newtype EnforceCoinbaseFailure = EnforceCoinbaseFailure Bool

-- | Transaction execution state
--
data TransactionState = TransactionState
    { _transactionGasEnv :: GasEnv
    , _transactionCache :: ModuleCache
    , _transactionLogs :: [TxLog Value]
    }

makeLenses ''TransactionState

instance Default TransactionState where
    def = TransactionState freeGasEnv mempty mempty

-- | Transaction execution env
--
data TransactionEnv db = TransactionEnv
    { _txEntity :: !(Maybe EntityName)
    , _txMode :: !ExecutionMode
    , _txDbEnv :: PactDbEnv db
    , _txLogger :: !Logger
    , _txPublicData :: !PublicData
    , _txSpvSupport :: !SPVSupport
    , _txNetworkId :: !(Maybe NetworkId)
    }
makeLenses ''TransactionEnv

-- | The transaction monad used in transaction execute. The reader
-- environment is the a Pact command env, writer is a list of json-ified
-- tx logs, and transaction state consists of a module cache, gas env,
-- and log values.
--
newtype TransactionM db a = TransactionM
    { _runTransactionM
        :: ReaderT (TransactionEnv db) (StateT TransactionState IO) a
    } deriving
      ( Functor, Applicative, Monad
      , MonadReader (TransactionEnv db)
      , MonadState TransactionState
      , MonadThrow, MonadCatch, MonadMask
      , MonadIO
      , MonadFail
      )

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, returning the full range of
-- results
--
runTransactionM
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
      -- ^ computation to execute
    -> IO (a, TransactionState)
runTransactionM tenv txst act
    = runStateT (runReaderT (_runTransactionM act) tenv) txst

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, returning the full range of
-- results in a strict tuple
--
runTransactionM_
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
      -- ^ computation to execute
    -> IO (T2 a TransactionState)
runTransactionM_ tenv txst act
    = view (from _T2)
    <$> runStateT (runReaderT (_runTransactionM act) tenv) txst

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, discarding the final state.
--
evalTransactionM
    :: forall db a
    . TransactionEnv db
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM db a
    -> IO a
evalTransactionM tenv txst act
    = evalStateT (runReaderT (_runTransactionM act) tenv) txst

-- | Run a 'TransactionM' computation given some initial
-- reader and state values, discarding the final value.
--
execTransactionM
    :: forall p a
    . TransactionEnv p
      -- ^ initial reader env
    -> TransactionState
      -- ^ initial state
    -> TransactionM p a
      -- ^ computation to execute
    -> IO TransactionState
execTransactionM tenv txst act
    = execStateT (runReaderT (_runTransactionM act) tenv) txst
