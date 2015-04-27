{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Core.Stream.Check (
      checkStream
    , StreamEnv (..)
    , emptyEnv
    ) where

import              Icicle.Core.Type
import              Icicle.Core.Exp

import              Icicle.Core.Stream.Stream
import              Icicle.Core.Stream.Error

import              P

import qualified    Data.Map as Map
import              Data.Either.Combinators


data StreamEnv n =
 StreamEnv
 { pres     :: Env n Type
 , streams  :: Env n ValType
 , concrete :: ValType
 }

emptyEnv :: Env n Type -> ValType -> StreamEnv n
emptyEnv pre conc
 = StreamEnv pre Map.empty conc


checkStream
        :: Ord n
        => StreamEnv n -> Stream n
        -> Either (StreamError n) ValType
checkStream se s
 = case s of
    Source
     -> return (concrete se)
    STrans st f n
     -> do  inp <- lookupOrDie StreamErrorVarNotInEnv (streams se) n
            fty <- mapLeft     StreamErrorExp $ checkExp (pres se) f

            requireSame (StreamErrorTypeError f)
                        (funOfVal $ inputOfStreamTransform st) (funOfVal inp)
            requireSame (StreamErrorTypeError f)
                        (typeOfStreamTransform st)              fty

            return (outputOfStreamTransform st)

