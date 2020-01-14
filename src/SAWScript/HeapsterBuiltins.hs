{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SAWScript.HeapsterBuiltins
       ( heapster_extract_print
       ) where

import qualified Data.Map as Map
import Control.Monad.IO.Class
import Unsafe.Coerce
import GHC.TypeNats

import Data.Binding.Hobbits

import Verifier.SAW.SharedTerm
import Verifier.SAW.OpenTerm

import Lang.Crucible.Types
import Lang.Crucible.CFG.Core
import Lang.Crucible.CFG.Extension
import Lang.Crucible.LLVM.Extension
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.Translation

import SAWScript.Proof
import SAWScript.Prover.SolverStats
import SAWScript.TopLevel
import SAWScript.Value
import SAWScript.Utils as SS
import SAWScript.Options
import SAWScript.CrucibleBuiltins
import SAWScript.Builtins

import SAWScript.Heapster.CruUtil
import SAWScript.Heapster.Permissions
import SAWScript.Heapster.TypedCrucible
import SAWScript.Heapster.SAWTranslation

data PermsListEntry where
  PermsListEntry :: FunPerm ghosts inits ret -> PermsListEntry

-- | A permission for a function that takes in two words and returns a word
binaryWordFunPerm :: (1 <= w, KnownNat w) =>
                     FunPerm (RNil :> BVType w :> BVType w)
                     (RNil :> LLVMPointerType w :> LLVMPointerType w)
                     (LLVMPointerType w)
binaryWordFunPerm =
  FunPerm knownRepr knownRepr knownRepr
  -- Input perms: r1:eq(x), r2:eq(y)
  (nuMulti (MNil :>: Proxy :>: Proxy :>: Proxy) $ \(_ :>: x :>: y :>: _) ->
    nuMulti (MNil :>: Proxy :>: Proxy) $ \_ ->
    ValPerms_Cons (ValPerms_Cons
                   ValPerms_Nil
                   (ValPerm_Eq $ PExpr_LLVMWord $ PExpr_Var x))
    (ValPerm_Eq $ PExpr_LLVMWord $ PExpr_Var x))
  -- Output perms: r1:true, r2:true, ret:(exists z.eq(z))
  (nuMulti (MNil :>: Proxy :>: Proxy :>: Proxy) $ \_ ->
    nuMulti (MNil :>: Proxy :>: Proxy :>: Proxy) $ \_ ->
    ValPerms_Cons (ValPerms_Cons
                   (ValPerms_Cons ValPerms_Nil ValPerm_True) ValPerm_True)
    (ValPerm_Exists $ nu $ \z -> ValPerm_Eq $ PExpr_LLVMWord $ PExpr_Var z))

binaryWordFunPerm64 :: FunPerm (RNil :> BVType 64 :> BVType 64)
                       (RNil :> LLVMPointerType 64 :> LLVMPointerType 64)
                       (LLVMPointerType 64)
binaryWordFunPerm64 = binaryWordFunPerm

binaryWordFunPerm32 :: FunPerm (RNil :> BVType 32 :> BVType 32)
                       (RNil :> LLVMPointerType 32 :> LLVMPointerType 32)
                       (LLVMPointerType 32)
binaryWordFunPerm32 = binaryWordFunPerm


heapsterPermsList :: [PermsListEntry]
heapsterPermsList =
  [PermsListEntry binaryWordFunPerm32, PermsListEntry binaryWordFunPerm64]

-- FIXME: in order to make withCFG work, we need an ArchRepr arg for LLVM_CFG
{-
-- FIXME: how do we do a type-level comparison of nats?
proveNatNonZero :: Proxy w -> (1 <=? w) :~: True
proveNatNonZero _ = unsafeCoerce Refl

withCFG :: SAW_CFG ->
           (forall ext blocks init ret.
            (TraverseExt ext, PrettyExt ext, PermCheckExtC ext) =>
            CFG ext blocks init ret -> a) -> a
withCFG (LLVM_CFG (AnyCFG (cfg :: CFG (LLVM arch) blocks inits ret))) f
  | Refl <- proveNatNonZero (Proxy :: Proxy (ArchWidth arch)) =  
    withKnownNat (Proxy :: Proxy (ArchWidth arch)) $ f cfg
withCFG (JVM_CFG (AnyCFG cfg)) f =
  error "FIXME: JVM CFGs not yet supported!"
  -- f cfg
-}

getLLVMCFG :: ArchRepr arch -> SAW_CFG -> AnyCFG (LLVM arch)
getLLVMCFG _ (LLVM_CFG cfg) =
  -- FIXME: there should be an ArchRepr argument for LLVM_CFG to compare here!
  unsafeCoerce cfg
getLLVMCFG _ (JVM_CFG _) =
  error "getLLVMCFG: expected LLVM CFG, found JVM CFG!"

archReprWidth :: ArchRepr arch -> NatRepr (ArchWidth arch)
archReprWidth (X86Repr w) = w

castFunPerm :: CFG ext blocks inits ret ->
               FunPerm ghosts args ret' ->
               TopLevel (FunPerm ghosts (CtxToRList inits) ret)
castFunPerm cfg fun_perm =
  case (testEquality (funPermArgs fun_perm) (mkCruCtx $ cfgArgTypes cfg),
        testEquality (funPermRet fun_perm) (cfgReturnType cfg)) of
    (Just Refl, Just Refl) -> return fun_perm
    (Nothing, _) ->
      fail $ unlines ["Function permission has incorrect argument types",
                      "Expected: " ++ show (cfgArgTypes cfg),
                      "Actual: " ++ show (funPermArgs fun_perm) ]
    (_, Nothing) ->
      fail $ unlines ["Function permission has incorrect return type",
                      "Expected: " ++ show (cfgReturnType cfg),
                      "Actual: " ++ show (funPermRet fun_perm)]

heapster_extract_print :: BuiltinContext -> Options ->
                          LLVMModule -> String -> Int ->
                          TopLevel ()
heapster_extract_print bic opts lm fn_name perms_num =
  case modTrans lm of
    Some mod_trans ->
      do let arch = llvmArch $ _transContext mod_trans
         let w = archReprWidth arch
         any_cfg <- getLLVMCFG arch <$> crucible_llvm_cfg bic opts lm fn_name
         pp_opts <- getTopLevelPPOpts
         somePerms <-
           if perms_num < length heapsterPermsList then
             return (heapsterPermsList !! perms_num)
           else fail "heapster_extract: perms index out of bounds"
         case (any_cfg, somePerms) of
           (AnyCFG cfg, PermsListEntry fun_perm_raw) ->
             do fun_perm <- castFunPerm cfg fun_perm_raw
                cl_fun_perm <-
                  case tryClose fun_perm of
                    Just cl_fun_perm -> return cl_fun_perm
                    Nothing -> fail "Function permission is not closed"
                leq_proof <- case decideLeq (knownNat @1) w of
                  Left pf -> return pf
                  Right _ -> fail "LLVM arch width is 0!"
                let cl_env = $(mkClosed [| FunTypeEnv [] |])
                let fun_openterm =
                      withKnownNat w $ withLeqProof leq_proof $
                      translateCFG $ tcCFG cl_env cl_fun_perm cfg
                sc <- getSharedContext
                fun_term <- liftIO $ completeOpenTerm sc fun_openterm
                liftIO $ putStrLn $ scPrettyTerm pp_opts fun_term