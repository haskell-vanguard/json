--------------------------------------------------------------------
-- |
-- Module    : Text.JSON.StringParser
-- Copyright : (c) Galois, Inc. 2007
-- License   : BSD3
--
-- Maintainer:  Don Stewart <dons@galois.com>
-- Stability :  provisional
-- Portability: portable
--
--------------------------------------------------------------------
--
-- Basic support for working with JSON values.
--

module Text.JSON.String (
    -- * Parsing
    --
     GetJSON, runGetJSON

    -- ** Reading JSON
  , readJSNull, readJSBool, readJSString, readJSRational
  , readJSArray, readJSObject

  , readJSType, readJSTopType

    -- ** Writing JSON
  , showJSNull, showJSBool, showJSRational, showJSArray
  , showJSObject

  , showJSType, showJSTopType

  ) where

import Text.JSON.Types

import Data.Char
import Data.List
import Data.Ratio
import Data.Either
import Control.Monad(liftM)
import Numeric


-- -----------------------------------------------------------------
-- | Parsing JSON

-- | The type of JSON parsers for String
newtype GetJSON a = GetJSON { un :: String -> Either String (a,String) }

instance Functor GetJSON where fmap = liftM
instance Monad GetJSON where
  return x        = GetJSON (\s -> Right (x,s))
  fail x          = GetJSON (\_ -> Left x)
  GetJSON m >>= f = GetJSON (\s -> case m s of
                                     Left err -> Left err
                                     Right (a,s1) -> un (f a) s1)

-- | Run a JSON reader on an input String, returning some Haskell value
runGetJSON :: GetJSON a -> String -> Either String a
runGetJSON (GetJSON m) s = case m s of
                             Left err    -> Left err
                             Right (a,_) -> Right a

getInput   :: GetJSON String
getInput    = GetJSON (\s -> Right (s,s))

setInput   :: String -> GetJSON ()
setInput s  = GetJSON (\_ -> Right ((),s))

(<$>) :: Functor f => (a -> b) -> f a -> f b
x <$> y = fmap x y

-------------------------------------------------------------------------

-- | Find 8 chars context, for error messages
context :: String -> String
context s = take 8 s

-- | Read the JSON null type
readJSNull :: GetJSON JSType
readJSNull = do
  xs <- getInput
  if "null" `isPrefixOf` xs
        then setInput (drop 4 xs) >> return JSNull
        else fail $ "Unable to parse JSON null: " ++ context xs

-- | Read the JSON Bool type
readJSBool :: GetJSON JSType
readJSBool = do
  xs <- getInput
  case () of {_
      | "true"  `isPrefixOf` xs -> setInput (drop 4 xs) >> return (JSBool True)
      | "false" `isPrefixOf` xs -> setInput (drop 5 xs) >> return (JSBool False)
      | otherwise               -> fail $ "Unable to parse JSON Bool: " ++ context xs
  }

-- | Read the JSON String type
readJSString :: GetJSON JSType
readJSString = do
  '"' : cs <- getInput
  parse [] cs

 where parse rs cs = rs `seq` case cs of
            '\\' : c : ds -> esc rs c ds
            '"'  : ds     -> do setInput ds
                                return . JSString . toJSString . reverse $ rs
            c    : ds     -> parse (c:rs) ds
            _             -> fail $ "Unable to parse JSON String: unterminated String: "
                                        ++ context cs

       esc rs c cs = case c of
          '\\' -> parse ('\\' : rs) cs
          '"'  -> parse ('"'  : rs) cs
          'n'  -> parse ('\n' : rs) cs
          'r'  -> parse ('\r' : rs) cs
          't'  -> parse ('\t' : rs) cs
          'f'  -> parse ('\f' : rs) cs
          'b'  -> parse ('\b' : rs) cs
          '/'  -> parse ('/'  : rs) cs
          'u'  -> case cs of
                    d1 : d2 : d3 : d4 : cs' ->
                      case readHex [d1,d2,d3,d4] of
                        [(n,"")] -> parse (toEnum n : rs) cs'

                        x -> fail $ "Unable to parse JSON String: invalid hex: " ++ context (show x)
                    _ -> fail $ "Unable to parse JSON String: invalid hex: " ++ context cs
          _ ->  fail $ "Unable to parse JSON String: invalid escape char: " ++ show c


