{-# LANGUAGE CPP, MultiParamTypeClasses, FunctionalDependencies,
             UndecidableInstances, TypeSynonymInstances, FlexibleInstances
  #-}

{-|
    Translating from internal syntax to abstract syntax. Enables nice
    pretty printing of internal syntax.

    TODO

	- numbers on metas
	- fake dependent functions to independent functions
	- meta parameters
	- shadowing
-}
module Agda.Syntax.Translation.InternalToAbstract where

import Prelude hiding (mapM_, mapM)
import Control.Arrow
import Control.Monad.State hiding (mapM_, mapM)
import Control.Monad.Error hiding (mapM_, mapM)

import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.List hiding (sort)
import Data.Traversable

import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Info as Info
import Agda.Syntax.Fixity
import Agda.Syntax.Abstract as A
import qualified Agda.Syntax.Concrete as C
import Agda.Syntax.Internal as I
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad

import Agda.TypeChecking.Monad as M
import Agda.TypeChecking.Reduce
import {-# SOURCE #-} Agda.TypeChecking.Records
import Agda.TypeChecking.DisplayForm
import Agda.TypeChecking.Level

import Agda.Utils.Monad
import Agda.Utils.Tuple
import Agda.Utils.Permutation
import Agda.Utils.Size

#include "../../undefined.h"
import Agda.Utils.Impossible

apps :: MonadTCM tcm => (Expr, [Arg Expr]) -> tcm Expr
apps (e, [])		    = return e
apps (e, arg@(Arg Hidden _) : args) =
    do	showImp <- showImplicitArguments
	if showImp then apps (App exprInfo e (unnamed <$> arg), args)
		   else apps (e, args)
apps (e, arg:args)	    =
    apps (App exprInfo e (unnamed <$> arg), args)

exprInfo :: ExprInfo
exprInfo = ExprRange noRange

reifyApp :: MonadTCM tcm => Expr -> [Arg Term] -> tcm Expr
reifyApp e vs = curry apps e =<< reify vs

class Reify i a | i -> a where
    reify :: MonadTCM tcm => i -> tcm a

instance Reify MetaId Expr where
    reify x@(MetaId n) = liftTCM $ do
      mi  <- getMetaInfo <$> lookupMeta x
      let mi' = Info.MetaInfo (getRange mi)
                              (M.clScope mi)
                              (Just n)
      ifM shouldReifyInteractionPoints
          (do iis <- map (snd /\ fst) . Map.assocs
                      <$> gets stInteractionPoints
              case lookup x iis of
                Just ii@(InteractionId n)
                        -> return $ A.QuestionMark $ mi' {metaNumber = Just n}
                Nothing	-> return $ A.Underscore mi'
          ) (return $ A.Underscore mi')

instance Reify DisplayTerm Expr where
  reify d = case d of
    DTerm v -> reify v
    DWithApp us vs -> do
      us <- reify us
      let wapp [e] = e
	  wapp (e : es) = A.WithApp exprInfo e es
	  wapp [] = __IMPOSSIBLE__
      reifyApp (wapp us) vs

reifyDisplayForm :: MonadTCM tcm => QName -> Args -> tcm A.Expr -> tcm A.Expr
reifyDisplayForm x vs fallback = do
  enabled <- displayFormsEnabled
  if enabled
    then do
      md <- liftTCM $ displayForm x vs
      case md of
        Nothing -> fallback
        Just d  -> reify d
    else fallback

reifyDisplayFormP :: A.LHS -> TCM A.LHS
reifyDisplayFormP lhs@(A.LHS i x ps wps) =
  ifM (not <$> displayFormsEnabled) (return lhs) $ do
    let vs = [ Arg h $ I.Var n [] | (n, h) <- zip [0..] $ map argHiding ps]
    md <- liftTCM $ displayForm x vs
    reportSLn "syntax.reify.display" 20 $ "display form of " ++ show x ++ ": " ++ show md
    case md of
      Just d  | okDisplayForm d ->
        reifyDisplayFormP =<< displayLHS (map (namedThing . unArg) ps) wps d
      _ -> return lhs
  where
    okDisplayForm (DWithApp (d : ds) []) =
      okDisplayForm d && all okDisplayTerm ds
    okDisplayForm (DTerm (I.Def f vs)) = all okArg vs
    okDisplayForm _ = True -- False

    okDisplayTerm (DTerm v) = okTerm v
    okDisplayTerm _ = False

    okArg = okTerm . unArg

    okTerm (I.Var _ []) = True
    okTerm (I.Con c vs) = all okArg vs
    okTerm (I.Def x []) = show x == "_" -- Handling wildcards in display forms
    okTerm _            = True -- False

    flattenWith (DWithApp (d : ds) []) = case flattenWith d of
      (f, vs, ds') -> (f, vs, ds' ++ map unDTerm ds)
    flattenWith (DTerm (I.Def f vs)) = (f, vs, [])
    flattenWith _ = __IMPOSSIBLE__

    unDTerm (DTerm v) = v
    unDTerm _ = __IMPOSSIBLE__

    displayLHS ps wps d = case flattenWith d of
      (f, vs, ds) -> do
        ds <- mapM termToPat ds
        vs <- mapM argToPat vs
        return $ LHS i f vs (ds ++ wps)
      where
        info = PatRange noRange
        argToPat arg = fmap unnamed <$> traverse termToPat arg

        -- TODO: dot variables
        termToPat (I.Var n []) = return $ ps !! fromIntegral n
        termToPat (I.Con c vs) = A.ConP info (AmbQ [c]) <$> mapM argToPat vs
        termToPat (I.Def _ []) = return $ A.WildP info
        termToPat v = A.DotP info <$> reify v -- __IMPOSSIBLE__

-- Level literals should be expanded.

instance Reify Literal Expr where
  reify (LitLevel r n) = do
    Just kit <- builtinLevelKit
    reify $ fold (levelSuc kit) (levelZero kit) n
    where
    fold s z n | n < 0     = __IMPOSSIBLE__
               | otherwise = foldr (.) id (genericReplicate n s) z
  reify l@(LitInt    {}) = return (A.Lit l)
  reify l@(LitFloat  {}) = return (A.Lit l)
  reify l@(LitString {}) = return (A.Lit l)
  reify l@(LitChar   {}) = return (A.Lit l)

instance Reify Term Expr where
    reify v =
	do  v <- instantiate v
	    case v of
		I.Var n vs   -> do
                    x  <- liftTCM $ nameOfBV n `catchError` \_ -> freshName_ ("@" ++ show n)
                    reifyApp (A.Var x) vs
		I.Def x vs   -> reifyDisplayForm x vs $ do
		    n <- getDefFreeVars x
		    reifyApp (A.Def x) $ genericDrop n vs
		I.Con x vs   -> do
		  isR <- isRecord x
		  case isR of
		    True -> do
		      showImp <- showImplicitArguments
                      let keep ((h, x), v) = showImp || h == NotHidden
		      xs <- getRecordFieldNames x
		      vs <- reify $ map unArg vs
		      return $ A.Rec exprInfo $ map (snd *** id) $ filter keep $ zip xs vs
		    False -> reifyDisplayForm x vs $ do
                      let hide (Arg _ x) = Arg Hidden x
                      Constructor{conPars = np} <- theDef <$> getConstInfo x
		      scope <- getScope
                      let whocares = A.Underscore (Info.MetaInfo noRange scope Nothing)
                          us = replicate (fromIntegral np) $ Arg Hidden whocares
                      n  <- getDefFreeVars x
                      es <- reify vs
                      apps (A.Con (AmbQ [x]), genericDrop n $ us ++ es)
		I.Lam h b    ->
		    do	(x,e) <- reify b
			return $ A.Lam exprInfo (DomainFree h x) e
		I.Lit l	     -> reify l
		I.Pi a b     ->
		    do	Arg h a <- reify a
			(x,b)   <- reify b
			return $ A.Pi exprInfo [TypedBindings noRange h [TBind noRange [x] a]] b
		I.Fun a b    -> uncurry (A.Fun $ exprInfo)
				<$> reify (a,b)
		I.Sort s     -> reify s
		I.MetaV x vs -> apps =<< reify (x,vs)

data NamedClause = NamedClause QName I.Clause
-- Named clause does not need 'Recursion' flag since I.Clause has it
-- data NamedClause = NamedClause QName Recursion I.Clause

instance Reify ClauseBody RHS where
  reify NoBody     = return AbsurdRHS
  reify (Body v)   = RHS <$> reify v
  reify (NoBind b) = reify b
  reify (Bind b)   = reify $ absBody b  -- the variables should already be bound

stripImplicits :: MonadTCM tcm => [NamedArg A.Pattern] -> [A.Pattern] -> tcm [NamedArg A.Pattern]
stripImplicits ps wps =
  ifM showImplicitArguments (return ps) $ do
  let vars = dotVars (ps, wps)
  reportSLn "syntax.reify.implicit" 30 $ unlines
    [ "stripping implicits"
--     , "  ps   = " ++ show ps
--     , "  wps  = " ++ show wps
    , "  vars = " ++ show vars
    ]
  return $ strip vars ps
  where
    argsVars = Set.unions . map argVars
    argVars = patVars . namedThing . unArg
    patVars p = case p of
      A.VarP x      -> Set.singleton x
      A.ConP _ _ ps -> argsVars ps
      A.DefP _ _ ps -> Set.empty
      A.DotP _ e    -> Set.empty
      A.WildP _     -> Set.empty
      A.AbsurdP _   -> Set.empty
      A.LitP _      -> Set.empty
      A.ImplicitP _ -> Set.empty
      A.AsP _ _ p   -> patVars p

    strip dvs = stripArgs
      where
        stripArgs [] = []
        stripArgs (a : as) = case argHiding a of
          Hidden | canStrip a as -> stripArgs as
          _                      -> stripArg a : stripArgs as

        -- TODO: use named implicits (need to get the names from somewhere!)
        canStrip a as = and
          [ varOrDot p
          , noInterestingBindings p
          , all (flip canStrip []) $ takeWhile ((Hidden ==) . argHiding) as
          ]
          where p = namedThing $ unArg a

        stripArg a = fmap (fmap stripPat) a

        stripPat p = case p of
          A.VarP _      -> p
          A.ConP i c ps -> A.ConP i c $ stripArgs ps
          A.DefP _ _ _  -> p
          A.DotP _ e    -> p
          A.WildP _     -> p
          A.AbsurdP _   -> p
          A.LitP _      -> p
          A.ImplicitP _ -> p
          A.AsP i x p   -> A.AsP i x $ stripPat p

        noInterestingBindings p =
          Set.null $ dvs `Set.intersection` patVars p

        varOrDot (A.VarP _)      = True
        varOrDot (A.WildP _)     = True
        varOrDot (A.DotP _ _)    = True
        varOrDot (A.ImplicitP _) = True
        varOrDot _               = False


class DotVars a where
  dotVars :: a -> Set Name

instance DotVars a => DotVars (Arg a) where
  dotVars (Arg Hidden _)    = Set.empty
  dotVars (Arg NotHidden x) = dotVars x

instance DotVars a => DotVars (Named s a) where
  dotVars = dotVars . namedThing

instance DotVars a => DotVars [a] where
  dotVars = Set.unions . map dotVars

instance (DotVars a, DotVars b) => DotVars (a, b) where
  dotVars (x, y) = Set.union (dotVars x) (dotVars y)

instance DotVars A.Pattern where
  dotVars p = case p of
    A.VarP _      -> Set.empty
    A.ConP _ _ ps -> dotVars ps
    A.DefP _ _ ps -> dotVars ps
    A.DotP _ e    -> dotVars e
    A.WildP _     -> Set.empty
    A.AbsurdP _   -> Set.empty
    A.LitP _      -> Set.empty
    A.ImplicitP _ -> Set.empty
    A.AsP _ _ p   -> dotVars p

instance DotVars A.Expr where
  dotVars e = case e of
    A.ScopedExpr _ e -> dotVars e
    A.Var x          -> Set.singleton x
    A.Def _          -> Set.empty
    A.Con _          -> Set.empty
    A.Lit _          -> Set.empty
    A.QuestionMark _ -> Set.empty
    A.Underscore _   -> Set.empty
    A.App _ e1 e2    -> dotVars (e1, e2)
    A.WithApp _ e es -> dotVars (e, es)
    A.Lam _ _ e      -> dotVars e
    A.AbsurdLam _ _  -> Set.empty
    A.Pi _ tel e     ->  dotVars (tel, e)
    A.Fun _ a b      -> dotVars (a, b)
    A.Set _ _        -> Set.empty
    A.Prop _         -> Set.empty
    A.Let _ _ _      -> __IMPOSSIBLE__
    A.Rec _ es       -> dotVars $ map snd es
    A.ETel _         -> __IMPOSSIBLE__

instance DotVars TypedBindings where
  dotVars (TypedBindings _ _ bs) = dotVars bs

instance DotVars TypedBinding where
  dotVars (TBind _ _ e) = dotVars e
  dotVars (TNoBind e)   = dotVars e

reifyPatterns :: MonadTCM tcm =>
  I.Telescope -> Permutation -> [Arg I.Pattern] -> tcm [NamedArg A.Pattern]
reifyPatterns tel perm ps = evalStateT (reifyArgs ps) 0
  where
    reifyArgs as = map (fmap unnamed) <$> mapM reifyArg as
    reifyArg a   = traverse reifyPat a

    tick = do i <- get; put (i + 1); return i

    translate = (vars !!)
      where
        vars = permute (invertP perm) [0..]

    reifyPat p = case p of
      I.VarP s    -> do
        i <- tick
        let j = translate i
        lift $ A.VarP <$> nameOfBV (size tel - 1 - j)
      I.DotP v -> do
        t <- lift $ reify v
        let vars = Set.map show (dotVars t)
        tick
        if Set.member "()" vars
          then return $ A.DotP i $ A.Underscore mi
          else lift $ A.DotP i <$> reify v
      I.LitP (LitLevel {}) -> __IMPOSSIBLE__
      I.LitP l             -> return (A.LitP l)
      I.ConP c ps -> A.ConP i (AmbQ [c]) <$> reifyArgs ps
      where
        i = PatRange noRange
        mi = MetaInfo noRange emptyScopeInfo Nothing

instance Reify NamedClause A.Clause where
  reify (NamedClause f (I.Clause _ tel perm ps body)) = addCtxTel tel $ do
    ps  <- reifyPatterns tel perm ps
    lhs <- liftTCM $ reifyDisplayFormP $ LHS info f ps []
    nfv <- getDefFreeVars f
    lhs <- stripImps $ dropParams nfv lhs
    rhs <- reify body
    return $ A.Clause lhs rhs []
    where
      info = LHSRange noRange
      dropParams n (LHS i f ps wps) = LHS i f (genericDrop n ps) wps
      stripImps (LHS i f ps wps) = do
        ps <- stripImplicits ps wps
        return $ LHS i f ps wps

instance Reify Type Expr where
    reify (I.El _ t) = reify t

instance Reify Sort Expr where
    reify s =
	do  s <- instantiateFull s
	    case s of
                I.Type (I.Lit (LitLevel _ n)) -> return $ A.Set exprInfo n
                I.Type a -> do
                  a <- reify a
                  return $ A.App exprInfo (A.Set exprInfo 0)
                                          (Arg NotHidden (unnamed a))
		I.Prop	     -> return $ A.Prop exprInfo
		I.MetaS x as -> apps =<< reify (x, as)
		I.Suc s	     ->
		    do	suc <- freshName_ "suc"	-- TODO: hack
			e   <- reify s
			return $ A.App exprInfo (A.Var suc) (Arg NotHidden $ unnamed e)
                I.Inf       -> A.Var <$> freshName_ "Setω"
                I.DLub s1 s2 -> do
                  lub <- freshName_ "dLub" -- TODO: hack
                  (e1,e2) <- reify (s1, I.Lam NotHidden $ fmap Sort s2)
                  let app x y = A.App exprInfo x (Arg NotHidden $ unnamed y)
                  return $ A.Var lub `app` e1 `app` e2
		I.Lub s1 s2 ->
		    do	lub <- freshName_ "\\/"	-- TODO: hack
			(e1,e2) <- reify (s1,s2)
			let app x y = A.App exprInfo x (Arg NotHidden $ unnamed y)
			return $ A.Var lub `app` e1 `app` e2

instance Reify i a => Reify (Abs i) (Name, a) where
    reify (Abs s v) =
	do  x <- freshName_ s
	    e <- addCtx x (Arg NotHidden $ sort I.Prop) -- type doesn't matter
		 $ reify v
	    return (x,e)

instance Reify I.Telescope A.Telescope where
  reify EmptyTel = return []
  reify (ExtendTel arg tel) = do
    Arg h e <- reify arg
    (x,bs)  <- reify $ betterName tel
    let r = getRange e
    return $ TypedBindings r h [TBind r [x] e] : bs
    where
      betterName (Abs "_" x) = Abs "z" x
      betterName (Abs s   x) = Abs s   x

instance Reify i a => Reify (Arg i) (Arg a) where
    reify = traverse reify

instance Reify i a => Reify [i] [a] where
    reify = traverse reify

instance (Reify i1 a1, Reify i2 a2) => Reify (i1,i2) (a1,a2) where
    reify (x,y) = (,) <$> reify x <*> reify y

instance (Reify t t', Reify a a')
         => Reify (Judgement t a) (Judgement t' a') where
    reify (HasType i t) = HasType <$> reify i <*> reify t
    reify (IsSort i) = IsSort <$> reify i


