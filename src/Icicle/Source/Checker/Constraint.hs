-- | Generate type constraints
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DoAndIfThenElse #-}
module Icicle.Source.Checker.Constraint (
    constraintsQ
  , generateQ
  , generateX
  , defaults
  ) where

import                  Icicle.Source.Checker.Base
import                  Icicle.Source.Checker.Error
import                  Icicle.Source.Checker.Prim

import                  Icicle.Source.Query
import                  Icicle.Source.Type

import                  Icicle.Common.Base
import qualified        Icicle.Common.Fresh     as Fresh

import                  P

import                  Control.Monad.Trans.Either

import                  Data.List (zip,unzip,unzip3)
import qualified        Data.Map                as Map



-- | Defaulting any polymorphic Nums to Ints.
-- For example, if the query has
-- > feature salary ~> 1
-- this actually has type "forall a. Num a => a"
-- and we could safely use any number type.
--
-- We should really also default anything else to unit.
-- However, because defaulting only applies to the query, where the input stream must be concrete,
-- there should be no type variables left at the end except Nums.
defaults :: Ord n
         => Query'C a n
         -> Query'C a n
defaults q
 -- Find all Num constraints and map them to Int
 = let cm = Map.fromList
          $ concatMap (defaultOfConstraint . snd)
          $ annConstraints
          $ annotOfQuery q
   -- Just substitute the type vars in
   in substTQ cm q
 where
  defaultOfConstraint (CIsNum t)
   -- It must be a type variable - if it isn't it either already has a concrete
   -- Num type such as Int, or it is a type error
   | TypeVar n <- t
   = [(n, IntT)]
   | otherwise
   = []
  -- Everything else should really be known by this stage.
  -- These shouldn't actually occur.
  defaultOfConstraint (CEquals _ _)
   = []
  defaultOfConstraint (CReturnOfLetTemporalities _ _ _)
   = []
  defaultOfConstraint (CReturnOfLatest _ _ _)
   = []
  defaultOfConstraint (CPossibilityJoin _ _ _)
   = []
  defaultOfConstraint (CTemporalityJoin _ _ _)
   = []
  defaultOfConstraint (CExtractTemporality _ _ _)
   = []



