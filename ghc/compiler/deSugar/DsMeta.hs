-----------------------------------------------------------------------------
-- The purpose of this module is to transform an HsExpr into a CoreExpr which
-- when evaluated, returns a (Meta.Q Meta.Exp) computation analogous to the
-- input HsExpr. We do this in the DsM monad, which supplies access to
-- CoreExpr's of the "smart constructors" of the Meta.Exp datatype.
--
-- It also defines a bunch of knownKeyNames, in the same way as is done
-- in prelude/PrelNames.  It's much more convenient to do it here, becuase
-- otherwise we have to recompile PrelNames whenever we add a Name, which is
-- a Royal Pain (triggers other recompilation).
-----------------------------------------------------------------------------


module DsMeta( dsBracket, dsReify,
	       templateHaskellNames, qTyConName, 
	       liftName, exprTyConName, declTyConName, typeTyConName,
	       decTyConName, typTyConName ) where

#include "HsVersions.h"

import {-# SOURCE #-}	DsExpr ( dsExpr )

import MatchLit	  ( dsLit )
import DsUtils    ( mkListExpr, mkStringLit, mkCoreTup, mkIntExpr )
import DsMonad

import qualified Language.Haskell.THSyntax as M

import HsSyn  	  ( Pat(..), HsExpr(..), Stmt(..), HsLit(..), HsOverLit(..),
		    Match(..), GRHSs(..), GRHS(..), HsBracket(..),
                    HsStmtContext(ListComp,DoExpr), ArithSeqInfo(..),
		    HsBinds(..), MonoBinds(..), HsConDetails(..),
		    TyClDecl(..), HsGroup(..),
		    HsReify(..), ReifyFlavour(..), 
		    HsType(..), HsContext(..), HsPred(..), HsTyOp(..),
	 	    HsTyVarBndr(..), Sig(..), ForeignDecl(..),
		    InstDecl(..), ConDecl(..), BangType(..),
		    PendingSplice, splitHsInstDeclTy,
		    placeHolderType, tyClDeclNames,
		    collectHsBinders, collectPatBinders, collectPatsBinders,
		    hsTyVarName, hsConArgs, getBangType,
		    toHsType
		  )

import PrelNames  ( mETA_META_Name, rationalTyConName, negateName,
		    parrTyConName )
import MkIface	  ( ifaceTyThing )
import Name       ( Name, nameOccName, nameModule, getSrcLoc )
import OccName	  ( isDataOcc, isTvOcc, occNameUserString )
-- To avoid clashes with DsMeta.varName we must make a local alias for OccName.varName
-- we do this by removing varName from the import of OccName above, making
-- a qualified instance of OccName and using OccNameAlias.varName where varName
-- ws previously used in this file.
import qualified OccName( varName, tcName )

import Module	  ( Module, mkThPkgModule, moduleUserString )
import Id         ( Id, idType )
import Name	  ( mkKnownKeyExternalName )
import OccName	  ( mkOccFS )
import NameEnv
import NameSet
import Type       ( Type, mkGenTyConApp )
import TcType	  ( TyThing(..), tcTyConAppArgs )
import TyCon	  ( DataConDetails(..) )
import TysWiredIn ( stringTy )
import CoreSyn
import CoreUtils  ( exprType )
import SrcLoc	  ( noSrcLoc )
import Maybes	  ( orElse )
import Maybe	  ( catMaybes, fromMaybe )
import Panic	  ( panic )
import Unique	  ( mkPreludeTyConUnique, mkPreludeMiscIdUnique )
import BasicTypes ( NewOrData(..), StrictnessMark(..), isBoxed ) 
import SrcLoc     ( SrcLoc )

import Outputable
import FastString	( mkFastString )

import Monad ( zipWithM )
import List ( sortBy )
 
-----------------------------------------------------------------------------
dsBracket :: HsBracket Name -> [PendingSplice] -> DsM CoreExpr
-- Returns a CoreExpr of type M.ExpQ
-- The quoted thing is parameterised over Name, even though it has
-- been type checked.  We don't want all those type decorations!

dsBracket brack splices
  = dsExtendMetaEnv new_bit (do_brack brack)
  where
    new_bit = mkNameEnv [(n, Splice e) | (n,e) <- splices]

    do_brack (ExpBr e)  = do { MkC e1  <- repE e      ; return e1 }
    do_brack (PatBr p)  = do { MkC p1  <- repP p      ; return p1 }
    do_brack (TypBr t)  = do { MkC t1  <- repTy t     ; return t1 }
    do_brack (DecBr ds) = do { MkC ds1 <- repTopDs ds ; return ds1 }

-----------------------------------------------------------------------------
dsReify :: HsReify Id -> DsM CoreExpr
-- Returns a CoreExpr of type 	reifyType --> M.TypQ
--				reifyDecl --> M.DecQ
--				reifyFixty --> Q M.Fix
dsReify (ReifyOut ReifyType name)
  = do { thing <- dsLookupGlobal name ;
		-- By deferring the lookup until now (rather than doing it
		-- in the type checker) we ensure that all zonking has
		-- been done.
	 case thing of
	    AnId id -> do { MkC e <- repTy (toHsType (idType id)) ;
			    return e }
	    other   -> pprPanic "dsReify: reifyType" (ppr name)
	}

dsReify r@(ReifyOut ReifyDecl name)
  = do { thing <- dsLookupGlobal name ;
	 mb_d <- repTyClD (ifaceTyThing thing) ;
	 case mb_d of
	   Just (MkC d) -> return d 
	   Nothing	-> pprPanic "dsReify" (ppr r)
	}

{- -------------- Examples --------------------

  [| \x -> x |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (var x1)


  [| \x -> $(f [| x |]) |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (f (var x1))
-}


-------------------------------------------------------
-- 			Declarations
-------------------------------------------------------

repTopDs :: HsGroup Name -> DsM (Core (M.Q [M.Dec]))
repTopDs group
 = do { let { bndrs = groupBinders group } ;
	ss    <- mkGenSyms bndrs ;

	-- Bind all the names mainly to avoid repeated use of explicit strings.
	-- Thus	we get
	--	do { t :: String <- genSym "T" ;
	--	     return (Data t [] ...more t's... }
	-- The other important reason is that the output must mention
	-- only "T", not "Foo:T" where Foo is the current module

	
	decls <- addBinds ss (do {
			val_ds <- rep_binds' (hs_valds group) ;
			tycl_ds <- mapM repTyClD' (hs_tyclds group) ;
			inst_ds <- mapM repInstD' (hs_instds group) ;
			-- more needed
			return (de_loc $ sort_by_loc $ val_ds ++ catMaybes tycl_ds ++ inst_ds) }) ;

	decl_ty <- lookupType declTyConName ;
	let { core_list = coreList' decl_ty decls } ;

	dec_ty <- lookupType decTyConName ;
	q_decs  <- repSequenceQ dec_ty core_list ;

	wrapNongenSyms ss q_decs
	-- Do *not* gensym top-level binders
      }

groupBinders (HsGroup { hs_valds = val_decls, hs_tyclds = tycl_decls,
			hs_fords = foreign_decls })
-- Collect the binders of a Group
  = collectHsBinders val_decls ++
    [n | d <- tycl_decls, (n,_) <- tyClDeclNames d] ++
    [n | ForeignImport n _ _ _ _ <- foreign_decls]


{- 	Note [Binders and occurrences]
	~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we desugar [d| data T = MkT |]
we want to get
	Data "T" [] [Con "MkT" []] []
and *not*
	Data "Foo:T" [] [Con "Foo:MkT" []] []
That is, the new data decl should fit into whatever new module it is
asked to fit in.   We do *not* clone, though; no need for this:
	Data "T79" ....

But if we see this:
	data T = MkT 
	foo = reifyDecl T

then we must desugar to
	foo = Data "Foo:T" [] [Con "Foo:MkT" []] []

So in repTopDs we bring the binders into scope with mkGenSyms and addBinds,
but in dsReify we do not.  And we use lookupOcc, rather than lookupBinder
in repTyClD and repC.

-}

repTyClD :: TyClDecl Name -> DsM (Maybe (Core M.DecQ))
repTyClD decl = do x <- repTyClD' decl
                   return (fmap snd x)

repTyClD' :: TyClDecl Name -> DsM (Maybe (SrcLoc, Core M.DecQ))

repTyClD' (TyData { tcdND = DataType, tcdCtxt = cxt, 
		   tcdName = tc, tcdTyVars = tvs, 
		   tcdCons = DataCons cons, tcdDerivs = mb_derivs,
           tcdLoc = loc}) 
 = do { tc1 <- lookupOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
      	       cxt1   <- repContext cxt ;
               cons1   <- mapM repC cons ;
      	       cons2   <- coreList consTyConName cons1 ;
      	       derivs1 <- repDerivs mb_derivs ;
      	       repData cxt1 tc1 (coreList' stringTy bndrs) cons2 derivs1 } ;
        return $ Just (loc, dec) }

repTyClD' (TyData { tcdND = NewType, tcdCtxt = cxt, 
		   tcdName = tc, tcdTyVars = tvs, 
		   tcdCons = DataCons [con], tcdDerivs = mb_derivs,
           tcdLoc = loc}) 
 = do { tc1 <- lookupOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
      	       cxt1   <- repContext cxt ;
               con1   <- repC con ;
      	       derivs1 <- repDerivs mb_derivs ;
      	       repNewtype cxt1 tc1 (coreList' stringTy bndrs) con1 derivs1 } ;
        return $ Just (loc, dec) }

repTyClD' (TySynonym { tcdName = tc, tcdTyVars = tvs, tcdSynRhs = ty,
           tcdLoc = loc})
 = do { tc1 <- lookupOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
	       ty1 <- repTy ty ;
	       repTySyn tc1 (coreList' stringTy bndrs) ty1 } ;
 	return (Just (loc, dec)) }

repTyClD' (ClassDecl { tcdCtxt = cxt, tcdName = cls, 
		      tcdTyVars = tvs, 
		      tcdFDs = [], 	-- We don't understand functional dependencies
		      tcdSigs = sigs, tcdMeths = mb_meth_binds,
              tcdLoc = loc})
 = do { cls1 <- lookupOcc cls ;		-- See note [Binders and occurrences] 
    	dec  <- addTyVarBinds tvs $ \bndrs -> do {
 		  cxt1   <- repContext cxt ;
 		  sigs1  <- rep_sigs sigs ;
 		  binds1 <- rep_monobind meth_binds ;
 		  decls1 <- coreList declTyConName (sigs1 ++ binds1) ;
 		  repClass cxt1 cls1 (coreList' stringTy bndrs) decls1 } ;
    	return $ Just (loc, dec) }
 where
	-- If the user quotes a class decl, it'll have default-method 
	-- bindings; but if we (reifyDecl C) where C is a class, we
	-- won't be given the default methods (a definite infelicity).
   meth_binds = mb_meth_binds `orElse` EmptyMonoBinds

-- Un-handled cases
repTyClD' d = do { addDsWarn (hang msg 4 (ppr d)) ;
	          return Nothing
	     }
  where
    msg = ptext SLIT("Cannot desugar this Template Haskell declaration:")

repInstD' (InstDecl ty binds _ _ loc)
	-- Ignore user pragmas for now
 = do { cxt1 <- repContext cxt ;
	inst_ty1 <- repPred (HsClassP cls tys) ;
	binds1 <- rep_monobind binds ;
	decls1 <- coreList declTyConName binds1 ;
	i <- repInst cxt1 inst_ty1 decls1;
    return (loc, i)}
 where
   (tvs, cxt, cls, tys) = splitHsInstDeclTy ty


-------------------------------------------------------
-- 			Constructors
-------------------------------------------------------

repC :: ConDecl Name -> DsM (Core M.ConQ)
repC (ConDecl con [] [] details loc)
  = do { con1     <- lookupOcc con ;		-- See note [Binders and occurrences] 
	 repConstr con1 details }

repBangTy :: BangType Name -> DsM (Core (M.StrictTypQ))
repBangTy (BangType str ty) = do MkC s <- rep2 strName []
                                 MkC t <- repTy ty
                                 rep2 strictTypeName [s, t]
    where strName = case str of
                        NotMarkedStrict -> nonstrictName
                        _ -> strictName

-------------------------------------------------------
-- 			Deriving clause
-------------------------------------------------------

repDerivs :: Maybe (HsContext Name) -> DsM (Core [String])
repDerivs Nothing = return (coreList' stringTy [])
repDerivs (Just ctxt)
  = do { strs <- mapM rep_deriv ctxt ; 
	 return (coreList' stringTy strs) }
  where
    rep_deriv :: HsPred Name -> DsM (Core String)
	-- Deriving clauses must have the simple H98 form
    rep_deriv (HsClassP cls []) = lookupOcc cls
    rep_deriv other		= panic "rep_deriv"


-------------------------------------------------------
--   Signatures in a class decl, or a group of bindings
-------------------------------------------------------

rep_sigs :: [Sig Name] -> DsM [Core M.DecQ]
rep_sigs sigs = do locs_cores <- rep_sigs' sigs
                   return $ de_loc $ sort_by_loc locs_cores

rep_sigs' :: [Sig Name] -> DsM [(SrcLoc, Core M.DecQ)]
	-- We silently ignore ones we don't recognise
rep_sigs' sigs = do { sigs1 <- mapM rep_sig sigs ;
		     return (concat sigs1) }

rep_sig :: Sig Name -> DsM [(SrcLoc, Core M.DecQ)]
	-- Singleton => Ok
	-- Empty     => Too hard, signature ignored
rep_sig (ClassOpSig nm _ ty loc) = rep_proto nm ty loc
rep_sig (Sig nm ty loc)	       = rep_proto nm ty loc
rep_sig other		       = return []

rep_proto :: Name -> HsType Name -> SrcLoc -> DsM [(SrcLoc, Core M.DecQ)]
rep_proto nm ty loc = do { nm1 <- lookupOcc nm ; 
		       ty1 <- repTy ty ; 
		       sig <- repProto nm1 ty1 ;
		       return [(loc, sig)] }


-------------------------------------------------------
-- 			Types
-------------------------------------------------------

-- gensym a list of type variables and enter them into the meta environment;
-- the computations passed as the second argument is executed in that extended
-- meta environment and gets the *new* names on Core-level as an argument
--
addTyVarBinds :: [HsTyVarBndr Name]	         -- the binders to be added
	      -> ([Core String] -> DsM (Core (M.Q a))) -- action in the ext env
	      -> DsM (Core (M.Q a))
addTyVarBinds tvs m =
  do
    let names = map hsTyVarName tvs
    freshNames <- mkGenSyms names
    term       <- addBinds freshNames $ do
		    bndrs <- mapM lookupBinder names 
		    m bndrs
    wrapGenSyns freshNames term

-- represent a type context
--
repContext :: HsContext Name -> DsM (Core M.CxtQ)
repContext ctxt = do 
	            preds    <- mapM repPred ctxt
		    predList <- coreList typeTyConName preds
		    repCtxt predList

-- represent a type predicate
--
repPred :: HsPred Name -> DsM (Core M.TypQ)
repPred (HsClassP cls tys) = do
			       tcon <- repTy (HsTyVar cls)
			       tys1 <- repTys tys
			       repTapps tcon tys1
repPred (HsIParam _ _)     = 
  panic "DsMeta.repTy: Can't represent predicates with implicit parameters"

-- yield the representation of a list of types
--
repTys :: [HsType Name] -> DsM [Core M.TypQ]
repTys tys = mapM repTy tys

-- represent a type
--
repTy :: HsType Name -> DsM (Core M.TypQ)
repTy (HsForAllTy bndrs ctxt ty)  = 
  addTyVarBinds (fromMaybe [] bndrs) $ \bndrs' -> do
    ctxt'  <- repContext ctxt
    ty'    <- repTy ty
    repTForall (coreList' stringTy bndrs') ctxt' ty'

repTy (HsTyVar n)
  | isTvOcc (nameOccName n)       = do 
				      tv1 <- lookupBinder n
				      repTvar tv1
  | otherwise		          = do 
				      tc1 <- lookupOcc n
				      repNamedTyCon tc1
repTy (HsAppTy f a)               = do 
				      f1 <- repTy f
				      a1 <- repTy a
				      repTapp f1 a1
repTy (HsFunTy f a)               = do 
				      f1   <- repTy f
				      a1   <- repTy a
				      tcon <- repArrowTyCon
				      repTapps tcon [f1, a1]
repTy (HsListTy t)		  = do
				      t1   <- repTy t
				      tcon <- repListTyCon
				      repTapp tcon t1
repTy (HsPArrTy t)                = do
				      t1   <- repTy t
				      tcon <- repTy (HsTyVar parrTyConName)
				      repTapp tcon t1
repTy (HsTupleTy tc tys)	  = do
				      tys1 <- repTys tys 
				      tcon <- repTupleTyCon (length tys)
				      repTapps tcon tys1
repTy (HsOpTy ty1 HsArrow ty2) 	  = repTy (HsFunTy ty1 ty2)
repTy (HsOpTy ty1 (HsTyOp n) ty2) = repTy ((HsTyVar n `HsAppTy` ty1) 
					   `HsAppTy` ty2)
repTy (HsParTy t)  	       	  = repTy t
repTy (HsNumTy i)                 =
  panic "DsMeta.repTy: Can't represent number types (for generics)"
repTy (HsPredTy pred)             = repPred pred
repTy (HsKindSig ty kind)	  = 
  panic "DsMeta.repTy: Can't represent explicit kind signatures yet"


-----------------------------------------------------------------------------
-- 		Expressions
-----------------------------------------------------------------------------

repEs :: [HsExpr Name] -> DsM (Core [M.ExpQ])
repEs es = do { es'  <- mapM repE es ;
		coreList exprTyConName es' }

-- FIXME: some of these panics should be converted into proper error messages
--	  unless we can make sure that constructs, which are plainly not
--	  supported in TH already lead to error messages at an earlier stage
repE :: HsExpr Name -> DsM (Core M.ExpQ)
repE (HsVar x)            =
  do { mb_val <- dsLookupMetaEnv x 
     ; case mb_val of
	Nothing	         -> do { str <- globalVar x
			       ; repVarOrCon x str }
	Just (Bound y)   -> repVarOrCon x (coreVar y)
	Just (Splice e)  -> do { e' <- dsExpr e
			       ; return (MkC e') } }
repE (HsIPVar x) = panic "DsMeta.repE: Can't represent implicit parameters"

	-- Remember, we're desugaring renamer output here, so
	-- HsOverlit can definitely occur
repE (HsOverLit l) = do { a <- repOverloadedLiteral l; repLit a }
repE (HsLit l)     = do { a <- repLiteral l;           repLit a }
repE (HsLam m)     = repLambda m
repE (HsApp x y)   = do {a <- repE x; b <- repE y; repApp a b}

repE (OpApp e1 op fix e2) =
  do { arg1 <- repE e1; 
       arg2 <- repE e2; 
       the_op <- repE op ;
       repInfixApp arg1 the_op arg2 } 
repE (NegApp x nm)        = do
			      a         <- repE x
			      negateVar <- lookupOcc negateName >>= repVar
			      negateVar `repApp` a
repE (HsPar x)            = repE x
repE (SectionL x y)       = do { a <- repE x; b <- repE y; repSectionL a b } 
repE (SectionR x y)       = do { a <- repE x; b <- repE y; repSectionR a b } 
repE (HsCase e ms loc)    = do { arg <- repE e
			       ; ms2 <- mapM repMatchTup ms
			       ; repCaseE arg (nonEmptyCoreList ms2) }
repE (HsIf x y z loc)     = do
			      a <- repE x
			      b <- repE y
			      c <- repE z
			      repCond a b c
repE (HsLet bs e)         = do { (ss,ds) <- repBinds bs
			       ; e2 <- addBinds ss (repE e)
			       ; z <- repLetE ds e2
			       ; wrapGenSyns ss z }
-- FIXME: I haven't got the types here right yet
repE (HsDo DoExpr sts _ ty loc) 
 = do { (ss,zs) <- repSts sts; 
        e       <- repDoE (nonEmptyCoreList zs);
        wrapGenSyns ss e }
repE (HsDo ListComp sts _ ty loc) 
 = do { (ss,zs) <- repSts sts; 
        e       <- repComp (nonEmptyCoreList zs);
        wrapGenSyns ss e }
repE (HsDo _ _ _ _ _) = panic "DsMeta.repE: Can't represent mdo and [: :] yet"
repE (ExplicitList ty es) = do { xs <- repEs es; repListExp xs } 
repE (ExplicitPArr ty es) = 
  panic "DsMeta.repE: No explicit parallel arrays yet"
repE (ExplicitTuple es boxed) 
  | isBoxed boxed         = do { xs <- repEs es; repTup xs }
  | otherwise		  = panic "DsMeta.repE: Can't represent unboxed tuples"
repE (RecordCon c flds)
 = do { x <- lookupOcc c;
        fs <- repFields flds;
        repRecCon x fs }
repE (RecordUpd e flds)
 = do { x <- repE e;
        fs <- repFields flds;
        repRecUpd x fs }

repE (ExprWithTySig e ty) = do { e1 <- repE e; t1 <- repTy ty; repSigExp e1 t1 }
repE (ArithSeqIn aseq) =
  case aseq of
    From e              -> do { ds1 <- repE e; repFrom ds1 }
    FromThen e1 e2      -> do 
		             ds1 <- repE e1
			     ds2 <- repE e2
			     repFromThen ds1 ds2
    FromTo   e1 e2      -> do 
			     ds1 <- repE e1
			     ds2 <- repE e2
			     repFromTo ds1 ds2
    FromThenTo e1 e2 e3 -> do 
			     ds1 <- repE e1
			     ds2 <- repE e2
			     ds3 <- repE e3
			     repFromThenTo ds1 ds2 ds3
repE (PArrSeqOut _ aseq)  = panic "DsMeta.repE: parallel array seq.s missing"
repE (HsCoreAnn _ _)      = panic "DsMeta.repE: Can't represent CoreAnn" -- hdaume: core annotations
repE (HsCCall _ _ _ _ _)  = panic "DsMeta.repE: Can't represent __ccall__"
repE (HsSCC _ _)          = panic "DsMeta.repE: Can't represent SCC"
repE (HsBracketOut _ _)   = 
  panic "DsMeta.repE: Can't represent Oxford brackets"
repE (HsSplice n e loc)   = do { mb_val <- dsLookupMetaEnv n
			       ; case mb_val of
				 Just (Splice e) -> do { e' <- dsExpr e
						       ; return (MkC e') }
				 other	     -> pprPanic "HsSplice" (ppr n) }
repE (HsReify _)          = panic "DsMeta.repE: Can't represent reification"
repE e                    = 
  pprPanic "DsMeta.repE: Illegal expression form" (ppr e)

-----------------------------------------------------------------------------
-- Building representations of auxillary structures like Match, Clause, Stmt, 

repMatchTup ::  Match Name -> DsM (Core M.MatchQ) 
repMatchTup (Match [p] ty (GRHSs guards wheres ty2)) = 
  do { ss1 <- mkGenSyms (collectPatBinders p) 
     ; addBinds ss1 $ do {
     ; p1 <- repP p
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
     ; gs    <- repGuards guards
     ; match <- repMatch p1 gs ds
     ; wrapGenSyns (ss1++ss2) match }}}

repClauseTup ::  Match Name -> DsM (Core M.ClauseQ)
repClauseTup (Match ps ty (GRHSs guards wheres ty2)) = 
  do { ss1 <- mkGenSyms (collectPatsBinders ps) 
     ; addBinds ss1 $ do {
       ps1 <- repPs ps
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
       gs <- repGuards guards
     ; clause <- repClause ps1 gs ds
     ; wrapGenSyns (ss1++ss2) clause }}}

repGuards ::  [GRHS Name] ->  DsM (Core M.RHSQ)
repGuards [GRHS [ResultStmt e loc] loc2] 
  = do {a <- repE e; repNormal a }
repGuards other 
  = do { zs <- mapM process other; 
	 repGuarded (nonEmptyCoreList (map corePair zs)) }
  where 
    process (GRHS [ExprStmt e1 ty loc,ResultStmt e2 _] _)
           = do { x <- repE e1; y <- repE e2; return (x, y) }
    process other = panic "Non Haskell 98 guarded body"

repFields :: [(Name,HsExpr Name)] -> DsM (Core [M.FieldExp])
repFields flds = do
        fnames <- mapM lookupOcc (map fst flds)
        es <- mapM repE (map snd flds)
        fs <- zipWithM (\n x -> rep2 fieldName [unC n, unC x]) fnames es
        coreList fieldTyConName fs


-----------------------------------------------------------------------------
-- Representing Stmt's is tricky, especially if bound variables
-- shaddow each other. Consider:  [| do { x <- f 1; x <- f x; g x } |]
-- First gensym new names for every variable in any of the patterns.
-- both static (x'1 and x'2), and dynamic ((gensym "x") and (gensym "y"))
-- if variables didn't shaddow, the static gensym wouldn't be necessary
-- and we could reuse the original names (x and x).
--
-- do { x'1 <- gensym "x"
--    ; x'2 <- gensym "x"   
--    ; doE [ BindSt (pvar x'1) [| f 1 |]
--          , BindSt (pvar x'2) [| f x |] 
--          , NoBindSt [| g x |] 
--          ]
--    }

-- The strategy is to translate a whole list of do-bindings by building a
-- bigger environment, and a bigger set of meta bindings 
-- (like:  x'1 <- gensym "x" ) and then combining these with the translations
-- of the expressions within the Do
      
-----------------------------------------------------------------------------
-- The helper function repSts computes the translation of each sub expression
-- and a bunch of prefix bindings denoting the dynamic renaming.

repSts :: [Stmt Name] -> DsM ([GenSymBind], [Core M.StmtQ])
repSts [ResultStmt e loc] = 
   do { a <- repE e
      ; e1 <- repNoBindSt a
      ; return ([], [e1]) }
repSts (BindStmt p e loc : ss) =
   do { e2 <- repE e 
      ; ss1 <- mkGenSyms (collectPatBinders p) 
      ; addBinds ss1 $ do {
      ; p1 <- repP p; 
      ; (ss2,zs) <- repSts ss
      ; z <- repBindSt p1 e2
      ; return (ss1++ss2, z : zs) }}
repSts (LetStmt bs : ss) =
   do { (ss1,ds) <- repBinds bs
      ; z <- repLetSt ds
      ; (ss2,zs) <- addBinds ss1 (repSts ss)
      ; return (ss1++ss2, z : zs) } 
repSts (ExprStmt e ty loc : ss) =       
   do { e2 <- repE e
      ; z <- repNoBindSt e2 
      ; (ss2,zs) <- repSts ss
      ; return (ss2, z : zs) }
repSts other = panic "Exotic Stmt in meta brackets"      


-----------------------------------------------------------
--			Bindings
-----------------------------------------------------------

repBinds :: HsBinds Name -> DsM ([GenSymBind], Core [M.DecQ]) 
repBinds decs
 = do { let { bndrs = collectHsBinders decs } ;
	ss	  <- mkGenSyms bndrs ;
	core      <- addBinds ss (rep_binds decs) ;
	core_list <- coreList declTyConName core ;
	return (ss, core_list) }

rep_binds :: HsBinds Name -> DsM [Core M.DecQ]
rep_binds binds = do locs_cores <- rep_binds' binds
                     return $ de_loc $ sort_by_loc locs_cores

rep_binds' :: HsBinds Name -> DsM [(SrcLoc, Core M.DecQ)]
rep_binds' EmptyBinds = return []
rep_binds' (ThenBinds x y)
 = do { core1 <- rep_binds' x
      ; core2 <- rep_binds' y
      ; return (core1 ++ core2) }
rep_binds' (MonoBind bs sigs _)
 = do { core1 <- rep_monobind' bs
      ;	core2 <- rep_sigs' sigs
      ;	return (core1 ++ core2) }
rep_binds' (IPBinds _ _)
  = panic "DsMeta:repBinds: can't do implicit parameters"

rep_monobind :: MonoBinds Name -> DsM [Core M.DecQ]
rep_monobind binds = do locs_cores <- rep_monobind' binds
                        return $ de_loc $ sort_by_loc locs_cores

rep_monobind' :: MonoBinds Name -> DsM [(SrcLoc, Core M.DecQ)]
rep_monobind' EmptyMonoBinds     = return []
rep_monobind' (AndMonoBinds x y) = do { x1 <- rep_monobind' x; 
				       y1 <- rep_monobind' y; 
				       return (x1 ++ y1) }

-- Note GHC treats declarations of a variable (not a pattern) 
-- e.g.  x = g 5 as a Fun MonoBinds. This is indicated by a single match 
-- with an empty list of patterns
rep_monobind' (FunMonoBind fn infx [Match [] ty (GRHSs guards wheres ty2)] loc) 
 = do { (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
	; fn' <- lookupBinder fn
	; p   <- repPvar fn'
	; ans <- repVal p guardcore wherecore
	; return [(loc, ans)] }

rep_monobind' (FunMonoBind fn infx ms loc)
 =   do { ms1 <- mapM repClauseTup ms
	; fn' <- lookupBinder fn
        ; ans <- repFun fn' (nonEmptyCoreList ms1)
        ; return [(loc, ans)] }

rep_monobind' (PatMonoBind pat (GRHSs guards wheres ty2) loc)
 =   do { patcore <- repP pat 
        ; (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
        ; ans <- repVal patcore guardcore wherecore
        ; return [(loc, ans)] }

rep_monobind' (VarMonoBind v e)  
 =   do { v' <- lookupBinder v 
	; e2 <- repE e
        ; x <- repNormal e2
        ; patcore <- repPvar v'
	; empty_decls <- coreList declTyConName [] 
        ; ans <- repVal patcore x empty_decls
        ; return [(getSrcLoc v, ans)] }

-----------------------------------------------------------------------------
-- Since everything in a MonoBind is mutually recursive we need rename all
-- all the variables simultaneously. For example: 
-- [| AndMonoBinds (f x = x + g 2) (g x = f 1 + 2) |] would translate to
-- do { f'1 <- gensym "f"
--    ; g'2 <- gensym "g"
--    ; [ do { x'3 <- gensym "x"; fun f'1 [pvar x'3] [| x + g2 |]},
--        do { x'4 <- gensym "x"; fun g'2 [pvar x'4] [| f 1 + 2 |]}
--      ]}
-- This requires collecting the bindings (f'1 <- gensym "f"), and the 
-- environment ( f |-> f'1 ) from each binding, and then unioning them 
-- together. As we do this we collect GenSymBinds's which represent the renamed 
-- variables bound by the Bindings. In order not to lose track of these 
-- representations we build a shadow datatype MB with the same structure as 
-- MonoBinds, but which has slots for the representations


-----------------------------------------------------------------------------
-- GHC allows a more general form of lambda abstraction than specified
-- by Haskell 98. In particular it allows guarded lambda's like : 
-- (\  x | even x -> 0 | odd x -> 1) at the moment we can't represent this in
-- Haskell Template's Meta.Exp type so we punt if it isn't a simple thing like
-- (\ p1 .. pn -> exp) by causing an error.  

repLambda :: Match Name -> DsM (Core M.ExpQ)
repLambda (Match ps _ (GRHSs [GRHS [ResultStmt e _ ] _ ] 
		             EmptyBinds _))
 = do { let bndrs = collectPatsBinders ps ;
      ; ss <- mkGenSyms bndrs
      ; lam <- addBinds ss (
		do { xs <- repPs ps; body <- repE e; repLam xs body })
      ; wrapGenSyns ss lam }

repLambda z = panic "Can't represent a guarded lambda in Template Haskell"  

  
-----------------------------------------------------------------------------
--			Patterns
-- repP deals with patterns.  It assumes that we have already
-- walked over the pattern(s) once to collect the binders, and 
-- have extended the environment.  So every pattern-bound 
-- variable should already appear in the environment.

-- Process a list of patterns
repPs :: [Pat Name] -> DsM (Core [M.Pat])
repPs ps = do { ps' <- mapM repP ps ;
		coreList pattTyConName ps' }

repP :: Pat Name -> DsM (Core M.Pat)
repP (WildPat _)     = repPwild 
repP (LitPat l)      = do { l2 <- repLiteral l; repPlit l2 }
repP (VarPat x)      = do { x' <- lookupBinder x; repPvar x' }
repP (LazyPat p)     = do { p1 <- repP p; repPtilde p1 }
repP (AsPat x p)     = do { x' <- lookupBinder x; p1 <- repP p; repPaspat x' p1 }
repP (ParPat p)      = repP p 
repP (ListPat ps _)  = repListPat ps
repP (TuplePat ps _) = do { qs <- repPs ps; repPtup qs }
repP (ConPatIn dc details)
 = do { con_str <- lookupOcc dc
      ; case details of
         PrefixCon ps   -> do { qs <- repPs ps; repPcon con_str qs }
         RecCon pairs -> do { vs <- sequence $ map lookupOcc (map fst pairs)
                            ; ps <- sequence $ map repP (map snd pairs)
                            ; fps <- zipWithM (\x y -> rep2 fieldPName [unC x,unC y]) vs ps
                            ; fps' <- coreList fieldPTyConName fps
                            ; repPrec con_str fps' }
         InfixCon p1 p2 -> do { qs <- repPs [p1,p2]; repPcon con_str qs }
   }
repP (NPatIn l (Just _)) = panic "Can't cope with negative overloaded patterns yet (repP (NPatIn _ (Just _)))"
repP (NPatIn l Nothing) = do { a <- repOverloadedLiteral l; repPlit a }
repP other = panic "Exotic pattern inside meta brackets"

repListPat :: [Pat Name] -> DsM (Core M.Pat)     
repListPat [] 	  = do { nil_con <- coreStringLit "[]"
		       ; nil_args <- coreList pattTyConName [] 
	               ; repPcon nil_con nil_args }
repListPat (p:ps) = do { p2 <- repP p 
		       ; ps2 <- repListPat ps
		       ; cons_con <- coreStringLit ":"
		       ; repPcon cons_con (nonEmptyCoreList [p2,ps2]) }


----------------------------------------------------------
-- Declaration ordering helpers

sort_by_loc :: [(SrcLoc, a)] -> [(SrcLoc, a)]
sort_by_loc xs = sortBy comp xs
    where comp x y = compare (fst x) (fst y)

de_loc :: [(SrcLoc, a)] -> [a]
de_loc = map snd

----------------------------------------------------------
--	The meta-environment

-- A name/identifier association for fresh names of locally bound entities
--
type GenSymBind = (Name, Id)	-- Gensym the string and bind it to the Id
				-- I.e.		(x, x_id) means
				--	let x_id = gensym "x" in ...

-- Generate a fresh name for a locally bound entity
--
mkGenSym :: Name -> DsM GenSymBind
mkGenSym nm = do { id <- newUniqueId nm stringTy; return (nm,id) }

-- Ditto for a list of names
--
mkGenSyms :: [Name] -> DsM [GenSymBind]
mkGenSyms ns = mapM mkGenSym ns
	     
-- Add a list of fresh names for locally bound entities to the meta
-- environment (which is part of the state carried around by the desugarer
-- monad) 
--
addBinds :: [GenSymBind] -> DsM a -> DsM a
addBinds bs m = dsExtendMetaEnv (mkNameEnv [(n,Bound id) | (n,id) <- bs]) m

-- Look up a locally bound name
--
lookupBinder :: Name -> DsM (Core String)
lookupBinder n 
  = do { mb_val <- dsLookupMetaEnv n;
	 case mb_val of
	    Just (Bound x) -> return (coreVar x)
	    other	   -> pprPanic "Failed binder lookup:" (ppr n) }

-- Look up a name that is either locally bound or a global name
--
-- * If it is a global name, generate the "original name" representation (ie,
--   the <module>:<name> form) for the associated entity
--
lookupOcc :: Name -> DsM (Core String)
-- Lookup an occurrence; it can't be a splice.
-- Use the in-scope bindings if they exist
lookupOcc n
  = do {  mb_val <- dsLookupMetaEnv n ;
          case mb_val of
		Nothing         -> globalVar n
		Just (Bound x)  -> return (coreVar x)
		Just (Splice _) -> pprPanic "repE:lookupOcc" (ppr n) 
    }

globalVar :: Name -> DsM (Core String)
globalVar n = coreStringLit (name_mod ++ ":" ++ name_occ)
 	    where
	      name_mod = moduleUserString (nameModule n)
	      name_occ = occNameUserString (nameOccName n)

localVar :: Name -> DsM (Core String)
localVar n = coreStringLit (occNameUserString (nameOccName n))

lookupType :: Name 	-- Name of type constructor (e.g. M.ExpQ)
	   -> DsM Type	-- The type
lookupType tc_name = do { tc <- dsLookupTyCon tc_name ;
		          return (mkGenTyConApp tc []) }

-- wrapGenSyns [(nm1,id1), (nm2,id2)] y 
--	--> bindQ (gensym nm1) (\ id1 -> 
--	    bindQ (gensym nm2 (\ id2 -> 
--	    y))

wrapGenSyns :: [GenSymBind] 
	    -> Core (M.Q a) -> DsM (Core (M.Q a))
wrapGenSyns binds body@(MkC b)
  = go binds
  where
    [elt_ty] = tcTyConAppArgs (exprType b) 
	-- b :: Q a, so we can get the type 'a' by looking at the
	-- argument type. NB: this relies on Q being a data/newtype,
	-- not a type synonym

    go [] = return body
    go ((name,id) : binds)
      = do { MkC body'  <- go binds
	   ; lit_str    <- localVar name
	   ; gensym_app <- repGensym lit_str
	   ; repBindQ stringTy elt_ty 
		      gensym_app (MkC (Lam id body')) }

-- Just like wrapGenSym, but don't actually do the gensym
-- Instead use the existing name
-- Only used for [Decl]
wrapNongenSyms :: [GenSymBind] -> Core a -> DsM (Core a)
wrapNongenSyms binds (MkC body)
  = do { binds' <- mapM do_one binds ;
	 return (MkC (mkLets binds' body)) }
  where
    do_one (name,id) 
	= do { MkC lit_str <- localVar name	-- No gensym
	     ; return (NonRec id lit_str) }

void = placeHolderType

string :: String -> HsExpr Id
string s = HsLit (HsString (mkFastString s))


-- %*********************************************************************
-- %*									*
--		Constructing code
-- %*									*
-- %*********************************************************************

-----------------------------------------------------------------------------
-- PHANTOM TYPES for consistency. In order to make sure we do this correct 
-- we invent a new datatype which uses phantom types.

newtype Core a = MkC CoreExpr
unC (MkC x) = x

rep2 :: Name -> [ CoreExpr ] -> DsM (Core a)
rep2 n xs = do { id <- dsLookupGlobalId n
               ; return (MkC (foldl App (Var id) xs)) }

-- Then we make "repConstructors" which use the phantom types for each of the
-- smart constructors of the Meta.Meta datatypes.


-- %*********************************************************************
-- %*									*
--		The 'smart constructors'
-- %*									*
-- %*********************************************************************

--------------- Patterns -----------------
repPlit   :: Core M.Lit -> DsM (Core M.Pat) 
repPlit (MkC l) = rep2 plitName [l]

repPvar :: Core String -> DsM (Core M.Pat)
repPvar (MkC s) = rep2 pvarName [s]

repPtup :: Core [M.Pat] -> DsM (Core M.Pat)
repPtup (MkC ps) = rep2 ptupName [ps]

repPcon   :: Core String -> Core [M.Pat] -> DsM (Core M.Pat)
repPcon (MkC s) (MkC ps) = rep2 pconName [s, ps]

repPrec   :: Core String -> Core [(String,M.Pat)] -> DsM (Core M.Pat)
repPrec (MkC c) (MkC rps) = rep2 precName [c,rps]

repPtilde :: Core M.Pat -> DsM (Core M.Pat)
repPtilde (MkC p) = rep2 ptildeName [p]

repPaspat :: Core String -> Core M.Pat -> DsM (Core M.Pat)
repPaspat (MkC s) (MkC p) = rep2 paspatName [s, p]

repPwild  :: DsM (Core M.Pat)
repPwild = rep2 pwildName []

--------------- Expressions -----------------
repVarOrCon :: Name -> Core String -> DsM (Core M.ExpQ)
repVarOrCon vc str | isDataOcc (nameOccName vc) = repCon str
	           | otherwise 		        = repVar str

repVar :: Core String -> DsM (Core M.ExpQ)
repVar (MkC s) = rep2 varName [s] 

repCon :: Core String -> DsM (Core M.ExpQ)
repCon (MkC s) = rep2 conName [s] 

repLit :: Core M.Lit -> DsM (Core M.ExpQ)
repLit (MkC c) = rep2 litName [c] 

repApp :: Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repApp (MkC x) (MkC y) = rep2 appName [x,y] 

repLam :: Core [M.Pat] -> Core M.ExpQ -> DsM (Core M.ExpQ)
repLam (MkC ps) (MkC e) = rep2 lamName [ps, e]

repTup :: Core [M.ExpQ] -> DsM (Core M.ExpQ)
repTup (MkC es) = rep2 tupName [es]

repCond :: Core M.ExpQ -> Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repCond (MkC x) (MkC y) (MkC z) =  rep2 condName [x,y,z] 

repLetE :: Core [M.DecQ] -> Core M.ExpQ -> DsM (Core M.ExpQ)
repLetE (MkC ds) (MkC e) = rep2 letEName [ds, e] 

repCaseE :: Core M.ExpQ -> Core [M.MatchQ] -> DsM( Core M.ExpQ)
repCaseE (MkC e) (MkC ms) = rep2 caseEName [e, ms]

repDoE :: Core [M.StmtQ] -> DsM (Core M.ExpQ)
repDoE (MkC ss) = rep2 doEName [ss]

repComp :: Core [M.StmtQ] -> DsM (Core M.ExpQ)
repComp (MkC ss) = rep2 compName [ss]

repListExp :: Core [M.ExpQ] -> DsM (Core M.ExpQ)
repListExp (MkC es) = rep2 listExpName [es]

repSigExp :: Core M.ExpQ -> Core M.TypQ -> DsM (Core M.ExpQ)
repSigExp (MkC e) (MkC t) = rep2 sigExpName [e,t]

repRecCon :: Core String -> Core [M.FieldExp]-> DsM (Core M.ExpQ)
repRecCon (MkC c) (MkC fs) = rep2 recConName [c,fs]

repRecUpd :: Core M.ExpQ -> Core [M.FieldExp] -> DsM (Core M.ExpQ)
repRecUpd (MkC e) (MkC fs) = rep2 recUpdName [e,fs]

repInfixApp :: Core M.ExpQ -> Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repInfixApp (MkC x) (MkC y) (MkC z) = rep2 infixAppName [x,y,z]

repSectionL :: Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repSectionL (MkC x) (MkC y) = rep2 sectionLName [x,y]

repSectionR :: Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repSectionR (MkC x) (MkC y) = rep2 sectionRName [x,y]

------------ Right hand sides (guarded expressions) ----
repGuarded :: Core [(M.ExpQ, M.ExpQ)] -> DsM (Core M.RHSQ)
repGuarded (MkC pairs) = rep2 guardedName [pairs]

repNormal :: Core M.ExpQ -> DsM (Core M.RHSQ)
repNormal (MkC e) = rep2 normalName [e]

------------- Stmts -------------------
repBindSt :: Core M.Pat -> Core M.ExpQ -> DsM (Core M.StmtQ)
repBindSt (MkC p) (MkC e) = rep2 bindStName [p,e]

repLetSt :: Core [M.DecQ] -> DsM (Core M.StmtQ)
repLetSt (MkC ds) = rep2 letStName [ds]

repNoBindSt :: Core M.ExpQ -> DsM (Core M.StmtQ)
repNoBindSt (MkC e) = rep2 noBindStName [e]

-------------- DotDot (Arithmetic sequences) -----------
repFrom :: Core M.ExpQ -> DsM (Core M.ExpQ)
repFrom (MkC x) = rep2 fromName [x]

repFromThen :: Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repFromThen (MkC x) (MkC y) = rep2 fromThenName [x,y]

repFromTo :: Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repFromTo (MkC x) (MkC y) = rep2 fromToName [x,y]

repFromThenTo :: Core M.ExpQ -> Core M.ExpQ -> Core M.ExpQ -> DsM (Core M.ExpQ)
repFromThenTo (MkC x) (MkC y) (MkC z) = rep2 fromThenToName [x,y,z]

------------ Match and Clause Tuples -----------
repMatch :: Core M.Pat -> Core M.RHSQ -> Core [M.DecQ] -> DsM (Core M.MatchQ)
repMatch (MkC p) (MkC bod) (MkC ds) = rep2 matchName [p, bod, ds]

repClause :: Core [M.Pat] -> Core M.RHSQ -> Core [M.DecQ] -> DsM (Core M.ClauseQ)
repClause (MkC ps) (MkC bod) (MkC ds) = rep2 clauseName [ps, bod, ds]

-------------- Dec -----------------------------
repVal :: Core M.Pat -> Core M.RHSQ -> Core [M.DecQ] -> DsM (Core M.DecQ)
repVal (MkC p) (MkC b) (MkC ds) = rep2 valName [p, b, ds]

repFun :: Core String -> Core [M.ClauseQ] -> DsM (Core M.DecQ)  
repFun (MkC nm) (MkC b) = rep2 funName [nm, b]

repData :: Core M.CxtQ -> Core String -> Core [String] -> Core [M.ConQ] -> Core [String] -> DsM (Core M.DecQ)
repData (MkC cxt) (MkC nm) (MkC tvs) (MkC cons) (MkC derivs) = rep2 dataDName [cxt, nm, tvs, cons, derivs]

repNewtype :: Core M.CxtQ -> Core String -> Core [String] -> Core M.ConQ -> Core [String] -> DsM (Core M.DecQ)
repNewtype (MkC cxt) (MkC nm) (MkC tvs) (MkC con) (MkC derivs) = rep2 newtypeDName [cxt, nm, tvs, con, derivs]

repTySyn :: Core String -> Core [String] -> Core M.TypQ -> DsM (Core M.DecQ)
repTySyn (MkC nm) (MkC tvs) (MkC rhs) = rep2 tySynDName [nm, tvs, rhs]

repInst :: Core M.CxtQ -> Core M.TypQ -> Core [M.DecQ] -> DsM (Core M.DecQ)
repInst (MkC cxt) (MkC ty) (MkC ds) = rep2 instName [cxt, ty, ds]

repClass :: Core M.CxtQ -> Core String -> Core [String] -> Core [M.DecQ] -> DsM (Core M.DecQ)
repClass (MkC cxt) (MkC cls) (MkC tvs) (MkC ds) = rep2 classDName [cxt, cls, tvs, ds]

repProto :: Core String -> Core M.TypQ -> DsM (Core M.DecQ)
repProto (MkC s) (MkC ty) = rep2 protoName [s, ty]

repCtxt :: Core [M.TypQ] -> DsM (Core M.CxtQ)
repCtxt (MkC tys) = rep2 ctxtName [tys]

repConstr :: Core String -> HsConDetails Name (BangType Name)
          -> DsM (Core M.ConQ)
repConstr con (PrefixCon ps)
    = do arg_tys  <- mapM repBangTy ps
         arg_tys1 <- coreList strTypeTyConName arg_tys
         rep2 constrName [unC con, unC arg_tys1]
repConstr con (RecCon ips)
    = do arg_vs   <- mapM lookupOcc (map fst ips)
         arg_tys  <- mapM repBangTy (map snd ips)
         arg_vtys <- zipWithM (\x y -> rep2 varStrictTypeName [unC x, unC y])
                              arg_vs arg_tys
         arg_vtys' <- coreList varStrTypeTyConName arg_vtys
         rep2 recConstrName [unC con, unC arg_vtys']
repConstr con (InfixCon st1 st2)
    = do arg1 <- repBangTy st1
         arg2 <- repBangTy st2
         rep2 infixConstrName [unC arg1, unC con, unC arg2]

------------ Types -------------------

repTForall :: Core [String] -> Core M.CxtQ -> Core M.TypQ -> DsM (Core M.TypQ)
repTForall (MkC tvars) (MkC ctxt) (MkC ty) = rep2 tforallName [tvars, ctxt, ty]

repTvar :: Core String -> DsM (Core M.TypQ)
repTvar (MkC s) = rep2 tvarName [s]

repTapp :: Core M.TypQ -> Core M.TypQ -> DsM (Core M.TypQ)
repTapp (MkC t1) (MkC t2) = rep2 tappName [t1,t2]

repTapps :: Core M.TypQ -> [Core M.TypQ] -> DsM (Core M.TypQ)
repTapps f []     = return f
repTapps f (t:ts) = do { f1 <- repTapp f t; repTapps f1 ts }

--------- Type constructors --------------

repNamedTyCon :: Core String -> DsM (Core M.TypQ)
repNamedTyCon (MkC s) = rep2 namedTyConName [s]

repTupleTyCon :: Int -> DsM (Core M.TypQ)
-- Note: not Core Int; it's easier to be direct here
repTupleTyCon i = rep2 tupleTyConName [mkIntExpr (fromIntegral i)]

repArrowTyCon :: DsM (Core M.TypQ)
repArrowTyCon = rep2 arrowTyConName []

repListTyCon :: DsM (Core M.TypQ)
repListTyCon = rep2 listTyConName []


----------------------------------------------------------
--		Literals

repLiteral :: HsLit -> DsM (Core M.Lit)
repLiteral lit 
  = do lit' <- case lit of
                   HsIntPrim i -> return $ HsInteger i
                   HsInt i -> return $ HsInteger i
                   HsFloatPrim r -> do rat_ty <- lookupType rationalTyConName
                                       return $ HsRat r rat_ty
                   HsDoublePrim r -> do rat_ty <- lookupType rationalTyConName
                                        return $ HsRat r rat_ty
                   _ -> return lit
       lit_expr <- dsLit lit'
       rep2 lit_name [lit_expr]
  where
    lit_name = case lit of
		 HsInteger _    -> integerLName
		 HsInt     _    -> integerLName
		 HsIntPrim _    -> intPrimLName
		 HsFloatPrim _  -> floatPrimLName
		 HsDoublePrim _ -> doublePrimLName
		 HsChar _       -> charLName
		 HsString _     -> stringLName
		 HsRat _ _      -> rationalLName
		 other 	        -> uh_oh
    uh_oh = pprPanic "DsMeta.repLiteral: trying to represent exotic literal"
		    (ppr lit)

repOverloadedLiteral :: HsOverLit -> DsM (Core M.Lit)
repOverloadedLiteral (HsIntegral i _)   = repLiteral (HsInteger i)
repOverloadedLiteral (HsFractional f _) = do { rat_ty <- lookupType rationalTyConName ;
					       repLiteral (HsRat f rat_ty) }
	-- The type Rational will be in the environment, becuase 
	-- the smart constructor 'THSyntax.rationalL' uses it in its type,
	-- and rationalL is sucked in when any TH stuff is used
              
--------------- Miscellaneous -------------------

repLift :: Core e -> DsM (Core M.ExpQ)
repLift (MkC x) = rep2 liftName [x]

repGensym :: Core String -> DsM (Core (M.Q String))
repGensym (MkC lit_str) = rep2 gensymName [lit_str]

repBindQ :: Type -> Type	-- a and b
	 -> Core (M.Q a) -> Core (a -> M.Q b) -> DsM (Core (M.Q b))
repBindQ ty_a ty_b (MkC x) (MkC y) 
  = rep2 bindQName [Type ty_a, Type ty_b, x, y] 

repSequenceQ :: Type -> Core [M.Q a] -> DsM (Core (M.Q [a]))
repSequenceQ ty_a (MkC list)
  = rep2 sequenceQName [Type ty_a, list]

------------ Lists and Tuples -------------------
-- turn a list of patterns into a single pattern matching a list

coreList :: Name	-- Of the TyCon of the element type
	 -> [Core a] -> DsM (Core [a])
coreList tc_name es 
  = do { elt_ty <- lookupType tc_name; return (coreList' elt_ty es) }

coreList' :: Type 	-- The element type
	  -> [Core a] -> Core [a]
coreList' elt_ty es = MkC (mkListExpr elt_ty (map unC es ))

nonEmptyCoreList :: [Core a] -> Core [a]
  -- The list must be non-empty so we can get the element type
  -- Otherwise use coreList
nonEmptyCoreList [] 	      = panic "coreList: empty argument"
nonEmptyCoreList xs@(MkC x:_) = MkC (mkListExpr (exprType x) (map unC xs))

corePair :: (Core a, Core b) -> Core (a,b)
corePair (MkC x, MkC y) = MkC (mkCoreTup [x,y])

coreStringLit :: String -> DsM (Core String)
coreStringLit s = do { z <- mkStringLit s; return(MkC z) }

coreVar :: Id -> Core String	-- The Id has type String
coreVar id = MkC (Var id)



-- %************************************************************************
-- %*									*
--		The known-key names for Template Haskell
-- %*									*
-- %************************************************************************

-- To add a name, do three things
-- 
--  1) Allocate a key
--  2) Make a "Name"
--  3) Add the name to knownKeyNames

templateHaskellNames :: NameSet
-- The names that are implicitly mentioned by ``bracket''
-- Should stay in sync with the import list of DsMeta
templateHaskellNames
  = mkNameSet [ intPrimLName, floatPrimLName, doublePrimLName,
        integerLName, charLName, stringLName, rationalLName,
		plitName, pvarName, ptupName, 
		pconName, ptildeName, paspatName, pwildName, 
                varName, conName, litName, appName, infixEName, lamName,
                tupName, doEName, compName, 
                listExpName, sigExpName, condName, letEName, caseEName,
                infixAppName, sectionLName, sectionRName,
                guardedName, normalName, 
		bindStName, letStName, noBindStName, parStName,
		fromName, fromThenName, fromToName, fromThenToName,
		funName, valName, liftName,
	  	gensymName, returnQName, bindQName, sequenceQName,
		matchName, clauseName, funName, valName, tySynDName, dataDName, newtypeDName, classDName,
		instName, protoName, tforallName, tvarName, tconName, tappName,
		arrowTyConName, tupleTyConName, listTyConName, namedTyConName,
		ctxtName, constrName, recConstrName, infixConstrName,
		exprTyConName, declTyConName, pattTyConName, mtchTyConName, 
		clseTyConName, stmtTyConName, consTyConName, typeTyConName,
        strTypeTyConName, varStrTypeTyConName,
		qTyConName, expTyConName, matTyConName, clsTyConName,
		decTyConName, typTyConName, strictTypeName, varStrictTypeName,
        recConName, recUpdName, precName,
        fieldName, fieldTyConName, fieldPName, fieldPTyConName,
        strictName, nonstrictName ]


varQual  = mk_known_key_name OccName.varName
tcQual   = mk_known_key_name OccName.tcName

thModule :: Module
-- NB: the THSyntax module comes from the "haskell-src" package
thModule = mkThPkgModule mETA_META_Name

mk_known_key_name space str uniq 
  = mkKnownKeyExternalName thModule (mkOccFS space str) uniq 

intPrimLName   = varQual FSLIT("intPrimLit")      intPrimLIdKey
floatPrimLName  = varQual FSLIT("floatPrimLit")   floatPrimLIdKey
doublePrimLName = varQual FSLIT("doublePrimLit")  doublePrimLIdKey
integerLName   = varQual FSLIT("integerLit")      integerLIdKey
charLName      = varQual FSLIT("charLit")         charLIdKey
stringLName    = varQual FSLIT("stringLit")       stringLIdKey
rationalLName  = varQual FSLIT("rationalLit")     rationalLIdKey
plitName       = varQual FSLIT("litPat")          plitIdKey
pvarName       = varQual FSLIT("varPat")          pvarIdKey
ptupName       = varQual FSLIT("tupPat")          ptupIdKey
pconName       = varQual FSLIT("conPat")          pconIdKey
ptildeName     = varQual FSLIT("tildePat")        ptildeIdKey
paspatName     = varQual FSLIT("asPat")        paspatIdKey
pwildName      = varQual FSLIT("wildPat")         pwildIdKey
precName       = varQual FSLIT("recPat")          precIdKey
varName        = varQual FSLIT("varExp")           varIdKey
conName        = varQual FSLIT("conExp")           conIdKey
litName        = varQual FSLIT("litExp")           litIdKey
appName        = varQual FSLIT("appExp")           appIdKey
infixEName     = varQual FSLIT("infixExp")        infixEIdKey
lamName        = varQual FSLIT("lamExp")           lamIdKey
tupName        = varQual FSLIT("tupExp")           tupIdKey
doEName        = varQual FSLIT("doExp")           doEIdKey
compName       = varQual FSLIT("compExp")          compIdKey
listExpName    = varQual FSLIT("listExp")       listExpIdKey
sigExpName     = varQual FSLIT("sigExp")        sigExpIdKey
condName       = varQual FSLIT("condExp")          condIdKey
letEName       = varQual FSLIT("letExp")          letEIdKey
caseEName      = varQual FSLIT("caseExp")         caseEIdKey
infixAppName   = varQual FSLIT("infixApp")      infixAppIdKey
sectionLName   = varQual FSLIT("sectionL")      sectionLIdKey
sectionRName   = varQual FSLIT("sectionR")      sectionRIdKey
recConName     = varQual FSLIT("recConExp")        recConIdKey
recUpdName     = varQual FSLIT("recUpdExp")        recUpdIdKey
guardedName    = varQual FSLIT("guardedRHS")       guardedIdKey
normalName     = varQual FSLIT("normalRHS")        normalIdKey
bindStName     = varQual FSLIT("bindStmt")        bindStIdKey
letStName      = varQual FSLIT("letStmt")         letStIdKey
noBindStName   = varQual FSLIT("noBindStmt")      noBindStIdKey
parStName      = varQual FSLIT("parStmt")         parStIdKey
fromName       = varQual FSLIT("fromExp")          fromIdKey
fromThenName   = varQual FSLIT("fromThenExp")      fromThenIdKey
fromToName     = varQual FSLIT("fromToExp")        fromToIdKey
fromThenToName = varQual FSLIT("fromThenToExp")    fromThenToIdKey
liftName       = varQual FSLIT("lift")          liftIdKey
gensymName     = varQual FSLIT("gensym")        gensymIdKey
returnQName    = varQual FSLIT("returnQ")       returnQIdKey
bindQName      = varQual FSLIT("bindQ")         bindQIdKey
sequenceQName  = varQual FSLIT("sequenceQ")     sequenceQIdKey

-- data Match = ...
matchName      = varQual FSLIT("match")         matchIdKey
			 
-- data Clause = ...	 
clauseName     = varQual FSLIT("clause")        clauseIdKey
			 
-- data Dec = ...	 
funName        = varQual FSLIT("funDec")        funIdKey
valName        = varQual FSLIT("valDec")        valIdKey
dataDName      = varQual FSLIT("dataDec")       dataDIdKey
newtypeDName   = varQual FSLIT("newtypeDec")    newtypeDIdKey
tySynDName     = varQual FSLIT("tySynDec")      tySynDIdKey
classDName     = varQual FSLIT("classDec")      classDIdKey
instName       = varQual FSLIT("instanceDec")   instIdKey
protoName      = varQual FSLIT("sigDec")        protoIdKey
			 
-- data Typ = ...	 
tforallName    = varQual FSLIT("forallTyp")       tforallIdKey
tvarName       = varQual FSLIT("varTyp")          tvarIdKey
tconName       = varQual FSLIT("conTyp")          tconIdKey
tappName       = varQual FSLIT("appTyp")          tappIdKey
			 
-- data Tag = ...	 
arrowTyConName = varQual FSLIT("arrowTyCon")    arrowIdKey
tupleTyConName = varQual FSLIT("tupleTyCon")    tupleIdKey
listTyConName  = varQual FSLIT("listTyCon")     listIdKey
namedTyConName = varQual FSLIT("namedTyCon")    namedTyConIdKey

-- type Ctxt = ...
ctxtName       = varQual FSLIT("cxt")          ctxtIdKey
			 
-- data Con = ...	 
constrName     = varQual FSLIT("normalCon")        constrIdKey
recConstrName  = varQual FSLIT("recCon")     recConstrIdKey
infixConstrName = varQual FSLIT("infixCon")  infixConstrIdKey
			 
exprTyConName  = tcQual  FSLIT("ExpQ")  	       exprTyConKey
declTyConName  = tcQual  FSLIT("DecQ")  	       declTyConKey
pattTyConName  = tcQual  FSLIT("Pat")  	       pattTyConKey
mtchTyConName  = tcQual  FSLIT("MatchQ")  	       mtchTyConKey
clseTyConName  = tcQual  FSLIT("ClauseQ")  	       clseTyConKey
stmtTyConName  = tcQual  FSLIT("StmtQ") 	       stmtTyConKey
consTyConName  = tcQual  FSLIT("ConQ")  	       consTyConKey
typeTyConName  = tcQual  FSLIT("TypQ")  	       typeTyConKey
strTypeTyConName  = tcQual  FSLIT("StrictTypQ")       strTypeTyConKey
varStrTypeTyConName  = tcQual  FSLIT("VarStrictTypQ")       varStrTypeTyConKey

fieldTyConName = tcQual FSLIT("FieldExp")              fieldTyConKey
fieldPTyConName = tcQual FSLIT("FieldPat")             fieldPTyConKey

qTyConName     = tcQual  FSLIT("Q")  	       qTyConKey
expTyConName   = tcQual  FSLIT("Exp")  	       expTyConKey
decTyConName   = tcQual  FSLIT("Dec")  	       decTyConKey
typTyConName   = tcQual  FSLIT("Typ")  	       typTyConKey
matTyConName   = tcQual  FSLIT("Match")  	       matTyConKey
clsTyConName   = tcQual  FSLIT("Clause")  	       clsTyConKey

strictTypeName = varQual  FSLIT("strictTypQ")   strictTypeKey
varStrictTypeName = varQual  FSLIT("varStrictTypQ")   varStrictTypeKey
strictName     = varQual  FSLIT("isStrict")       strictKey
nonstrictName  = varQual  FSLIT("notStrict")    nonstrictKey

fieldName = varQual FSLIT("fieldExp")              fieldKey
fieldPName = varQual FSLIT("fieldPat")            fieldPKey

--	TyConUniques available: 100-119
-- 	Check in PrelNames if you want to change this

expTyConKey  = mkPreludeTyConUnique 100
matTyConKey  = mkPreludeTyConUnique 101
clsTyConKey  = mkPreludeTyConUnique 102
qTyConKey    = mkPreludeTyConUnique 103
exprTyConKey = mkPreludeTyConUnique 104
declTyConKey = mkPreludeTyConUnique 105
pattTyConKey = mkPreludeTyConUnique 106
mtchTyConKey = mkPreludeTyConUnique 107
clseTyConKey = mkPreludeTyConUnique 108
stmtTyConKey = mkPreludeTyConUnique 109
consTyConKey = mkPreludeTyConUnique 110
typeTyConKey = mkPreludeTyConUnique 111
typTyConKey  = mkPreludeTyConUnique 112
decTyConKey  = mkPreludeTyConUnique 113
varStrTypeTyConKey = mkPreludeTyConUnique 114
strTypeTyConKey = mkPreludeTyConUnique 115
fieldTyConKey = mkPreludeTyConUnique 116
fieldPTyConKey = mkPreludeTyConUnique 117



-- 	IdUniques available: 200-299
-- 	If you want to change this, make sure you check in PrelNames
fromIdKey       = mkPreludeMiscIdUnique 200
fromThenIdKey   = mkPreludeMiscIdUnique 201
fromToIdKey     = mkPreludeMiscIdUnique 202
fromThenToIdKey = mkPreludeMiscIdUnique 203
liftIdKey       = mkPreludeMiscIdUnique 204
gensymIdKey     = mkPreludeMiscIdUnique 205
returnQIdKey    = mkPreludeMiscIdUnique 206
bindQIdKey      = mkPreludeMiscIdUnique 207
funIdKey        = mkPreludeMiscIdUnique 208
valIdKey        = mkPreludeMiscIdUnique 209
protoIdKey      = mkPreludeMiscIdUnique 210
matchIdKey      = mkPreludeMiscIdUnique 211
clauseIdKey     = mkPreludeMiscIdUnique 212
integerLIdKey   = mkPreludeMiscIdUnique 213
charLIdKey      = mkPreludeMiscIdUnique 214

classDIdKey     = mkPreludeMiscIdUnique 215
instIdKey       = mkPreludeMiscIdUnique 216
dataDIdKey      = mkPreludeMiscIdUnique 217

sequenceQIdKey  = mkPreludeMiscIdUnique 218
tySynDIdKey      = mkPreludeMiscIdUnique 219

plitIdKey       = mkPreludeMiscIdUnique 220
pvarIdKey       = mkPreludeMiscIdUnique 221
ptupIdKey       = mkPreludeMiscIdUnique 222
pconIdKey       = mkPreludeMiscIdUnique 223
ptildeIdKey     = mkPreludeMiscIdUnique 224
paspatIdKey     = mkPreludeMiscIdUnique 225
pwildIdKey      = mkPreludeMiscIdUnique 226
varIdKey        = mkPreludeMiscIdUnique 227
conIdKey        = mkPreludeMiscIdUnique 228
litIdKey        = mkPreludeMiscIdUnique 229
appIdKey        = mkPreludeMiscIdUnique 230
infixEIdKey     = mkPreludeMiscIdUnique 231
lamIdKey        = mkPreludeMiscIdUnique 232
tupIdKey        = mkPreludeMiscIdUnique 233
doEIdKey        = mkPreludeMiscIdUnique 234
compIdKey       = mkPreludeMiscIdUnique 235
listExpIdKey    = mkPreludeMiscIdUnique 237
condIdKey       = mkPreludeMiscIdUnique 238
letEIdKey       = mkPreludeMiscIdUnique 239
caseEIdKey      = mkPreludeMiscIdUnique 240
infixAppIdKey   = mkPreludeMiscIdUnique 241
-- 242 unallocated
sectionLIdKey   = mkPreludeMiscIdUnique 243
sectionRIdKey   = mkPreludeMiscIdUnique 244
guardedIdKey    = mkPreludeMiscIdUnique 245
normalIdKey     = mkPreludeMiscIdUnique 246
bindStIdKey     = mkPreludeMiscIdUnique 247
letStIdKey      = mkPreludeMiscIdUnique 248
noBindStIdKey   = mkPreludeMiscIdUnique 249
parStIdKey      = mkPreludeMiscIdUnique 250

tforallIdKey	= mkPreludeMiscIdUnique 251
tvarIdKey	= mkPreludeMiscIdUnique 252
tconIdKey	= mkPreludeMiscIdUnique 253
tappIdKey	= mkPreludeMiscIdUnique 254

arrowIdKey	= mkPreludeMiscIdUnique 255
tupleIdKey	= mkPreludeMiscIdUnique 256
listIdKey	= mkPreludeMiscIdUnique 257
namedTyConIdKey	= mkPreludeMiscIdUnique 258

ctxtIdKey	= mkPreludeMiscIdUnique 259

constrIdKey	= mkPreludeMiscIdUnique 260

stringLIdKey	= mkPreludeMiscIdUnique 261
rationalLIdKey	= mkPreludeMiscIdUnique 262

sigExpIdKey     = mkPreludeMiscIdUnique 263

strictTypeKey = mkPreludeMiscIdUnique 264
strictKey = mkPreludeMiscIdUnique 265
nonstrictKey = mkPreludeMiscIdUnique 266
varStrictTypeKey = mkPreludeMiscIdUnique 267

recConstrIdKey	= mkPreludeMiscIdUnique 268
infixConstrIdKey	= mkPreludeMiscIdUnique 269

recConIdKey     = mkPreludeMiscIdUnique 270
recUpdIdKey     = mkPreludeMiscIdUnique 271
precIdKey       = mkPreludeMiscIdUnique 272
fieldKey        = mkPreludeMiscIdUnique 273
fieldPKey       = mkPreludeMiscIdUnique 274

intPrimLIdKey    = mkPreludeMiscIdUnique 275
floatPrimLIdKey  = mkPreludeMiscIdUnique 276
doublePrimLIdKey = mkPreludeMiscIdUnique 277

newtypeDIdKey      = mkPreludeMiscIdUnique 278

-- %************************************************************************
-- %*									*
--		Other utilities
-- %*									*
-- %************************************************************************

-- It is rather usatisfactory that we don't have a SrcLoc
addDsWarn :: SDoc -> DsM ()
addDsWarn msg = dsWarn (noSrcLoc, msg)
