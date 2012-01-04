module Visi.Parse (parseLine, parseLines, mkGroup) where

{- ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is Visi.io.
 *
 * The Initial Developer of the Original Code is
 * David Pollak.
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * ***** END LICENSE BLOCK ***** -}

import Control.Applicative((<*))
import Text.Parsec
import Text.Parsec.String
import Text.Parsec.Prim
import Text.Parsec.Expr
import Text.Parsec.Token
import Text.Parsec.Language
import qualified Data.Text as T
import Data.Char ( isAlpha, toLower, toUpper, isSpace, digitToInt )
import Data.List ( nub, sort )
import Visi.Util
import Visi.Expression
import qualified Data.Map as Map
import qualified Data.List as List

data TIState = TIState {tiSupply :: Int, tiDepth :: Int} deriving (Show)
type MParser = Parsec String TIState

-- | parse a line of input
parseLine :: String -> Either VisiError Expression
parseLine str = case runParser line (TIState{tiSupply = 0, tiDepth = 0}) str str of
                  Left(err) -> Left(ParsingError err)
                  Right(res) -> Right(res)

-- | parse many lines of input and return a List of expressions
parseLines :: String -> Either VisiError [Expression]
parseLines str = case runParser doLines (TIState{tiSupply = 0, tiDepth = 0}) str str of
                    Left(err) -> Left(ParsingError err)
                    Right(res) -> Right(res)
                    

mkGroup :: [Expression] -> Expression
mkGroup expLst = Group (Map.fromList $ expLst >>= funcName) (TPrim PrimDouble) (ValueConst $ DoubleValue 1.0)

mkString _ [] = ""
mkString _ [s] = s
mkString sep (h:t) = h ++ sep ++ (mkString sep t)

funcName :: Expression -> [(FuncName, Expression)]
funcName exp@(LetExp _ name _ _ _) = [(name, exp)]
funcName exp@(BuiltIn name _ _) = [(name, exp)]
funcName exp@(SinkExp _ name _ _) = [(name, exp)]
funcName exp@(SourceExp _ name _) = [(name, exp)]
funcName _ = []


visiDef = emptyDef{ commentStart = "/*"
                  , commentEnd = "*/"
                  , commentLine = "//"
                  , caseSensitive = True
                  , nestedComments = True
                  , identStart = letter <|> char '_'
                  , identLetter = alphaNum <|> char '_'
                  , opStart = oneOf ":!#$%&*+./<=>?@\\^|-~"
                  , opLetter = oneOf ":!#$%&*+./<=>?@\\^|-~"
                  , reservedOpNames = []
                  , reservedNames = ["if", "then", "else", "struct"]
                  }

TokenParser{ parens = m_parens
            , identifier = m_identifier
            , reservedOp = m_reservedOp
            , reserved = m_reserved
            , semiSep1 = m_semiSep1
            , stringLiteral = m_stringLiteral
            , whiteSpace = m_whiteSpace } = m_makeTokenParser visiDef


line :: MParser Expression
line = do info <- dataDefinition <|> try(funcDef) <|> try(letDef)
          try(eol) <|> try(eof)
          return info

narc id = id

doLines = blankLines >> stmtparser <* (do
                                        blankLines
                                        eof)
    where
      stmtparser :: MParser [Expression]
      stmtparser = many(blankLines >> line <* blankLines)


{-mySpace = do try(char ' ') <|> try(char '\t') {- <|> m_singleLineComment <|> m_multiLineComment -} <?> "Space"
             return ()
-}

mySpaces = try(m_whiteSpace) {-do many mySpace
              return ()-}

blankLine =
            do
                mySpaces
                eol

blankLines = many blankLine

eol :: MParser ()
eol = do char '\n'
         toGrab <- curDepth
         consumeN (toGrab - 1) $ char ' '
         return ()

consumeN n _ | n <= 0 = return ()
consumeN n exp =
  do
    exp
    consumeN (n - 1) exp

curDepth =
  do
    st <- getState
    return $ tiDepth st

funcDef :: MParser Expression
funcDef = try(sinkFunc) <|> try(normalFunc) <|> try(sourceFunc) <?> "Function Definition"

-- | An upper case character followed by an identifier
typeName =
  do
    c <- upper
    rest <- option [] m_identifier
    return (c:rest)

-- | a type parameter
typeParam =
  do
    mySpaces
    c <- lower
    rest <- option [] m_identifier
    mySpaces
    return (c:rest)

