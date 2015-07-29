-- | The main module parsers and executes the R6RS Scheme superset, Ballgame
module Main where

import Text.ParserCombinators.Parsec hiding (spaces)

import System.Environment
import System.IO

import Control.Monad
import Control.Monad.Except

import Data.Char

-- | Possible Scheme values
data LispVal = Atom String
             | List [LispVal]
             | Number Integer
             | Decimal Double
             | String String
             | Bool Bool
             | Char Char
instance Show LispVal where show = showVal

-- | Possible Scheme Errors
data LispError = NumArgs Integer [LispVal]
               | TypeMismatch String LispVal
               | Parser ParseError
               | BadSpecialForm String LispVal
               | NotFunction String String
               | UnboundVar String String
               | Default String
instance Show LispError where show = showError

type ThrowsError = Either LispError

data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

-- | Recognizes a Scheme symbol
symbol :: Parser Char
symbol = oneOf "!#$%&|*+-/:<=>?@^_~"

-- | Skips spaces
spaces :: Parser ()
spaces = skipMany1 Text.ParserCombinators.Parsec.space

-- | Returns a LispVal String read from a String
parseString :: Parser LispVal
parseString = do
  char '"'
  x <- many (escapedChar <|> noneOf "\\\"")
  char '"'
  return $ String x

parseChar :: Parser LispVal
parseChar = do
  string "#\\"
  s <- many1 letter
  return $ case map toLower s of
    "space" -> Char ' '
    "newline" -> Char '\n'
    "return" -> Char '\r'
    "linefeed" -> Char '\f'
    "tab" -> Char '\t'
    "vtab" -> Char '\v'
    "backspace" -> Char '\b'
    [x] -> Char x

-- | A helper function for parseString. Matches an escaped character
escapedChar :: Parser Char
escapedChar = do
  char '\\'
  c <- oneOf "\\abtnvfr\""
  return $ case c of
    '\\' -> c
    'a' -> '\a'
    'b' -> '\b'
    't' -> '\t'
    'n' -> '\n'
    'v' -> '\v'
    'f' -> '\f'
    'r' -> '\r'
    '"' -> c

-- | Match a list of expressions spearated by spaces
parseList :: Parser LispVal
parseList = liftM List $ sepBy parseExpr spaces

-- | Parse a quoted symbol/expression
parseQuoted :: Parser LispVal
parseQuoted = do
  char '\''
  x <- parseExpr
  return $ List [Atom "quote", x]

-- | Returns a LispVal Atom read from a String
parseAtom :: Parser LispVal
parseAtom = do
  first <- letter <|> symbol
  rest <- many (letter <|> digit <|> symbol)
  let atom = first:rest


  return $ case atom of
    "#t" -> Bool True
    "#f" -> Bool False
    _    -> Atom atom

-- | Returns a LispVal Number read from a String
parseNumber :: Parser LispVal
parseNumber = liftM readWrap $ many1 digit
  where readWrap = Number . read

-- | Returns a LispVal Decimal read from a String
parseDecimal :: Parser LispVal
parseDecimal = do
  whole <- many1 digit
  char '.'
  decimal <- many1 digit
  return $ Decimal (read (whole++"."++decimal) :: Double)

-- | Parses a Scheme expression
parseExpr :: Parser LispVal
parseExpr = parseAtom
  <|> parseString
  <|> parseNumber
  <|> parseDecimal
  <|> parseQuoted
  <|> do oneOf "({["
         x <- try parseList
         oneOf ")}]"
         return x

-- | Formats Scheme values
showVal :: LispVal -> String
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Decimal contents) = show contents
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (List contents) = "(" ++ unwordsList contents ++ ")"

-- | Formats Scheme Error
showError :: LispError -> String
showError (UnboundVar message varname) = message ++ ": " ++ varname
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (NotFunction message func) = message ++ ": " ++ show func
showError (NumArgs expected found) = "Expected " ++ show expected ++ " args: found values " ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected ++ ", found " ++ show found
showError (Parser parseErr) = "Parse error at " ++ show parseErr

-- | Convert error to string, and return it
trapError action = catchError action (return . show)

-- | Possibly throws an error when extracting a Scheme values
extractValue :: ThrowsError a -> a
extractValue (Right val) = val

-- | Recursivly formats a list
unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

-- | EVALUATION AND INPUT | --

-- | A set of built in functions and primitive operators
primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
              ("*", numericBinop (*)),
              ("-", numericBinop (-)),
              ("/", numericBinop div),
              ("mod", numericBinop mod),
              ("quotient", numericBinop quot),
              ("remainder", numericBinop rem),
              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("!=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("and", boolBoolBinop (&&)),
              ("or", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string>?", strBoolBinop (>)),
              ("string<?", strBoolBinop (<)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv),
              ("equal?", equal)]

-- | Adaptes a Haskell functions for Scheme
numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params = liftM (Number . foldl1 op) (mapM unpackNum params)

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (String n) = let parsed = reads n in
  if null parsed
    then throwError $ TypeMismatch "number" $ String n
    else return $ fst $ head parsed
unpackNum (List [n]) = unpackNum n
unpackNum notNum = throwError $ TypeMismatch "number" notNum

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
                             then throwError $ NumArgs 2 args
                             else do left <- unpacker $ head args
                                     right <- unpacker $ args !! 1
                                     return $ Bool $ left `op` right

numBoolBinop = boolBinop unpackNum
strBoolBinop = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s) = return $ show s
unpackStr notString = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool = throwError $ TypeMismatch "boolean" notBool

