{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Icicle.Test.Avalanche.Flatten where

import           Icicle.Core.Program.Check
import qualified Icicle.Core.Eval.Exp       as XV

import qualified Icicle.Avalanche.Program   as AP
import qualified Icicle.Avalanche.FromCore  as AC
import qualified Icicle.Avalanche.Eval      as AE
import qualified Icicle.Avalanche.Prim.Eval as AE
import qualified Icicle.Avalanche.Statement.Flatten   as AF

import           Icicle.Common.Base
import qualified Icicle.Common.Fresh                as Fresh

import           Icicle.Internal.Pretty

import qualified Icicle.Pipeline as P

import           Icicle.Test.Arbitrary
import           Icicle.Test.Core.Arbitrary

import           Data.Either.Combinators

import           P

import           System.IO

import           Test.QuickCheck
import           Test.QuickCheck.Property


-- We need a way to differentiate stream variables from scalars
namer = AC.namerText (flip Var 0)


-- Flattening - removing all folds keeps value same
zprop_flatten_commutes_value t =
 forAll (programForStreamType t)
 $ \p ->
 forAll (inputsForType t)
 $ \(vs,d) ->
    P.isRight     (checkProgram p) ==>
     let p' = AC.programFromCore namer p

         eval xp = AE.evalProgram xp d vs

         simp = Fresh.runFreshT
                        (AF.flatten () $ AP.statements p')
                        (Fresh.counterNameState (Name . Var "anf") 0)
     in case simp of
         Left e
          -> counterexample (show e)
           $ counterexample (show $ pretty p')
             False
         Right (_, s')
          -> counterexample (show $ pretty p')
           $ counterexample (show $ pretty s')
             (mapLeft show (eval XV.evalPrim p') === mapLeft show (eval AE.evalPrim p' { AP.statements = s'}))



prop_flatten_simp_commutes_value t =
 forAll (programForStreamType t)
 $ \p ->
 forAll (inputsForType t)
 $ \x@(_vs,_d) ->
   flatten_simp_commutes_value p x

--
-- This can be used to run a counterexample.
--
--   fprog  = the program to flatten
--   ffacts = the inputs for the program
--
--run_flatten_simp_commutes_value =
-- quickCheck (once (flatten_simp_commutes_value fprog ffacts))

flatten_simp_commutes_value p (vs, d) =
    P.isRight (checkProgram p) ==>
     let aval = P.coreAvalanche p
         flat = P.coreFlatten p
     in  case flat of
           Left _
            -> discard -- not well-typed avalanche
           Right flat'
            -> counterexample (show $ pretty aval)
            $  counterexample (show $ pretty flat')
               (eval XV.evalPrim aval `compareEvalResult` eval AE.evalPrim flat')
 where
  eval xp  = AE.evalProgram xp d vs
  compareEvalResult xv yv =
    let xv' = mapRight snd (mapLeft show xv)
        yv' = mapRight snd (mapLeft show yv)
    in either (counterexample . show . pretty) (const id) xv $
       either (counterexample . show . pretty) (const id) yv $
       if xv' == yv'
       then property succeeded
       else counterexample (show xv') $
            counterexample " /="      $
            counterexample (show yv') $
            property failed

return []
tests :: IO Bool
-- tests = $quickCheckAll
tests = $forAllProperties $ quickCheckWithResult (stdArgs {maxSuccess = 10000, maxSize = 10, maxDiscardRatio = 1000})
-- tests = $forAllProperties $ quickCheckWithResult (stdArgs {maxDiscardRatio = 10000})
-- Need a larger discard ratio sometimes

