{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Sea.Seaworthy where

import           Icicle.Data
import           Icicle.Internal.Pretty

import qualified Icicle.Core.Program.Check          as C

import qualified Icicle.Sea.Eval                    as S

import qualified Icicle.Avalanche.Check             as AC
import qualified Icicle.Avalanche.FromCore          as A
import qualified Icicle.Avalanche.Prim.Flat         as APF
import qualified Icicle.Avalanche.Program           as AP
import qualified Icicle.Avalanche.Statement.Flatten as AF
import qualified Icicle.Avalanche.Simp      as AS

import           Icicle.Common.Base
import           Icicle.Common.Type
import           Icicle.Common.Annot
import qualified Icicle.Common.Fresh                as Fresh

import           Icicle.Test.Core.Arbitrary

import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Either
import qualified Data.Map                           as Map

import           P

import           System.IO

import           Test.QuickCheck
import           Test.QuickCheck.Monadic


namer = A.namerText (flip Var 0)

-- | Any Icicle Core program is convertible to C.
prop_seaworthy t
 = monadicIO
 $ forAllM (programForStreamType t)
 $ \coreProgram
 -> do pre $ isRight (C.checkProgram coreProgram)
       let avalProgram  = A.programFromCore namer coreProgram
           flatStmts    = Fresh.runFreshT (AF.flatten () $ AP.statements avalProgram) counter
           flatProgram  = fmap ( AC.checkProgram APF.flatFragment
                               . replaceStmts avalProgram
                               . snd) flatStmts
           meltProgram  = fmap (fmap simp) flatProgram
       case meltProgram of
         Right (Right f)
          -> do let attr         = Attribute "eval"
                let seaProgram   = Map.singleton attr f
                fleet           <- lift $ runEitherT $ S.seaCompile seaProgram
                stop $ case fleet of
                 Right _
                  -> property True
                 Left err
                  -> counterexample (show $ pretty err)
                  $  counterexample (show $ pretty coreProgram)
                     False
         Left _
          -> discard -- not well typed flattened avalanche
         Right (Left _)
          -> discard -- not well typed avalanche
 where
  replaceStmts prog stms
   = prog { AP.statements = stms }
  simp p
   = snd $ Fresh.runFresh (AS.simpFlattened dummyAnn p) counter'
  dummyAnn = Annot (FunT [] ErrorT) ()
  counter  = Fresh.counterNameState (Name . Var "anf") 0
  counter' = Fresh.counterNameState (Name . Var "simp") 0

return []
tests :: IO Bool
tests = $quickCheckAll
-- tests = $forAllProperties $ quickCheckWithResult (stdArgs {maxSuccess = 1000, maxSize = 10, maxDiscardRatio = 10000})