-- | Takes an Unpacker and two LispVals, and determines if the LispVals are equel when unpacked with the Unpacker
unpackEquals :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackEquals arg1 arg2 (AnyUnpacker unpacker) =
  do
    unpacked1 <- unpacker arg1
    unpacked2 <- unpacker arg2
    return $ unpacked1 == unpacked2
  `catchError` const (return False)

-- | Checks if two LispVals are equal in any possible way
equal :: [LispVal] -> ThrowsError LispVal
equal [List arg1, List arg2] = return $ Bool $ length arg1 == length arg2 && all equalPair (zip arg1 arg2)
  where equalPair (x1, x2) = case equal [x1, x2] of
                               Left err -> False
                               Right (Bool val) -> val
equal [arg1, arg2] = do
  primitiveEquals <- liftM or $ mapM (unpackEquals arg1 arg2)
                     [AnyUnpacker unpackNum, AnyUnpacker unpackStr, AnyUnpacker unpackBool]
  eqvEquals <- eqv [arg1, arg2]
  return $ Bool $ primitiveEquals || let (Bool x) = eqvEquals in x
equal badArgList = throwError $ NumArgs 2 badArgList
-- | Primitive list access functions
car :: [LispVal] -> ThrowsError LispVal
car [List (x : xs)] = return x
car [badArg] = throwError $ TypeMismatch "pair" badArg
car badArgList = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x : xs)] = return $ List xs
cdr [badArg] = throwError $ TypeMismatch "pair" badArg
cdr badArgList = throwError $ NumArgs 1 badArgList

-- | Primitive list building function, CONS
cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []] = return $ List [x1]
cons [x, List xs] = return $ List $ x : xs
cons [x1, x2] = return $ List $ x1 : [x2]
cons badArgList = throwError $ NumArgs 2 badArgList

-- | Checks if two LispVals are exactly equivilant and equal
eqv :: [LispVal] -> ThrowsError LispVal
eqv [Bool arg1, Bool arg2] = return $ Bool $ arg1 == arg2
eqv [Number arg1, Number arg2] = return $ Bool $ arg1 == arg2
eqv [String arg1, String arg2] = return $ Bool $ arg1 == arg2
eqv [Atom arg1, Atom arg2] = return $ Bool $ arg1 == arg2
eqv [List arg1, List arg2] = return $ Bool $ length arg1 == length arg2 && all eqvPair (zip arg1 arg2)
  where eqvPair (x1, x2) = case eqv [x1, x2] of
                             Left err -> False
                             Right (Bool val) -> val
eqv [_, _] = return $ Bool False
eqv badArgList = throwError $ NumArgs 2 badArgList

-- | Evaluates primitives
eval :: LispVal -> ThrowsError LispVal
eval val@(String _) = return val
eval val@(Number _) = return val
eval val@(Bool _) = return val
eval (List [Atom "quote", val]) = return val
eval (List [Atom "if", pred, conseq, alt]) = do
    result <- eval pred
    case result of
      Bool False -> eval alt
      otherwise -> eval conseq
eval (List (Atom func : args)) = mapM eval args >>= apply func
eval badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

-- | Runs a function on LispVal arguments
apply :: String -> [LispVal] -> ThrowsError LispVal
apply func args = maybe (throwError $ NotFunction "Unrecognized primitive function args" func)
                        ($ args)
                        (lookup func primitives)

-- | Reads a Scheme expression
readExpr :: String -> ThrowsError LispVal
readExpr input = case parse parseExpr "lisp" input of
  Left err -> throwError $ Parser err
  Right val -> return val

-- | Main entry point and IO related code
flushStr :: String -> IO ()
flushStr str = putStr str >> hFlush stdout

readPrompt :: String -> IO String
readPrompt prompt = flushStr prompt >> getLine

evalString :: String -> IO String
evalString expr = return $ extractValue $ trapError (liftM show $ readExpr expr >>= eval)

evalAndPrint :: String -> IO ()
evalAndPrint expr = evalString expr >>= putStrLn

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pred prompt action = do
  result <- prompt
  unless (pred result) $ action result >> until_ pred prompt action

runRepl :: IO ()
runRepl = until_ (== "quit") (readPrompt ":) ") evalAndPrint

main :: IO ()
main = do
  args <- getArgs
  case length args of
    0 -> runRepl
    1 -> evalAndPrint $ head args
    otherwise -> putStrLn "Probram takes only 0 or 1 argument"