-- | a list of type parameters
typeParams = many typeParam

typeWithOptionalParams =
  do
    name <- typeName
    mySpaces
    many typeOrTypeParam
    mySpaces
    return name

-- | get a type with optional type parameters or an identifier
typeOrTypeParam =
  typeWithOptionalParams <|> m_identifier

structDataDef =
  do
    mySpaces
    argName <- typeParam
    mySpaces
    char ':'
    mySpaces
    typeName <- typeOrTypeParam
    mySpaces
    return ()


structParams =
  do
    char '('
    params <- sepBy1 structDataDef (char ',')
    mySpaces
    char ')'
    mySpaces
    return params

-- | the inner part of a struct definition
structInner =
  do
    mySpaces
    name <- typeName
    params <- option [] (structParams)
    return ()


-- | Did we find a 
dataDefinition =
  do
    m_reserved "struct"
    mySpaces
    name <- typeName
    tparams <- typeParams <?> "Type parameters"
    mySpaces
    char '='
    defs <- sepBy1 structInner (char '|')
    return $ ValueConst $ BoolValue False -- FIXME finish data definition

sourceOrSinkName = try(m_identifier) <|> try(m_stringLiteral)

sinkFunc =
    do
      mySpaces
      sinkName <- m_stringLiteral
      mySpaces
      char '='
      mySpaces
      exp <- expressionOrLetAndExp
      mySpaces
      rt <- newTyVar "Sink"
      letId <- newLetId "SinkLet"
      return $ SinkExp letId (FuncName $ T.pack sinkName) rt exp

consumeUntilNotWhitespaceOrEOL :: MParser ()
consumeUntilNotWhitespaceOrEOL = try(consumeUntilNotWhitespaceOrEOL' <|> mySpaces)

consumeUntilNotWhitespaceOrEOL' :: MParser ()
consumeUntilNotWhitespaceOrEOL' =
  do
    mySpaces
    eol
    many consumeUntilNotWhitespaceOrEOL
    mySpaces
    return ()

expressionOrLetAndExp :: MParser Expression
expressionOrLetAndExp = 
  do
    consumeUntilNotWhitespaceOrEOL
    col <- curColumn
    dep <- curDepth
    (if col > dep then runDepth col ((letAndThenExp col) <|> expression <?> "Looking for let + exp or exp") else parserFail "Incorrect indentation")

letAndThenExp atCol =
  do

    letExp <- try(normalFunc) <|> try(letDef)
    try(eol)
    consumeUntilNotWhitespaceOrEOL
    curCol <- curColumn
    expr <- (if curCol /= atCol then parserFail "Expressions not lined up"
                                                  else try(letAndThenExp atCol) <|> expression)
    tpe <- newTyVar "innerlet"
    return $ InnerLet tpe letExp expr



sourceFunc =
    do
      mySpaces
      char '?'
      sourceName <- m_identifier
      mySpaces
      tpe <- newTyVar "source"
      letId <- newLetId "SourceLet"
      seLetId <- newLetId "SourceExp"
      return $ LetExp letId (FuncName $ T.pack sourceName) False tpe $ SourceExp seLetId (FuncName $ T.pack sourceName) tpe

normalFunc = do 
              name <- m_identifier
              param <- many1(m_identifier )
              mySpaces
              char '='
              mySpaces
              exp <- expressionOrLetAndExp
              mySpaces
              rt <- newTyVar "r"
              letId <- newLetId "normal"
              pTypes <- mapM makeVars param
              let (wholeExp, ft) = foldr foldFunc (exp, rt) pTypes
              return $ LetExp letId (FuncName $ T.pack name) True ft wholeExp
              where makeVars param = do pt <- newTyVar "p"
                                        return (FuncName $ T.pack param, pt)
                    foldFunc (funcName, pt) (exp, rt) = (FuncExp funcName pt exp, tFun pt rt)

letDef :: MParser Expression
letDef = 
  do
    curCol <- curColumn
    name <- m_identifier
    mySpaces
    char '='
    mySpaces
    exp <- expressionOrLetAndExp
    mySpaces
    t1 <- newTyVar "L"
    letId <- newLetId "Let"
    return $ LetExp letId (FuncName $ T.pack name) False t1 exp

buildType t = tFun (TPrim PrimBool) $ ifType t
ifType t = (tFun t (tFun t t))


functionInvocationName =
  try(m_identifier) <|> try(
    do
      char '#'
      name <- m_identifier
      return ('#':name)
  ) <|> try(
    do
      char '#'
      char '='
      name <- m_identifier
      return ('#':'=':name)
  ) {-} <|> try(
    do
      var <- m_identifier
      char '.'
      prop <- m_identifier
      return var -- FIXME compound thingy
  ) -}