-- | Read an Integer or Double in JSON format, returning a Rational
readJSRational :: GetJSON Rational
readJSRational = do
  cs <- getInput
  case cs of
    '-' : ds -> negate <$> pos ds
    _        -> pos cs

  where pos ('0':cs)  = frac 0 cs
        pos cs        = case span isDigit cs of
          ([],_)  -> fail $ "Unable to parse JSON Rational: " ++ context cs
          (xs,ys) -> frac (fromInteger (read xs)) ys

        frac n cs = case cs of
            '.' : ds ->
              case span isDigit ds of
                ([],_) -> setInput cs >> return n
                (as,bs) -> let x = read as :: Integer
                               y = 10 ^ (fromIntegral (length as) :: Integer)
                           in exponent' (n + (x % y)) bs
            _ -> exponent' n cs

        exponent' n (c:cs)
          | c == 'e' || c == 'E' = (n*) <$> exp_num cs
        exponent' n cs = setInput cs >> return n

        exp_num          :: String -> GetJSON Rational
        exp_num ('+':cs)  = exp_digs cs
        exp_num ('-':cs)  = recip <$> exp_digs cs
        exp_num cs        = exp_digs cs

        exp_digs :: String -> GetJSON Rational
        exp_digs cs = case readDec cs of
            [(a,ds)] -> do setInput ds
                           return (fromIntegral ((10::Integer) ^ (a::Integer)))
            _        -> fail $ "Unable to parse JSON exponential: " ++ context cs

-- | Read a list in JSON format
readJSArray  :: GetJSON JSType
readJSArray  = readSequence '[' ']' ',' >>= return . JSArray

-- | Read an object in JSON format
readJSObject :: GetJSON JSType
readJSObject = readAssocs '{' '}' ',' >>= return . JSObject . toJSObject


-- | Read a sequence of items
readSequence :: Char -> Char -> Char -> GetJSON [JSType]
readSequence start end sep = do
  zs <- getInput
  case dropWhile isSpace zs of
    c : cs | c == start ->
        case dropWhile isSpace cs of
            d : ds | d == end -> setInput (dropWhile isSpace ds) >> return []
            ds                -> setInput ds >> parse []
    _ -> fail $ "Unable to parse JSON sequence: sequence stars with invalid character: " ++ context zs

  where parse rs = rs `seq` do
          a  <- readJSType
          ds <- getInput
          case dropWhile isSpace ds of
            e : es | e == sep -> do setInput (dropWhile isSpace es)
                                    parse (a:rs)
                   | e == end -> do setInput (dropWhile isSpace es)
                                    return (reverse (a:rs))
            _ -> fail $ "Unable to parse JSON sequence: unterminated sequence: " ++ context ds


-- | Read a sequence of JSON labelled fields
readAssocs :: Char -> Char -> Char -> GetJSON [(String,JSType)]
readAssocs start end sep = do
  zs <- getInput
  case dropWhile isSpace zs of
    c:cs | c == start -> case dropWhile isSpace cs of
            d:ds | d == end -> setInput (dropWhile isSpace ds) >> return []
            ds              -> setInput ds >> parsePairs []
    _ -> fail "Unable to parse JSON object: unterminated sequence"

  where parsePairs rs = rs `seq` do
          a  <- do (JSString k)  <- readJSString
                   ds <- getInput
                   case dropWhile isSpace ds of
                       ':':es -> do setInput (dropWhile isSpace es)
                                    v <- readJSType
                                    return (fromJSString k,v)
                       _      -> fail $ "Malformed JSON labelled field: " ++ context ds

          ds <- getInput
          case dropWhile isSpace ds of
            e : es | e == sep -> do setInput (dropWhile isSpace es)
                                    parsePairs (a:rs)
                   | e == end -> do setInput (dropWhile isSpace es)
                                    return (reverse (a:rs))
            _ -> fail $ "Unable to parse JSON object: unterminated sequence: "
                            ++ context ds

