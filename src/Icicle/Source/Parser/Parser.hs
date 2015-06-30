{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Source.Parser.Parser (
    top
  , query
  , context
  , exp
  , windowUnit
  ) where

import qualified        Icicle.Source.Lexer.Token  as T
import                  Icicle.Source.Parser.Token
import                  Icicle.Source.Parser.Operators
import qualified        Icicle.Source.Query        as Q

import                  P hiding (exp)

import                  Text.Parsec (many1, parserFail, getPosition, eof, (<?>))

top :: Parser (Q.QueryTop T.SourcePos Var)
top
 = do   pKeyword T.Feature                                  <?> "feature start"
        v <- pVariable                                      <?> "concrete feature name"
        pFlowsInto
        q <- query                                          <?> "query"
        eof
        return $ Q.QueryTop v q


query :: Parser (Q.Query T.SourcePos Var)
query
 = do   cs <- many context                                  <?> "contexts"
        x  <- exp                                           <?> "expression"
        return $ Q.Query cs x


context :: Parser (Q.Context T.SourcePos Var)
context
 = do   c <- context1                                       <?> "context"
        pFlowsInto
        return c
 where
  context1
   =   pKeyword T.Windowed *> cwindowed
   <|> pKeyword T.Group    *> (Q.GroupBy  <$> getPosition <*> exp)
   <|> pKeyword T.Distinct *> (Q.Distinct <$> getPosition <*> exp)
   <|> pKeyword T.Filter   *> (Q.Filter   <$> getPosition <*> exp)
   <|> pKeyword T.Latest   *> (Q.Latest   <$> getPosition <*> pLitInt)
   <|> pKeyword T.Let      *> (cletfold <|> clet)

  cwindowed
   = cwindowed2 <|> cwindowed1

  cwindowed1
   = do p  <- getPosition
        t1 <- windowUnit
        return $ Q.Windowed p t1 Nothing

  cwindowed2
   = do p <- getPosition
        pKeyword T.Between 
        t1 <- windowUnit
        pKeyword T.And
        t2 <- windowUnit
        return $ Q.Windowed p t2 $ Just t1

  clet
   = do p <- getPosition
        n <- pVariable                                      <?> "binding name"
        pEq T.TEqual
        x <- exp                                            <?> "let definition expression"
        return $ Q.Let p n x

  cletfold
   = do ft <- foldtype                                      <?> "let fold"
        p <- getPosition
        n <- pVariable
        pEq T.TEqual
        z <- exp                                            <?> "initial value"
        pEq T.TFollowedBy                                   <?> "colon (:)"
        k <- exp                                            <?> "fold expression"
        return $ Q.LetFold p (Q.Fold n z k ft)

  foldtype
    =   pKeyword T.Fold1 *> return Q.FoldTypeFoldl1
    <|> pKeyword T.Fold  *> return Q.FoldTypeFoldl

exp :: Parser (Q.Exp T.SourcePos Var)
exp
 = do   xs <- many1 ((Left <$> exp1) <|> op)                <?> "expression"
        either (parserFail.show) return
               (defix xs)
 where
  -- Get the position before reading the operator
  op = do p <- getPosition
          o <- pOperator
          return (Right (o,p))

exp1 :: Parser (Q.Exp T.SourcePos Var)
exp1
 =   (Q.Var     <$> getPosition <*> var)
 <|> (Q.Prim    <$> getPosition <*> prims)
 <|> (simpNested<$> getPosition <*> parens)
 <?> "expression"
 where
  var
   = pVariable

  -- TODO: this should be a lookup rather than asum
  prims
   =  asum (fmap (\(k,q) -> pKeyword k *> return q) primitives)
   <|> ((Q.Lit . Q.LitInt) <$> pLitInt)
   <?> "primitive"

  simpNested _ (Q.Query [] x)
   = x
  simpNested p q
   = Q.Nested p q

  parens
   =   pParenL *> query <* pParenR                          <?> "sub-expression or nested query"


windowUnit :: Parser Q.WindowUnit
windowUnit
 = do   i <- pLitInt                                        <?> "window amount"
        unit T.Days (Q.Days i) <|> unit T.Months (Q.Months i) <|> unit T.Weeks (Q.Weeks i)
 where
  unit kw q
   = pKeyword kw *> return q


primitives :: [(T.Keyword, Q.Prim)]
primitives
 = [(T.Newest, Q.Agg Q.Newest)
   ,(T.Count,  Q.Agg Q.Count)
   ,(T.Oldest, Q.Agg Q.Oldest)
   ,(T.Sum,    Q.Agg Q.SumA)
   ]