-- expression :: GenParser Char TIState Expression
expression = try( oprFuncExp ) <|>
             try( parenExp ) <|>
             try( ifElseExp) <|>
             try( funcParamExp) <|>
             try( zeroFuncExp) <|>
             try( constExp) <?> "Looking for an expression"
             where parenExp = do
                              mySpaces
                              char '('
                              mySpaces
                              exp <- expression
                              mySpaces
                              char ')'
                              return exp
                   constExp = try(strConstExp) <|> try(numConstExp) <?> "Constant"
                   strConstExp = do
                                  chars <- m_stringLiteral
                                  return $ ValueConst $ StrValue $ T.pack chars
                   decMore = do
                               dec <- char '.'
                               digits <- many1 $ oneOf "0123456789"
                               return $ dec : digits
                   numConstExp = do
                                  mySpaces
                                  optMin <- optionMaybe(char '-')
                                  digits <- many1 $ oneOf "0123456789"
                                  optDec <- optionMaybe $ decMore
                                  mySpaces
                                  return $ ValueConst $ DoubleValue $ 
                                    read $ case (optMin, digits, optDec) of
                                             (Nothing, d, Nothing) -> d
                                             (Just(_), d, Nothing) -> '-' : d
                                             (Just(_), d, Just(rest)) -> '-' : (d ++ rest)
                                             (_, d, Just(rest)) -> (d ++ rest)
                   zeroFuncExp = do funcName <- try(functionInvocationName) <?> "Looking for a variable"
                                    return $ Var (FuncName $ T.pack funcName)
                   ifElseExp = do
                                m_reserved "if"
                                mySpaces
                                boolExp <- expression
                                mySpaces
                                m_reserved "then"
                                mySpaces
                                trueExp <- expression
                                mySpaces
                                m_reserved "else"
                                mySpaces
                                falseExp <- expression
                                mySpaces
                                theType <- newTyVar "IfElse"
                                letId <- newLetId "IfElse"
                                return $ Apply letId theType 
                                           (Apply letId (tFun theType theType)
                                            (Apply letId (ifType theType) 
                                                       (Var (FuncName $ T.pack "$ifelse"))
                                                       boolExp) trueExp) falseExp
                   funcParamExp = do
                                  funcName <- try(functionInvocationName)
                                  mySpaces
                                  rest <- many1(try(oprFuncExp) <|> try(parenExp) <|> 
                                                try(zeroFuncExp) <|> try(constExp) <?> "parameter")
                                  restWithVars <- mapM makeVars rest
                                  letId <- newLetId funcName
                                  let buildApply exp (exp2, t2) =  Apply letId t2 exp exp2
                                  return $ List.foldl' buildApply (Var (FuncName $ T.pack funcName)) restWithVars
                                  where makeVars exp = do t2 <- newTyVar "RetType"
                                                          return (exp, t2)
                                        
                   allButOpr = try( parenExp) <|> try(ifElseExp) <|> try(funcParamExp) <|> 
                               try(zeroFuncExp) <|> try(constExp) <?>
                               "All but Opr"
--                   oprFuncExp :: GenParser Char TIState Expression
                   oprFuncExp = do
                                mySpaces
                                left <- try(allButOpr)
                                mySpaces
                                opr <- many1 $ oneOf "+-*/&|=><!?"
                                mySpaces
                                t1 <- newTyVar "OAt1"
                                t2 <- newTyVar "OAt2"
                                t3 <- newTyVar "OAt3"
                                t4 <- newTyVar "OAt4"
                                letId <- newLetId $ "binary" ++ opr
                                right <- try(expression) <?> "Looking for right side of exp"
                                return $ Apply letId t2 (Apply letId t4 (Var (FuncName $ T.pack opr)) left) right

curColumn :: MParser Int
curColumn =
  do
    pos <- getPosition
    let sc = sourceColumn pos
    return sc