-- | Generate constraints for an entire query.
--   We take the map of types of all imported functions.
constraintsQ
  :: Ord n
  => Map.Map (Name n) (FunctionType n)
  -> Query a n
  -> EitherT (CheckError a n) (Fresh.Fresh n) (Query'C a n)
constraintsQ env q
 = do (x, _, cons) <- evalGen (generateQ q env) []
      -- We must have been able to solve all constraints except numeric requirements.
      if   all (isNumConstraint . snd) cons
      then right x
      else hoistEither
            $ errorNoSuggestions
            $ ErrorConstraintLeftover
               (annotOfQuery q)
               (filter (not . isNumConstraint . snd) cons)
 where
  isNumConstraint (CIsNum _) = True
  isNumConstraint _          = False


-- | Generate constraints for top-level query.
-- The Gen monad stack has a fresh name supply, as well as the state of
-- constraints and environment mapping from name to type.
--
-- The constraints flow upwards, bottom-up, but are also discharged and simplified at every level.
-- The substitutions from discharged constraints also flow upwards.
--
-- The environment mapping flows downwards, with new names only available in lexically
-- nested subexpressions and so on.
--
generateQ
  :: Ord n
  => Query a n
  -> GenEnv n
  -> GenConstraintSet a n
  -> Gen a n (Query'C a n, SubstT n, GenConstraintSet a n)

-- End of query - at this stage it is just an expression with no contexts.
generateQ (Query [] x) env cons
 = do   (x', s, cons') <- generateX x env cons
        return (Query [] x', s, cons')

-- Query with a context
generateQ qq@(Query (c:_) _) env cons
 -- Discharge any constraints on the result
 =   discharge (annAnnot.annotOfQuery) substTQ
 =<< case c of
    -- In the following "rules",
    --  x't stands for "temporality of x";
    --  x'p "possibility of x";
    --  x'd "data type of x"
    --  and so on.
    --
    -- >   windowed n days ~> Aggregate x'p x'd
    -- > : Aggregate x'p x'd
    Windowed _ from to
     -> do  (q', sq, t', consr) <- rest cons env

            -- Windowed only works for aggregates
            cons'    <- requireAgg t' consr
            let t''   = canonT $ Temporality TemporalityAggregate t'

            let q''   = with cons' q' t'' $ \a' -> Windowed a' from to
            return (q'', sq, cons')

    -- >   latest n ~> x't x'p x'd
    -- > : Aggregate Possibly (ReturnOfLatest x't x'd)
    Latest _ i
     -> do  (q', sq, tq, consr) <- rest cons env

            let (tmpq, _, datq)  = decomposeT tq
            retDat              <- TypeVar <$> fresh

            -- Latest works for aggregates or elements.
            -- If the end is an element, such as
            --
            -- > latest 3 ~> value
            --
            -- the result type is actually an array of the last three elements.
            --
            --
            -- However, if we are in a function definition right now such as
            --
            -- > silly_function x = latest 3 ~> x
            --
            -- we do not necessarily know whether "x" is an element or an aggregate;
            -- its temporality is still just a type variable.
            --
            -- So instead of making a choice prematurely, we introduce a constraint:
            --
            -- > silly_function x = latest 3 ~> x
            -- >  : forall (x't : Temporality)
            -- >           (x'd : Data)
            -- >           (ret : Data)
            -- >    (ret = ReturnOfLatest x't x'd)
            -- > => x't x'd -> Aggregate ret
            --
            -- The definition for ReturnOfLatest is in Icicle.Source.Type.Constraints,
            -- but is something like
            --
            -- > ReturnOfLatest Aggregate d = d
            -- > ReturnOfLatest Element   d = Array d
            --
            let cons' = require a (CReturnOfLatest retDat (fromMaybe TemporalityPure tmpq) datq) consr
            let t'    = canonT
                      $ Temporality TemporalityAggregate
                      $ Possibility PossibilityPossibly retDat

            let q''   = with cons' q' t' $ \a' -> Latest a' i
            return (q'', sq, cons')

    -- >   group (Element k'p k'd) ~> Aggregate v'p v'd
    -- > : Aggregate (PossibilityJoin k'p v'p) (Group k'd v'd)
    GroupBy _ x
     -> do  (x', sx, consk)       <- generateX x env cons
            (q', sq, tval, consr) <- rest consk env

            let tkey = annResult $ annotOfExp x'

            cons'          <-  requireTemporality tkey TemporalityElement consr
                           >>= requireAgg tval
            (poss, cons'') <-  requirePossibilityJoin tkey tval cons'

            let t'  = canonT
                    $ Temporality TemporalityAggregate
                    $ Possibility poss
                    $ GroupT tkey tval

            let ss  = compose sx sq
            let q'' = with cons'' q' t' $ \a' -> GroupBy a' x'
            return (q'', ss, cons'')

    -- >   group fold (k, v) = ( |- Q : Aggregate g'p (Group a'k a'v))
    -- >   ~> (k: Element a'k, v: Element a'v |- Aggregate a'p a)
    -- >    : Aggregate (PossibilityJoin g'p a'p) a
    GroupFold _ k v x
     -> do  (x', sx, consg) <- generateX x env cons
            let tgroup       = annResult $ annotOfExp x'

            retk <- Temporality TemporalityElement . TypeVar <$> fresh
            retv <- Temporality TemporalityElement . TypeVar <$> fresh

            (q', sq, t', consr)
                <- withBind k retk env
                 $ (fmap flip . withBind) v retv (rest consg)

            cons'  <-  requireAgg  t' consr
                   >>= requireAgg  tgroup
                   >>= return . requireData tgroup (GroupT retk retv)

            (poss, cons'') <- requirePossibilityJoin tgroup t' cons'

            let t'' = canonT
                    $ Temporality TemporalityAggregate
                    $ Possibility poss t'

            let ss  = compose sx sq
            let q'' = with cons'' q' t'' $ \a' -> GroupFold a' k v x'
            return (q'', ss, cons'')

    -- >   distinct (Element k'p k'd) ~> Aggregate v'p v'd
    -- > : Aggregate (PossibilityJoin k'p v'p) v'd
    Distinct _ x
     -> do  (x', sx, consk)     <- generateX x env cons
            (q', sq, t', consr) <- rest consk env

            let tkey = annResult $ annotOfExp x'

            cons'          <-  requireTemporality tkey TemporalityElement consr
                           >>= requireAgg t'
            (poss, cons'') <-  requirePossibilityJoin tkey t' cons'

            let t'' = canonT
                    $ Temporality TemporalityAggregate
                    $ Possibility poss t'

            let ss  = compose sx sq
            let q'' = with cons'' q' t'' $ \a' -> Distinct a' x'
            return (q'', ss, cons'')

    -- >   filter (Element p'p Bool) ~> Aggregate x'p x'd
    -- > : Aggregate (PossibilityJoin p'p x'p) x'd
    Filter _ x
     -> do  (x', sx, consp)     <- generateX x env cons
            (q', sq, t', consr) <- rest consp env

            let pred = annResult $ annotOfExp x'

            cons'          <-  requireTemporality pred TemporalityElement consr
                           >>= return . requireData pred BoolT
                           >>= requireAgg t'
            (poss, cons'') <-  requirePossibilityJoin pred t' cons'

            let t'' = canonT
                    $ Temporality TemporalityAggregate
                    $ Possibility poss t'

            let ss  = compose sx sq
            let q'' = with cons'' q' t'' $ \a' -> Filter a' x'
            return (q'', ss, cons'')

    -- >     let fold  bind = ( |- Pure z'p a'd) : ( bind : Element z'p a'd |- Element k'p a'd)
    -- >  ~> (bind : Aggregate k'p a'd |- Aggregate r'p r'd)
    -- >   :  Aggregate r'p r'd
    --
    -- >     let fold1 bind = ( |- Element z'p a'd) : ( bind : Element z'p a'd |- Element k'p a'd)
    -- >  ~> (bind : Aggregate Possibly a'd |- Aggregate r'p r'd)
    -- >   :  Aggregate r'p r'd
    LetFold _ f
     -> do  (i,si, csi) <- generateX (foldInit f) env cons
            (w,sw, csw) <- withBind  (foldBind f) (annResult $ annotOfExp i) env
                                     (fmap flip generateX (foldWork f) csi)

            let bindType
                 | FoldTypeFoldl1 <- foldType f
                 = canonT
                 $ Temporality TemporalityAggregate
                 $ Possibility PossibilityPossibly
                 $ annResult $ annotOfExp w

                 | otherwise
                 = canonT
                 $ Temporality TemporalityAggregate
                 $ annResult $ annotOfExp w

            (q', sq, t', consr) <- withBind (foldBind f) bindType env (rest csw)

            consf
              <- case foldType f of
                  FoldTypeFoldl1
                   -> requireTemporality (annResult $ annotOfExp i) TemporalityElement consr
                  FoldTypeFoldl
                   -> requireTemporality (annResult $ annotOfExp i) TemporalityPure consr

            let (_,_,it) = decomposeT $ annResult $ annotOfExp i
            let (_,_,wt) = decomposeT $ annResult $ annotOfExp w

            cons' <-  requireAgg t' consf
                  >>= requireTemporality (annResult $ annotOfExp w) TemporalityElement
                  >>= return . require a (CEquals it wt)

            let t'' = canonT $ Temporality TemporalityAggregate t'
            let s'  = si `compose` sw `compose` sq

            let q'' = with cons' q' t'' $ \a' -> LetFold a' (f { foldInit = i, foldWork = w })
            return (q'', s', cons')

    -- Lets are not allowed if it means the binding would not be able to be used in the body.
    -- For example, trying to bind an Aggregate where the body is an Element, means that the
    -- definition cannot possibly be used: any reference to the binding would force the body to be
    -- an Aggregate itself.
    --
    -- The constraint "let't = ReturnOfLetTemporalities def't body't" is used for this.
    -- 
    -- >   let n = ( |- def't def'p def'd )
    -- >    ~> ( n : def't def'p def'd |- body't body'p body'd )
    -- > : (ReturnOfLetTemporalities def't body't) body'p body'd
    Let _ n x
     -> do  (x', sx, consd) <- generateX x env cons

            (q',sq,tq,consr) <- withBind n (annResult $ annotOfExp x') env (rest consd)

            retTmp   <- TypeVar <$> fresh
            let tmpx  = getTemporalityOrPure $ annResult $ annotOfExp x'
            let tmpq  = getTemporalityOrPure $ tq

            let cons' = require a (CReturnOfLetTemporalities retTmp tmpx tmpq) consr
            let t'    = canonT $ Temporality retTmp tq

            let ss  = compose sx sq
            let q'' = with cons' q' t' $ \a' -> Let a' n x'
            return (q'', ss, cons')

 where
  a  = annotOfContext c

  -- Generate constraints for the remainder of the query, and rip out the result type
  rest cs e
   = do (q',s',cx') <- generateQ (qq { contexts = drop 1 $ contexts qq }) e cs
        return (q', s', annResult $ annotOfQuery q',cx')

  -- Rebuild the result with given substitution and type, using the given constraints
  with cs q' t' c'
   = let a' = Annot a t' cs
     in  q' { contexts = c' a' : contexts q' }

  -- Helpers for adding constraints
  requireTemporality ty tmp cx
   | TemporalityPure <- getTemporalityOrPure ty
   = return cx
   | otherwise
   = do n <- fresh
        return $ require a (CEquals ty (Temporality tmp $ TypeVar n)) cx

  requireAgg t
   = requireTemporality t TemporalityAggregate

  requireData t1 t2 cx
   = let (_,_,d1) = decomposeT t1
         (_,_,d2) = decomposeT t2
     in  require a (CEquals d1 d2) cx

  requirePossibilityJoin t1 t2 cx
   = do poss   <- TypeVar <$> fresh
        let pt1 = getPossibilityOrDefinitely t1
        let pt2 = getPossibilityOrDefinitely t2
        let c'  = require a (CPossibilityJoin poss pt1 pt2) cx
        return (poss, c')


-- | Generate constraints for expression
generateX
  :: Ord n
  => Exp a n
  -> GenEnv n
  -> GenConstraintSet a n
  -> Gen a n (Exp'C a n, SubstT n, GenConstraintSet a n)
generateX x env cons
 =   discharge (annAnnot.annotOfExp) substTX
 =<< case x of
    -- Variables can only be values, not functions.
    Var a n
     -> do (fErr, argsT, resT, cons') <- lookup a n env cons

           when (not $ null argsT)
             $ Gen . hoistEither
             $ errorNoSuggestions (ErrorFunctionWrongArgs a x fErr [])

           let x' = annotate cons' resT
                  $ \a' -> Var a' n
           return (x', Map.empty, cons')

    -- Nested just has the type of its inner query.
    Nested _ q
     -> do (q', sq, cons') <- generateQ q env cons

           let x' = annotate cons' (annResult $ annotOfQuery q')
                  $ \a' -> Nested a' q'
           return (x', sq, cons')

    -- Applications are a bit more complicated.
    -- If your function expects an argument with a particular temporality,
    -- and you give it that temporality, it is fine; function application is as usual.
    -- (This is even if it expects Pure, and you apply a Pure)
    --
    -- If your function expects a Pure argument, and you give it another temporality
    -- such as Element, that means the argument must be implicitly unboxed to a pure computation,
    -- and then the result of application being reboxed as an Element.
    -- Reboxing can only work if the result type is pure or the desired temporality;
    -- you could not rebox an Aggregate result to an Element.
    --
    -- Look at an application of (+), for example:
    --  (+) : Pure Int -> Pure Int -> Pure Int
    -- However if one of its arguments is an Element:
    --  (x : Pure Int) + (y : Element Int) : Element Int
    -- here the y is unboxed, then the result is reboxed.
    --
    App a _ _
     -> let (f, args)   = takeApps x
            look        | Prim _ p <- f
                        = primLookup a p cons
                        | Var _ n  <- f
                        = lookup a n env cons
                        | otherwise
                        = Gen . hoistEither
                        $ errorNoSuggestions (ErrorApplicationNotFunction a x)
        in do   (fErr, argsT, resT, cons') <- look

                (args', subs', conss)      <- unzip3 <$> mapM ((flip . flip generateX) env cons') args
                let argsT'                  = fmap (annResult.annotOfExp) args'

                when (length argsT /= length args)
                 $ Gen. hoistEither
                 $ errorNoSuggestions (ErrorFunctionWrongArgs a x fErr argsT')

                let go (t, c) u     = appType a t u c
                let (resT', cons'') = foldl' go (resT, concat conss) (argsT `zip` argsT')

                let s' = foldl compose Map.empty subs'
                let f' = annotate cons' resT' $ \a' -> reannotX (const a') f

                return (foldl mkApp f' args', s', cons'')

    -- Unapplied primitives should be relatively easy
    Prim a p
     -> do (fErr, argsT, resT, cons') <- primLookup a p cons

           when (not $ null argsT)
             $ Gen . hoistEither
             $ errorNoSuggestions (ErrorFunctionWrongArgs a x fErr [])

           let x' = annotate cons' resT
                  $ \a' -> Prim a' p
           return (x', Map.empty, cons')

    -- Cases require:
    --
    --  1. Alternatives to have "join-able" types, i.e. no mixing of aggregates and elements.
    --  2. The return temporality is the join of the scrutinee with the alternatives.
    --  3. The type of the scrutinee is compatible with all patterns.
    --
    Case a scrut pats
     -> do (scrut', sub, consS) <- generateX scrut env cons

           -- Destruct the scrutinee type into the base type
           -- and the temporality (defaulting to Pure).
           let scrutT =  annResult $ annotOfExp scrut'
           scrutTy    <- TypeVar <$> fresh
           scrutTm    <- TypeVar <$> fresh
           let cons'  =  require a (CExtractTemporality scrutTm scrutTy scrutT) consS

           -- Require the scrutinee and the alternatives to have compatible temporalities.
           returnType  <- TypeVar <$> fresh
           returnTemp  <- TypeVar <$> fresh
           returnTemp' <- TypeVar <$> fresh
           let cons''  =  require a (CTemporalityJoin returnTemp' scrutTm returnTemp) cons'

           (patsubs, ctx'') <- generateP a scrutT returnType returnTemp pats env cons'
           let (pats', subs) = unzip patsubs

           let t'    = Temporality returnTemp returnType
           let subst = Map.unions (sub : subs)

           let x' = annotate cons'' t'
                  $ \a' -> Case a' scrut' pats'

           return (x', subst, ctx'')
  where
  annotate cs t' f
   = let a' = Annot (annotOfExp x) t' cs
     in  f a'


generateP
  :: Ord n
  => a
  -> Type n                 -- ^ scrutinee type
  -> Type n                 -- ^ result base type
  -> Type n                 -- ^ result temporality
  -> [(Pattern n, Exp a n)] -- ^ pattern and alternative
  -> GenEnv n
  -> GenConstraintSet a n
  -> Gen a n ([((Pattern n, Exp'C a n), SubstT n)], GenConstraintSet a n)

generateP ann _ _ resTm [] _ cons
 = do   let cons' = require ann (CEquals resTm TemporalityPure) cons
        return ([], cons')

generateP ann scrutTy resTy resTm ((pat, alt):rest) env cons
 = do   (t, envp) <- goPat pat env

        let (_,_,datS) = decomposeT $ canonT scrutTy
        let conss      = require (annotOfExp alt) (CEquals datS t) cons

        (alt', sub, consa) <- generateX alt envp conss

        let altTy'  = annResult (annotOfExp alt')
        altTy      <- TypeVar <$> fresh
        altTp      <- TypeVar <$> fresh
        resTp'     <- TypeVar <$> fresh

        -- Require alternative types to have the same temporality if they
        -- do have temporalities. Otherwise defaults to TemporalityPure.
        let cons' = require (annotOfExp alt) (CExtractTemporality altTp altTy altTy')
        -- Require the alternative types without temporality to be the same.
                  . requireData resTy altTy
        -- Require return temporality to be compatible with alternative temporalities.
                  . require (annotOfExp alt) (CTemporalityJoin resTm resTp' altTp)
                  $ consa

        (rest', cons'') <- generateP ann scrutTy resTy resTp' rest env cons'
        let patsubs     = ((pat, alt'), sub) : rest'

        return (patsubs, cons'')

 where
  requireData t1 t2
   = let (_,_,d1) = decomposeT t1
         (_,_,d2) = decomposeT t2
     in  require ann $ CEquals d1 d2

  goPat  PatDefault e
   = (,e) . TypeVar <$> fresh

  goPat (PatVariable n) e
   = do let (tmpS,posS,_)  = decomposeT $ canonT scrutTy
        datV              <- TypeVar <$> fresh
        let env'           = bind n (recomposeT (tmpS, posS, datV)) e
        return (datV, env')

  goPat (PatCon ConSome  [p]) e
   = fmap (first OptionT) $ goPat p e
  goPat (PatCon ConNone  []) e
   = (,e) . OptionT . TypeVar <$> fresh
  goPat (PatCon ConTrue  []) e
   = return (BoolT, e)
  goPat (PatCon ConFalse []) e
   = return (BoolT, e)
  goPat (PatCon ConTuple [a,b]) e
   = do (ta, ea) <- goPat a e
        (tb, eb) <- goPat b ea
        return (PairT ta tb, eb)

  goPat _ _
   = Gen . hoistEither
   $ errorNoSuggestions (ErrorCaseBadPattern (annotOfExp alt) pat)


appType
 :: a
 -> Type n
 -> (Type n, Type n)
 -> GenConstraintSet a n
 -> (Type n, GenConstraintSet a n)
appType ann resT (expT,actT) cons
 = let (tmpE,posE,datE) = decomposeT $ canonT expT
       (tmpA,posA,datA) = decomposeT $ canonT actT
       (tmpR,posR,datR) = decomposeT $ canonT resT

       cons' = require ann (CEquals datE datA) cons

       (tmpR', cs)  = checkTemp (purely tmpE) (purely tmpA) (purely tmpR) cons'
       (posR', cs') = checkPoss (definitely posE) (definitely posA) (definitely posR) cs

       t = recomposeT (tmpR', posR', datR)
   in  (t, cs')

 where
  checkTemp = check' TemporalityPure
  checkPoss = check' PossibilityDefinitely

  check' pureMode modE modA modR cx
   | Nothing <- modA
   = (modR, cx)
   | Just _  <- modA
   , Nothing <- modE
   , Nothing <- modR
   = (modA, cx)
   | Just a' <- modA
   , Nothing <- modE
   , Just r' <- modR
   = (modR, require ann (CEquals a' r') cx)
   | otherwise
   = (modR, require ann (CEquals (maybe pureMode id modE) (maybe pureMode id modA)) cx)


  purely (Just TemporalityPure) = Nothing
  purely tmp = tmp

  definitely (Just PossibilityDefinitely) = Nothing
  definitely pos = pos


