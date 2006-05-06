{-# OPTIONS -cpp #-}

module TypeChecking.Conversion where

import Data.Generics

import Syntax.Common
import Syntax.Internal
import TypeChecking.Monad
import TypeChecking.Monad.Context
import TypeChecking.MetaVars
import TypeChecking.Substitute
import TypeChecking.Reduce
import TypeChecking.Constraints

import TypeChecking.Monad.Debug
debug' = debug

#include "../undefined.h"

-- | Equality of two instances of the same metavar
--
equalSameVar :: Data a => 
                (MetaId -> a) -> (a -> MetaVariable) -> MetaId -> Args -> Args -> TCM ()
equalSameVar meta inst x args1 args2 =
    if length args1 == length args2 then do
        -- next 2 checks could probably be nicely merged into construction 
        --   of newArgs using ListT, but then can't use list comprehension.
        checkArgs x args1 
        checkArgs x args2 
        let idx = [0 .. length args1 - 1]
        let newArgs = [Arg NotHidden $ Var n [] | (n, (a,b)) <- zip idx $ reverse $ zip args1 args2
						, a === b]
        v <- newMetaSame x args1 meta
        setRef Why x $ inst $ abstract args1 (v `apply` newArgs)
    else fail $ "equalSameVar"
    where
	Arg _ (Var i []) === Arg _ (Var j []) = i == j
	_		 === _		      = False


-- | Type directed equality on values.
--
equalVal :: Data a => a -> Type -> Term -> Term -> TCM ()
equalVal _ a m n = do --trace ("equalVal ("++(show a)++") ("++(show m)++") ("++(show n)++")\n") $ do
    a' <- instType a
    --debug $ "equalVal " ++ show m ++ " == " ++ show n ++ " : " ++ show a'
    case a' of
        Pi h a (Abs x b) -> 
            let p = Arg h $ Var 0 []	-- TODO: this must be wrong!
                m' = raise 1 m
                n' = raise 1 n
            in do name <- freshName_ x
		  addCtx name a $ equalVal Why b (m' `apply` [p]) (n' `apply` [p])
        MetaT x _ -> addCnstr [x] (ValueEq a m n)
        _ -> catchConstr (ValueEq a' m n) $ equalAtm Why m n

-- | Syntax directed equality on atomic values
--
equalAtm :: Data a => a -> Term -> Term -> TCM ()
equalAtm _ m n = do
    mVal <- reduceM m  -- need mVal for the metavar case
    nVal <- reduceM n  -- need nVal for the metavar case
--     debug $ "equalAtm " ++ show m ++ " == " ++ show n
--     debug $ "         " ++ show mVal ++ " == " ++ show nVal
    --trace ("equalAtm ("++(show mVal)++") ("++(show nVal)++")\n") $ 
    case (mVal, nVal) of
        (Lit l1, Lit l2) | l1 == l2 -> return ()
        (Var i iArgs, Var j jArgs) | i == j -> do
            a <- typeOfBV i
            equalArg Why a iArgs jArgs
        (Def x xArgs, Def y yArgs) | x == y -> do
            a <- typeOfConst x
            equalArg Why a xArgs yArgs
        (Con x xArgs, Con y yArgs) | x == y -> do
            a <- typeOfConst x
            equalArg Why a xArgs yArgs
        (MetaV x xArgs, MetaV y yArgs) | x == y ->
	    equalSameVar (\x -> MetaV x []) InstV x xArgs yArgs -- !!! MetaV args???
        (MetaV x xArgs, _) -> assign x xArgs nVal
        (_, MetaV x xArgs) -> assign x xArgs mVal
        _ -> fail $ "equalAtm "++(show mVal)++" ==/== "++(show nVal)


-- | Type-directed equality on argument lists
--
equalArg :: Data a => a -> Type -> Args -> Args -> TCM ()
equalArg _ a args1 args2 = do
    a' <- instType a
    case (a', args1, args2) of 
        (_, [], []) -> return ()
        (Pi h b (Abs _ c), (Arg _ arg1 : args1), (Arg _ arg2 : args2)) -> do
            equalVal Why b arg1 arg2
            equalArg Why (subst arg1 c) args1 args2
        _ -> fail $ "equalArg "++(show a)++" "++(show args1)++" "++(show args2)


-- | Equality on Types
--   Assumes @Type@s being compared are at the same @Sort@
--   !!! Safe to not have @LamT@ case? @LamT@s shouldn't surface?
--
equalTyp :: Data a => a -> Type -> Type -> TCM ()
equalTyp _ a1 a2 = do
    a1' <- instType a1
    a2' <- instType a2
--     debug $ "equalTyp " ++ show a1 ++ " == " ++ show a2
--     debug $ "         " ++ show a1' ++ " == " ++ show a2'
    case (a1', a2') of
        (El m1 s1, El m2 s2) ->
            equalVal Why (sort s1) m1 m2
        (Pi h a1 a2, Pi h' b1 b2) -> do
            equalTyp Why a1 b1
            let Abs x a2' = raise 1 a2
            let Abs _ b2' = raise 1 b2
	    name <- freshName_ x
            addCtx name a1 $ equalTyp Why (subst (Var 0 []) a2') (subst (Var 0 []) b2')
				-- TODO: this looks dangerous.. what does subst really do?
        (Sort s1, Sort s2) -> return ()
        (MetaT x xDeps, MetaT y yDeps) | x == y -> 
            equalSameVar (\x -> MetaT x []) InstT x xDeps yDeps -- !!! MetaT???
        (MetaT x xDeps, a) -> assign x xDeps a 
        (a, MetaT x xDeps) -> assign x xDeps a 
	(LamT _, _)   -> __IMPOSSIBLE__
	(El _ _, _)   -> fail "not equal"
	(Pi _ _ _, _) -> fail "not equal"
	(Sort _, _)   -> fail "not equal"