newLetId prefix =
    do
      s <- getState
      setState s{tiSupply = tiSupply s + 1}
      return $ LetId $ T.pack (prefix ++ (show (tiSupply s)))

runDepth d c =
  do
    curr <- getState
    let cd = tiDepth curr
    setState curr{tiDepth = d}
    res <- c
    nCurr <- getState
    setState nCurr{tiDepth = cd}
    return res

newTyVar prefix = do s <- getState
                     setState s{tiSupply = tiSupply s + 1}
                     return $ TVar $ T.pack (prefix ++ (show (tiSupply s)))


-----------------------------------------------------------
-- Given a LanguageDef, create a token parser.
-----------------------------------------------------------

-- | The expression @makeTokenParser language@ creates a 'GenTokenParser'
-- record that contains lexical parsers that are
-- defined using the definitions in the @language@ record.
--
-- The use of this function is quite stylized - one imports the
-- appropiate language definition and selects the lexical parsers that
-- are needed from the resulting 'GenTokenParser'.
--
-- >  module Main where
-- >
-- >  import Text.Parsec
-- >  import qualified Text.Parsec.Token as P
-- >  import Text.Parsec.Language (haskellDef)
-- >
-- >  -- The parser
-- >  ...
-- >
-- >  expr  =   parens expr
-- >        <|> identifier
-- >        <|> ...
-- >       
-- >
-- >  -- The lexer
-- >  lexer       = P.makeTokenParser haskellDef    
-- >      
-- >  parens      = P.parens lexer
-- >  braces      = P.braces lexer
-- >  identifier  = P.identifier lexer
-- >  reserved    = P.reserved lexer
-- >  ...

m_makeTokenParser :: (Stream s m Char)
                => GenLanguageDef s u m -> GenTokenParser s u m
