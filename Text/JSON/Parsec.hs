--------------------------------------------------------------------
-- |
-- Module    : 
-- Copyright : (c) Galois, Inc. 2008
-- License   : BSD3
--
-- Maintainer: Don Stewart <dons@galois.com>
-- Stability : provisional
-- Portability:
--
-- An example parsec-based parser for JSON

module Text.JSON.Parsec
  ( p_value
  , p_null
  , p_boolean
  , p_array
  , p_string
  , p_object
  , p_number
  , p_js_string
  , p_js_object
  , module Text.ParserCombinators.Parsec
  ) where

import Text.JSON.Types
import Text.ParserCombinators.Parsec
import Control.Monad
import Data.Char
import Numeric

type Parsec a     = CharParser () a

tok              :: Parsec a -> Parsec a
tok p             = spaces *> p

p_value          :: Parsec JSType
p_value           =  (JSNull      <$  p_null)
                 <|> (JSBool      <$> p_boolean)
                 <|> (JSArray     <$> p_array)
                 <|> (JSString    <$> p_js_string)
                 <|> (JSObject    <$> p_js_object)
                 <|> (JSRational  <$> p_number)
                 <?> "JSON value"

p_null           :: Parsec ()
p_null            = tok (string "null") >> return ()

p_boolean        :: Parsec Bool
p_boolean         = tok
                      (  (True  <$ string "true")
                     <|> (False <$ string "false")
                      )

p_array          :: Parsec [JSType]
p_array           = between (tok (char '[')) (tok (char ']'))
                  $ p_value `sepBy` tok (char ',')

p_string         :: Parsec String
p_string          = between (tok (char '"')) (char '"') (many p_char)
  where p_char    =  (char '\\' >> p_esc)
                 <|> (satisfy (\x -> x /= '"' && x /= '\\'))

        p_esc     =  ('"'   <$ char '"')
                 <|> ('\\'  <$ char '\\')
                 <|> ('/'   <$ char '/')
                 <|> ('\b'  <$ char 'b')
                 <|> ('\f'  <$ char 'f')
                 <|> ('\n'  <$ char 'n')
                 <|> ('\r'  <$ char 'r')
                 <|> ('\t'  <$ char 't')
                 <|> (char 'u' *> p_uni)
                 <?> "escape character"

        p_uni     = check =<< count 4 (satisfy isHexDigit)
          where check x | code <= max_char  = pure (toEnum code)
                        | otherwise         = empty
                  where code      = fst $ head $ readHex x
                        max_char  = fromEnum (maxBound :: Char)

p_object         :: Parsec [(String,JSType)]
p_object          = between (tok (char '{')) (tok (char '}'))
                  $ p_field `sepBy` tok (char ',')
  where p_field   = (,) <$> (p_string <* tok (char ':')) <*> p_value

p_number         :: Parsec Rational
p_number          = do s <- getInput
                       case readSigned readFloat s of
                         [(n,s1)] -> n <$ setInput s1
                         _        -> empty

p_js_string      :: Parsec JSONString
p_js_string       = toJSString <$> p_string

p_js_object      :: Parsec (JSONObject JSType)
p_js_object       = toJSObject <$> p_object

--------------------------------------------------------------------------------
-- XXX: Because Parsec is not Applicative yet...

pure   :: a -> Parsec a
pure    = return

(<*>)  :: Parsec (a -> b) -> Parsec a -> Parsec b
(<*>)   = ap

(*>)   :: Parsec a -> Parsec b -> Parsec b
(*>)    = (>>)

(<*)   :: Parsec a -> Parsec b -> Parsec a
m <* n  = do x <- m; n; return x

empty  :: Parsec a
empty   = mzero

(<$>)  :: (a -> b) -> Parsec a -> Parsec b
(<$>)   = fmap

(<$)   :: a -> Parsec b -> Parsec a
x <$ m  = m >> return x
