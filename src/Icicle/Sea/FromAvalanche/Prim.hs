{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}

module Icicle.Sea.FromAvalanche.Prim (
    seaOfXPrim
  , seaOfPrimDocApps
  , PrimDoc (..)
  ) where

import           Icicle.Avalanche.Prim.Flat

import qualified Icicle.Common.Exp.Prim.Minimal as M
import           Icicle.Common.Type

import           Icicle.Internal.Pretty

import           Icicle.Sea.FromAvalanche.Base
import           Icicle.Sea.FromAvalanche.Type

import           P

data PrimDoc
 = PDFun   Doc
 | PDAlloc Doc

seaOfPrimDocApps :: PrimDoc -> [Doc] -> Doc
seaOfPrimDocApps p xs
 = case p of
    PDFun   d -> d <+> tuple xs
    PDAlloc d -> d <+> tuple ("&s->mempool" : xs)

seaOfXPrim :: Prim -> PrimDoc
seaOfXPrim p
 = case p of
     PrimMinimal (M.PrimArithUnary op t)
      -> PDFun
       ( prefixOfArithType t <> seaOfPrimArithUnary op )

     PrimMinimal (M.PrimArithBinary op t)
      -> PDFun
       ( prefixOfArithType t <> seaOfPrimArithBinary op )

     PrimMinimal (M.PrimDouble op)
      -> PDFun
       ( prefixOfValType DoubleT <> seaOfPrimDouble op )

     PrimMinimal (M.PrimDateTime op)
      -> PDFun
       ( prefixOfValType DateTimeT <> seaOfPrimDateTime op )

     PrimMinimal (M.PrimCast op)
      -> PDFun $ seaOfPrimCast op

     PrimMinimal (M.PrimRelation op t)
      -> PDFun
       ( prefixOfValType t <> seaOfPrimRelation op )

     PrimMinimal (M.PrimLogical op)
      -> PDFun
       ( prefixOfValType BoolT <> seaOfPrimLogical op )

     PrimProject op
      -> PDFun $ seaOfPrimProject op

     PrimUnsafe op
      -> seaOfPrimUnsafe op

     PrimUpdate op
      -> PDFun $ seaOfPrimUpdate op

     PrimArray op
      -> PDFun $ seaOfPrimArray op

     PrimBuf   op
      -> seaOfPrimBuf op

     _
      -> PDFun $ seaError "seaOfXPrim" p

seaOfPrimArithUnary :: M.PrimArithUnary -> Doc
seaOfPrimArithUnary p
 = case p of
     M.PrimArithNegate -> "neg"

seaOfPrimArithBinary :: M.PrimArithBinary -> Doc
seaOfPrimArithBinary p
 = case p of
     M.PrimArithPlus  -> "add"
     M.PrimArithMinus -> "sub"
     M.PrimArithMul   -> "mul"
     M.PrimArithPow   -> "pow"

seaOfPrimDouble :: M.PrimDouble -> Doc
seaOfPrimDouble p
 = case p of
     M.PrimDoubleDiv -> "div"
     M.PrimDoubleLog -> "log"
     M.PrimDoubleExp -> "exp"

seaOfPrimDateTime :: M.PrimDateTime -> Doc
seaOfPrimDateTime p
 = case p of
     M.PrimDateTimeDaysDifference -> "days_diff"
     M.PrimDateTimeDaysEpoch      -> "to_epoch"
     M.PrimDateTimeMinusDays      -> "minus_days"
     M.PrimDateTimeMinusMonths    -> "minus_months"

seaOfPrimCast :: M.PrimCast -> Doc
seaOfPrimCast p
 = case p of
     M.PrimCastDoubleOfInt -> "iint_extend"
     M.PrimCastIntOfDouble -> "idouble_trunc"
     _                     -> seaError "seaOfPrimCast" p

seaOfPrimRelation :: M.PrimRelation -> Doc
seaOfPrimRelation p
 = case p of
     M.PrimRelationGt -> "gt"
     M.PrimRelationGe -> "ge"
     M.PrimRelationLt -> "lt"
     M.PrimRelationLe -> "le"
     M.PrimRelationEq -> "eq"
     M.PrimRelationNe -> "ne"

seaOfPrimLogical :: M.PrimLogical -> Doc
seaOfPrimLogical p
 = case p of
     M.PrimLogicalAnd -> "and"
     M.PrimLogicalOr  -> "or"
     M.PrimLogicalNot -> "not"

seaOfPrimProject :: PrimProject -> Doc
seaOfPrimProject p
 = case p of
     PrimProjectArrayLength t
      -> prefixOfValType (ArrayT t) <> "length"
     _
      -> seaError "seaOfPrimProject" p

seaOfPrimUnsafe :: PrimUnsafe -> PrimDoc
seaOfPrimUnsafe p
 = case p of
     PrimUnsafeArrayIndex t
      -> PDFun   (prefixOfValType (ArrayT t) <> "index")
     PrimUnsafeArrayCreate t
      -> PDAlloc (prefixOfValType (ArrayT t) <> "create")
     _
      -> PDFun   (seaError "seaOfPrimUnsafe" p)

seaOfPrimUpdate :: PrimUpdate -> Doc
seaOfPrimUpdate p
 = case p of
     PrimUpdateArrayPut t
      -> prefixOfValType (ArrayT t) <> "put"

seaOfPrimArray :: PrimArray -> Doc
seaOfPrimArray p
 = case p of
     _
      -> seaError "seaOfPrimArray" p

seaOfPrimBuf :: PrimBuf -> PrimDoc
seaOfPrimBuf p
 = case p of
     PrimBufPush i t
      -> PDFun   (prefixOfValType (BufT i t) <> "push")
     PrimBufRead i t
      -> PDAlloc (prefixOfValType (BufT i t) <> "read")