m_makeTokenParser languageDef
    = TokenParser{ identifier = identifier
                 , reserved = reserved
                 , operator = operator
                 , reservedOp = reservedOp

                 , charLiteral = charLiteral
                 , stringLiteral = stringLiteral
                 , natural = natural
                 , integer = integer
                 , float = float
                 , naturalOrFloat = naturalOrFloat
                 , decimal = decimal
                 , hexadecimal = hexadecimal
                 , octal = octal

                 , symbol = symbol
                 , lexeme = lexeme
                 , whiteSpace = whiteSpace

                 , parens = parens
                 , braces = braces
                 , angles = angles
                 , brackets = brackets
                 , squares = brackets
                 , semi = semi
                 , comma = comma
                 , colon = colon
                 , dot = dot
                 , semiSep = semiSep
                 , semiSep1 = semiSep1
                 , commaSep = commaSep
                 , commaSep1 = commaSep1
                 }
    where

    -----------------------------------------------------------
    -- Bracketing
    -----------------------------------------------------------
    parens p        = between (symbol "(") (symbol ")") p
    braces p        = between (symbol "{") (symbol "}") p
    angles p        = between (symbol "<") (symbol ">") p
    brackets p      = between (symbol "[") (symbol "]") p

    semi            = symbol ";"
    comma           = symbol ","
    dot             = symbol "."
    colon           = symbol ":"

    commaSep p      = sepBy p comma
    semiSep p       = sepBy p semi

    commaSep1 p     = sepBy1 p comma
    semiSep1 p      = sepBy1 p semi


    -----------------------------------------------------------
    -- Chars & Strings
    -----------------------------------------------------------
    charLiteral     = lexeme (between (char '\'')
                                      (char '\'' <?> "end of character")
                                      characterChar )
                    <?> "character"

    characterChar   = charLetter <|> charEscape
                    <?> "literal character"

    charEscape      = do{ char '\\'; escapeCode }
    charLetter      = satisfy (\c -> (c /= '\'') && (c /= '\\') && (c > '\026'))



    stringLiteral   = lexeme (
                      do{ str <- between (char '"')
                                         (char '"' <?> "end of string")
                                         (many stringChar)
                        ; return (foldr (maybe id (:)) "" str)
                        }
                      <?> "literal string")

    stringChar      =   do{ c <- stringLetter; return (Just c) }
                    <|> stringEscape
                    <?> "string character"

    stringLetter    = satisfy (\c -> (c /= '"') && (c /= '\\') && (c > '\026'))

    stringEscape    = do{ char '\\'
                        ;     do{ escapeGap  ; return Nothing }
                          <|> do{ escapeEmpty; return Nothing }
                          <|> do{ esc <- escapeCode; return (Just esc) }
                        }

    escapeEmpty     = char '&'
    escapeGap       = do{ many1 space
                        ; char '\\' <?> "end of string gap"
                        }



    -- escape codes
    escapeCode      = charEsc <|> charNum <|> charAscii <|> charControl
                    <?> "escape code"

    charControl     = do{ char '^'
                        ; code <- upper
                        ; return (toEnum (fromEnum code - fromEnum 'A'))
                        }

    charNum         = do{ code <- decimal
                                  <|> do{ char 'o'; number 8 octDigit }
                                  <|> do{ char 'x'; number 16 hexDigit }
                        ; return (toEnum (fromInteger code))
                        }

    charEsc         = choice (map parseEsc escMap)
                    where
                      parseEsc (c,code)     = do{ char c; return code }

    charAscii       = choice (map parseAscii asciiMap)
                    where
                      parseAscii (asc,code) = try (do{ string asc; return code })


    -- escape code tables
    escMap          = zip ("abfnrtv\\\"\'") ("\a\b\f\n\r\t\v\\\"\'")
    asciiMap        = zip (ascii3codes ++ ascii2codes) (ascii3 ++ ascii2)

    ascii2codes     = ["BS","HT","LF","VT","FF","CR","SO","SI","EM",
                       "FS","GS","RS","US","SP"]
    ascii3codes     = ["NUL","SOH","STX","ETX","EOT","ENQ","ACK","BEL",
                       "DLE","DC1","DC2","DC3","DC4","NAK","SYN","ETB",
                       "CAN","SUB","ESC","DEL"]

    ascii2          = ['\BS','\HT','\LF','\VT','\FF','\CR','\SO','\SI',
                       '\EM','\FS','\GS','\RS','\US','\SP']
    ascii3          = ['\NUL','\SOH','\STX','\ETX','\EOT','\ENQ','\ACK',
                       '\BEL','\DLE','\DC1','\DC2','\DC3','\DC4','\NAK',
                       '\SYN','\ETB','\CAN','\SUB','\ESC','\DEL']


    -----------------------------------------------------------
    -- Numbers
    -----------------------------------------------------------
    naturalOrFloat  = lexeme (natFloat) <?> "number"

    float           = lexeme floating   <?> "float"
    integer         = lexeme int        <?> "integer"
    natural         = lexeme nat        <?> "natural"


    -- floats
    floating        = do{ n <- decimal
                        ; fractExponent n
                        }


    natFloat        = do{ char '0'
                        ; zeroNumFloat
                        }
                      <|> decimalFloat

    zeroNumFloat    =  do{ n <- hexadecimal <|> octal
                         ; return (Left n)
                         }
                    <|> decimalFloat
                    <|> fractFloat 0
                    <|> return (Left 0)

    decimalFloat    = do{ n <- decimal
                        ; option (Left n)
                                 (fractFloat n)
                        }

    fractFloat n    = do{ f <- fractExponent n
                        ; return (Right f)
                        }

    fractExponent n = do{ fract <- fraction
                        ; expo  <- option 1.0 exponent'
                        ; return ((fromInteger n + fract)*expo)
                        }
                    <|>
                      do{ expo <- exponent'
                        ; return ((fromInteger n)*expo)
                        }

    fraction        = do{ char '.'
                        ; digits <- many1 digit <?> "fraction"
                        ; return (foldr op 0.0 digits)
                        }
                      <?> "fraction"
                    where
                      op d f    = (f + fromIntegral (digitToInt d))/10.0

    exponent'       = do{ oneOf "eE"
                        ; f <- sign
                        ; e <- decimal <?> "exponent"
                        ; return (power (f e))
                        }
                      <?> "exponent"
                    where
                       power e  | e < 0      = 1.0/power(-e)
                                | otherwise  = fromInteger (10^e)


    -- integers and naturals
    int             = do{ f <- lexeme sign
                        ; n <- nat
                        ; return (f n)
                        }

    sign            =   (char '-' >> return negate)
                    <|> (char '+' >> return id)
                    <|> return id

    nat             = zeroNumber <|> decimal

    zeroNumber      = do{ char '0'
                        ; hexadecimal <|> octal <|> decimal <|> return 0
                        }
                      <?> ""

    decimal         = number 10 digit
    hexadecimal     = do{ oneOf "xX"; number 16 hexDigit }
    octal           = do{ oneOf "oO"; number 8 octDigit  }

    number base baseDigit
        = do{ digits <- many1 baseDigit
            ; let n = foldl (\x d -> base*x + toInteger (digitToInt d)) 0 digits
            ; seq n (return n)
            }

    -----------------------------------------------------------
    -- Operators & reserved ops
    -----------------------------------------------------------
    reservedOp name =
        lexeme $ try $
        do{ string name
          ; notFollowedBy (opLetter languageDef) <?> ("end of " ++ show name)
          }

    operator =
        lexeme $ try $
        do{ name <- oper
          ; if (isReservedOp name)
             then unexpected ("reserved operator " ++ show name)
             else return name
          }

    oper =
        do{ c <- (opStart languageDef)
          ; cs <- many (opLetter languageDef)
          ; return (c:cs)
          }
        <?> "operator"

    isReservedOp name =
        isReserved (sort (reservedOpNames languageDef)) name


    -----------------------------------------------------------
    -- Identifiers & Reserved words
    -----------------------------------------------------------
    reserved name =
        lexeme $ try $
        do{ caseString name
          ; notFollowedBy (identLetter languageDef) <?> ("end of " ++ show name)
          }

    caseString name
        | caseSensitive languageDef  = string name
        | otherwise               = do{ walk name; return name }
        where
          walk []     = return ()
          walk (c:cs) = do{ caseChar c <?> msg; walk cs }

          caseChar c  | isAlpha c  = char (toLower c) <|> char (toUpper c)
                      | otherwise  = char c

          msg         = show name


    identifier =
        lexeme $ try $
        do{ name <- ident
          ; if (isReservedName name)
             then unexpected ("reserved word " ++ show name)
             else return name
          }


    ident
        = do{ c <- identStart languageDef
            ; cs <- many (identLetter languageDef)
            ; return (c:cs)
            }
        <?> "identifier"

    isReservedName name
        = isReserved theReservedNames caseName
        where
          caseName      | caseSensitive languageDef  = name
                        | otherwise               = map toLower name


    isReserved names name
        = scan names
        where
          scan []       = False
          scan (r:rs)   = case (compare r name) of
                            LT  -> scan rs
                            EQ  -> True
                            GT  -> False

    theReservedNames
        | caseSensitive languageDef  = sort reserved
        | otherwise                  = sort . map (map toLower) $ reserved
        where
          reserved = reservedNames languageDef



    -----------------------------------------------------------
    -- White space & symbols
    -----------------------------------------------------------
    symbol name
        = lexeme (string name)

    lexeme p
        = do{ x <- p; whiteSpace; return x  }


    --whiteSpace
    whiteSpace
        | noLine && noMulti  = skipMany (simpleSpace <?> "")
        | noLine             = skipMany (simpleSpace <|> multiLineComment <?> "")
        | noMulti            = skipMany (simpleSpace <|> oneLineComment <?> "")
        | otherwise          = skipMany (simpleSpace <|> oneLineComment <|> multiLineComment <?> "")
        where
          noLine  = null (commentLine languageDef)
          noMulti = null (commentStart languageDef)

    m_isSpace c = c == ' ' || c == '\t'

    simpleSpace =
        skipMany1 (satisfy m_isSpace)

    oneLineComment =
        do{ try (string (commentLine languageDef))
          ; skipMany (satisfy (/= '\n'))
          ; return ()
          }

    multiLineComment =
        do { try (string (commentStart languageDef))
           ; inComment
           }

    inComment
        | nestedComments languageDef  = inCommentMulti
        | otherwise                = inCommentSingle

    inCommentMulti
        =   do{ try (string (commentEnd languageDef)) ; return () }
        <|> do{ multiLineComment                     ; inCommentMulti }
        <|> do{ skipMany1 (noneOf startEnd)          ; inCommentMulti }
        <|> do{ oneOf startEnd                       ; inCommentMulti }
        <?> "end of comment"
        where
          startEnd   = nub (commentEnd languageDef ++ commentStart languageDef)

    inCommentSingle
        =   do{ try (string (commentEnd languageDef)); return () }
        <|> do{ skipMany1 (noneOf startEnd)         ; inCommentSingle }
        <|> do{ oneOf startEnd                      ; inCommentSingle }
        <?> "end of comment"
        where
          startEnd   = nub (commentEnd languageDef ++ commentStart languageDef)