-- | Read one of several possible JS types
readJSType :: GetJSON JSType
readJSType = do
  cs <- getInput
  case cs of
    '"' : _ -> readJSString
    '[' : _ -> readJSArray
    '{' : _ -> readJSObject
    't' : _ -> readJSBool
    'f' : _ -> readJSBool
    xs | "null" `isPrefixOf` xs -> readJSNull
    _ -> JSRational <$> readJSRational

-- | Top level JSON can only be Arrays or Objects
readJSTopType :: GetJSON JSType
readJSTopType = do
  cs <- getInput
  case cs of
    '[' : _ -> readJSArray
    '{' : _ -> readJSObject
    _       -> fail "Invalid JSON: a JSON text a serialized object or array at the top level."

-- -----------------------------------------------------------------
-- | Writing JSON

-- | Show strict JSON top level types. Values not permitted
-- at the top level are wrapped in a singleton array.
showJSTopType :: JSType -> ShowS
showJSTopType (JSArray a)    = showJSArray a
showJSTopType (JSObject o)   = showJSObject o
showJSTopType x              = showJSTopType $ JSArray [x]

-- | Show JSON values
showJSType :: JSType -> ShowS
showJSType (JSNull)       = showJSNull
showJSType (JSBool b)     = showJSBool b
showJSType (JSRational r) = showJSRational r
showJSType (JSArray a)    = showJSArray a
showJSType (JSString s)   = showJSString s
showJSType (JSObject o)   = showJSObject o

-- | Write the JSON null type
showJSNull :: ShowS
showJSNull = showString "null"

-- | Write the JSON Bool type
showJSBool :: Bool -> ShowS
showJSBool True  = showString "true"
showJSBool False = showString "false"

-- | Write the JSON String type
showJSString :: JSONString -> ShowS
showJSString x = quote . foldr (.) quote (map sh (fromJSString x))
  where
        quote = showChar '"'
        sh c  = case c of
                  '"'  -> showString "\\\""
                  '\\' -> showString "\\\\"
                  '\n' -> showString "\\n"
                  '\r' -> showString "\\r"
                  '\t' -> showString "\\t"
                  '\f' -> showString "\\f"
                  '\b' -> showString "\\b"
                  _ | n < 32 -> showString "\\u"
                       . showHex d1 . showHex d2 . showHex d3 . showHex d4
                  _ -> showChar c
          where n = fromEnum c
                (d1,n1) = n  `divMod` 0x1000
                (d2,n2) = n1 `divMod` 0x0100
                (d3,d4) = n2 `divMod` 0x0010

-- | Show a Rational in JSON format
showJSRational :: Rational -> ShowS
showJSRational r | denominator r == 1 = shows $ numerator r
                 | otherwise = if isInfinite x || isNaN x then showJSNull
                                                          else shows x
                     where x :: Double
                           x = realToFrac r

-- | Show a list in JSON format
showJSArray :: [JSType] -> ShowS
showJSArray = showSequence '[' ']' ','

-- | Show an association list in JSON format
showJSObject :: JSONObject JSType -> ShowS
showJSObject = showAssocs '{' '}' ',' . fromJSObject

-- | Show a generic sequence of pairs in JSON format
showAssocs :: Char -> Char -> Char -> [(String,JSType)] -> ShowS
showAssocs start end sep xs rest = (start:[])
    ++ concat (intersperse (sep:[]) $ map mkRecord xs)
    ++ (end:[]) ++ rest
  where mkRecord (k,v) = show k ++ ":" ++ showJSType v []

-- | Show a generic sequence in JSON format
showSequence :: Char -> Char -> Char -> [JSType] -> ShowS
showSequence start end sep xs rest = (start:[])
  ++ concat (intersperse (sep:[]) $ map (flip showJSType []) xs)
  ++ (end:[]) ++ rest
