{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
module Text.Haiji.Parse
       ( Expr(..)
       , Variable(..)
       , Function(..)
       , AST(..)
       , SubTemplate(..)
       , Template(..)
       , parseString
       , parseFile
       ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Control.Monad.State.Strict
import Data.Attoparsec.Text
import Data.Char
import Data.List (intercalate)
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.IO as LT

import Text.Haiji.Syntax.Identifier
import Text.Haiji.Syntax.Variable

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> let execHaijiParser p = snd <$> runHaijiParser p

data Expr = Fun Function
          | Var Variable
          deriving Eq

instance Show Expr where
  show (Fun f) = show f
  show (Var v) = show v

data Function = Function Identifier [Expr] deriving Eq

instance Show Function where
  show (Function ident args) = shows ident "(" ++ intercalate ", " (map show args) ++ ")"

type Scoped = Bool

type Base = Bool

data SubTemplate = Loaded
                 | Unloaded

data AST :: SubTemplate -> * where
  Literal :: T.Text -> AST a
  Eval :: Expr -> AST a
  Condition :: Expr -> [AST a] -> Maybe [AST a] -> AST a
  Foreach :: Identifier -> Expr -> [AST a] -> Maybe [AST a] -> AST a
  Include :: FilePath -> AST 'Unloaded
  Raw :: String -> AST a
  Extends :: FilePath -> AST 'Unloaded
  Base :: [AST 'Loaded] -> AST 'Loaded
  Block :: Base -> Identifier -> Scoped -> [AST a] -> AST a
  Super :: AST a
  Comment :: String -> AST a

deriving instance Eq (AST a)

data Template =
  Template
  { templateBase :: [AST 'Loaded]
  , templateChild :: [AST 'Loaded]
  } deriving (Eq, Show)

toTemplate :: [AST 'Loaded] -> Template
toTemplate (Base base : asts) = tmpl { templateChild = templateChild tmpl ++ asts } where
  tmpl = toTemplate base
toTemplate asts = Template { templateBase = asts, templateChild = [] }

parseString :: String -> IO Template
parseString = (toTemplate <$>) . either error readAllFile . parseOnly parser . T.pack

parseFileWith :: (LT.Text -> LT.Text) -> FilePath -> IO Template
parseFileWith f file = LT.readFile file >>= parseString . LT.unpack . f

readAllFile :: [AST 'Unloaded] -> IO [AST 'Loaded]
readAllFile asts = concat <$> mapM parseFileRecursively asts

parseFileRecursively :: AST 'Unloaded -> IO [AST 'Loaded]
parseFileRecursively (Literal l) = return [ Literal l ]
parseFileRecursively (Eval v) = return [ Eval v ]
parseFileRecursively (Condition p ts fs) =
  ((:[]) .) . Condition p
  <$> readAllFile ts
  <*> runMaybeT (maybe mzero return fs >>= lift . readAllFile)
parseFileRecursively (Foreach k xs loopBody elseBody) =
  ((:[]) .) . Foreach k xs
  <$> readAllFile loopBody
  <*> runMaybeT (maybe mzero return elseBody >>= lift . readAllFile)
parseFileRecursively (Include includeFile) = templateBase <$> parseImportFile includeFile
parseFileRecursively (Raw raw) = return [ Raw raw ]
parseFileRecursively (Extends extendsfile) = (:[]) . Base . templateBase <$> parseFile extendsfile
parseFileRecursively (Block base name scoped body) =
  (:[]) . Block base name scoped <$> readAllFile body
parseFileRecursively Super = return [ Super ]
parseFileRecursively (Comment c) = return [ Comment c ]

parseFile :: FilePath -> IO Template
parseFile = parseFileWith deleteLastOneLF where
  deleteLastOneLF :: LT.Text -> LT.Text
  deleteLastOneLF xs
    | "%}\n" `LT.isSuffixOf` xs     = LT.init xs
    | "\n\n" `LT.isSuffixOf` xs     = LT.init xs
    | not ("\n" `LT.isSuffixOf` xs) = xs `LT.append` "\n"
    | otherwise                     = xs

parseImportFile :: FilePath -> IO Template
parseImportFile = parseFileWith deleteLastOneLF where
  deleteLastOneLF xs
    | LT.null xs         = xs
    | LT.last xs == '\n' = LT.init xs
    | otherwise          = xs

instance Show (AST a) where
  show (Literal l) = T.unpack l
  show (Eval v) = "{{ " ++ shows v " }}"
  show (Condition p ts mfs) =
    "{% if " ++ show p ++ " %}" ++
    concatMap show ts ++
    maybe "" (\fs -> "{% else %}" ++ concatMap show fs) mfs ++
    "{% endif %}"
  show (Foreach x xs loopBody elseBody) =
    "{% for " ++ show x ++ " in " ++ show xs ++ " %}" ++
    concatMap show loopBody ++
    maybe "" (("{% else %}" ++) . concatMap show) elseBody ++
    "{% endfor %}"
  show (Include file) = "{% include \"" ++ file ++ "\" %}"
  show (Raw raw) = "{% raw %}" ++ raw ++ "{% endraw %}"
  show (Extends file) = "{% extends \"" ++ file ++ "\" %}"
  show (Base asts) = concatMap show asts
  show (Block _ name scoped body) =
    "{% block " ++ show name ++ (if scoped then " scoped" else "") ++" %}" ++
    concatMap show body ++
    "{% endblock %}"
  show Super = "{{ super() }}"
  show (Comment c) = "{#" ++ c ++ "#}"

data HaijiParserState =
  HaijiParserState
  { haijiParserStateLeadingSpaces :: Maybe (AST 'Unloaded)
  , haijiParserStateInBaseTemplate :: Bool
  } deriving (Eq, Show)

defaultHaijiParserState :: HaijiParserState
defaultHaijiParserState =
  HaijiParserState
  { haijiParserStateLeadingSpaces = Nothing
  , haijiParserStateInBaseTemplate = True
  }

newtype HaijiParser a =
  HaijiParser
  { unHaijiParser :: StateT HaijiParserState Parser a
  } deriving (Functor, Applicative, Alternative, Monad, MonadState HaijiParserState)

runHaijiParser :: HaijiParser a -> Parser (a, HaijiParserState)
runHaijiParser p = runStateT (unHaijiParser p) defaultHaijiParserState

evalHaijiParser :: HaijiParser a -> Parser a
evalHaijiParser p = fst <$> runHaijiParser p

liftParser :: Parser a -> HaijiParser a
liftParser = HaijiParser . lift

saveLeadingSpaces :: HaijiParser ()
saveLeadingSpaces = liftParser leadingSpaces >>= setLeadingSpaces where
  leadingSpaces = option Nothing (Just . Literal <$> takeWhile1 isSpace)

withLeadingSpacesOf :: HaijiParser a -> (a -> HaijiParser b) -> HaijiParser b
withLeadingSpacesOf p q = do
  a <- p
  getLeadingSpaces >>= (q a <*) . setLeadingSpaces

setLeadingSpaces :: Maybe (AST 'Unloaded) -> HaijiParser ()
setLeadingSpaces ss = modify (\s -> s { haijiParserStateLeadingSpaces = ss })

resetLeadingSpaces :: HaijiParser ()
resetLeadingSpaces = setLeadingSpaces Nothing

getLeadingSpaces :: HaijiParser (Maybe (AST 'Unloaded))
getLeadingSpaces = gets haijiParserStateLeadingSpaces

setWhetherBaseTemplate :: Bool -> HaijiParser ()
setWhetherBaseTemplate x = modify (\s -> s { haijiParserStateInBaseTemplate = x })

getWhetherBaseTemplate :: HaijiParser Bool
getWhetherBaseTemplate = gets haijiParserStateInBaseTemplate

parser :: Parser [AST 'Unloaded]
parser = evalHaijiParser (haijiParser <* liftParser endOfInput)

haijiParser :: HaijiParser [AST 'Unloaded]
haijiParser = concat <$> many (resetLeadingSpaces *> choice (map toList parsers)) where
  parsers = [ literalParser
            , derefParser
            , conditionParser
            , foreachParser
            , includeParser
            , rawParser
            , extendsParser
            , blockParser
            , superParser
            , commentParser
            ]
  toList p = do
    b <- p
    a <- getLeadingSpaces
    return $ maybe id (:) a [b]

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser literalParser)
-- >>> eval "テスト{test"
-- テスト
-- >>> eval "   テスト  {test"
--    テスト
-- >>> eval "   テスト  {%-test"
--    テスト
-- >>> eval "   テスト  テスト  {%-test"
--    テスト  テスト
--
literalParser :: HaijiParser (AST 'Unloaded)
literalParser = liftParser $ Literal . T.concat <$> many1 go where
  go = do
    sp <- takeTill (not . isSpace)
    pc <- peekChar
    case pc of
      Nothing  -> if T.null sp then fail "literalParser" else return sp
      Just '{' -> fail "literalParser"
      _        -> T.append sp <$> takeWhile1 (\c -> c /= '{' && not (isSpace c))

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser derefParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser derefParser)
-- >>> eval "{{ foo }}"
-- {{ foo }}
-- >>> exec "{{ foo }}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{{bar}}"
-- {{ bar }}
-- >>> eval "{{   baz}}"
-- {{ baz }}
-- >>> eval " {{ foo }}"
-- {{ foo }}
-- >>> exec " {{ foo }}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just  , haijiParserStateInBaseTemplate = True}
-- >>> eval "{ { foo }}"
-- *** Exception: parse error
-- >>> eval "{{ foo } }"
-- *** Exception: parse error
-- >>> eval "{{ foo }} "
-- {{ foo }}
-- >>> eval "{{ foo() }} "
-- {{ foo() }}
--
derefParser :: HaijiParser (AST 'Unloaded)
derefParser = saveLeadingSpaces *> liftParser deref where
  deref = Eval <$> ((string "{{" >> skipSpace) *> exprParser <* (skipSpace >> string "}}"))


exprParser :: Parser Expr
exprParser = choice [ Fun <$> functionParser
                    , Var <$> variable
                    ]

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly functionParser
-- >>> eval "foo()"
-- foo()
-- >>> eval "super()"
-- *** Exception: parse error
-- >>> eval "foo(a)"
-- foo(a)
-- >>> eval "foo( x , test , a.b )"
-- foo(x, test, a.b)
--
functionParser :: Parser Function
functionParser = do
  ident <- identifier <* skipSpace
  when (ident == "super") $ fail "functionParser"
  Function ident <$> (char '(' >> sepBy (skipSpace >> exprParser <* skipSpace) (char ',') <* char ')')

-- |
--
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser $ statement $ return ())
-- >>> exec "{%%}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> exec "{% %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> exec " {% %} "
-- HaijiParserState {haijiParserStateLeadingSpaces = Just  , haijiParserStateInBaseTemplate = True}
-- >>> exec " {%- -%} "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
statement :: Parser a -> HaijiParser a
statement f = start "{%" <|> (start "{%-" <* resetLeadingSpaces) where
  start s = saveLeadingSpaces *> liftParser ((string s  >> skipSpace) *> f <* (skipSpace >> end))
  end = string "%}" <|> (string "-%}" <* skipSpace)

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser conditionParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser conditionParser)
-- >>> eval "{% if foo %}テスト{% endif %}"
-- {% if foo %}テスト{% endif %}
-- >>> exec "{% if foo %}テスト{% endif %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{%if foo%}テスト{%endif%}"
-- {% if foo %}テスト{% endif %}
-- >>> eval "{% iffoo %}テスト{% endif %}"
-- *** Exception: parse error
-- >>> eval "{% if foo %}真{% else %}偽{% endif %}"
-- {% if foo %}真{% else %}偽{% endif %}
-- >>> eval "{%if foo%}{%if bar%}{%else%}{%endif%}{%else%}{%if baz%}{%else%}{%endif%}{%endif%}"
-- {% if foo %}{% if bar %}{% else %}{% endif %}{% else %}{% if baz %}{% else %}{% endif %}{% endif %}
-- >>> eval "    {% if foo %}テスト{% endif %}"
-- {% if foo %}テスト{% endif %}
-- >>> exec "    {% if foo %}テスト{% endif %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just     , haijiParserStateInBaseTemplate = True}
-- >>> eval "    {%- if foo -%}    テスト    {%- endif -%}    "
-- {% if foo %}テスト{% endif %}
-- >>> exec "    {%- if foo -%}    テスト    {%- endif -%}    "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
conditionParser :: HaijiParser (AST 'Unloaded)
conditionParser = withLeadingSpacesOf startCondition restCondition where
  startCondition = statement $ string "if" >> skipMany1 space >> exprParser
  restCondition cond = do
    ifPart <- haijiParser
    mElsePart <- mayElseParser
    leadingElseSpaces <- getLeadingSpaces
    _ <- statement $ string "endif"
    leadingEndIfSpaces <- getLeadingSpaces
    return $ case mElsePart of
      Nothing       -> Condition cond (ifPart ++ maybeToList leadingEndIfSpaces) Nothing
      Just elsePart -> Condition cond (ifPart ++ maybeToList leadingElseSpaces ) (Just $ elsePart ++ maybeToList leadingEndIfSpaces)

mayElseParser :: HaijiParser (Maybe [AST 'Unloaded])
mayElseParser = option Nothing (Just <$> elseParser) where
  elseParser = withLeadingSpacesOf (statement (string "else")) $ const haijiParser

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser foreachParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser foreachParser)
-- >>> eval "{% for _ in foo %}loop{% endfor %}"
-- {% for _ in foo %}loop{% endfor %}
-- >>> exec "{% for _ in foo %}loop{% endfor %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{%for _ in foo%}loop{%endfor%}"
-- {% for _ in foo %}loop{% endfor %}
-- >>> eval "{% for_ in foo %}loop{% endfor %}"
-- *** Exception: parse error
-- >>> eval "{% for _in foo %}loop{% endfor %}"
-- *** Exception: parse error
-- >>> eval "{% for _ infoo %}loop{% endfor %}"
-- *** Exception: parse error
-- >>> eval "{% for _ in foo %}loop{% else %}else block{% endfor %}"
-- {% for _ in foo %}loop{% else %}else block{% endfor %}
-- >>> eval "{%for _ in foo%}loop{%else%}else block{%endfor%}"
-- {% for _ in foo %}loop{% else %}else block{% endfor %}
-- >>> eval "  {% for _ in foo %}  loop  {% endfor %}  "
-- {% for _ in foo %}  loop  {% endfor %}
-- >>> exec "  {% for _ in foo %}  loop  {% endfor %}  "
-- HaijiParserState {haijiParserStateLeadingSpaces = Just   , haijiParserStateInBaseTemplate = True}
-- >>> eval "  {%- for _ in foo -%}  loop  {%- endfor -%}  "
-- {% for _ in foo %}loop{% endfor %}
-- >>> exec "  {%- for _ in foo -%}  loop  {%- endfor -%}  "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
foreachParser :: HaijiParser (AST 'Unloaded)
foreachParser = withLeadingSpacesOf startForeach restForeach where
  startForeach = statement $ Foreach
                 <$> (string "for" >> skipMany1 space >> identifier)
                 <*> (skipMany1 space >> string "in" >> skipMany1 space >> exprParser)
  restForeach foreach = do
    loopPart <- haijiParser
    mElsePart <- mayElseParser
    leadingElseSpaces <- getLeadingSpaces
    _ <- statement (string "endfor")
    leadingEndForSpaces <- getLeadingSpaces
    return $ case mElsePart of
      Nothing       -> foreach (loopPart ++ maybeToList leadingEndForSpaces) Nothing
      Just elsePart -> foreach (loopPart ++ maybeToList leadingElseSpaces  ) (Just $ elsePart ++ maybeToList leadingEndForSpaces)

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser includeParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser includeParser)
-- >>> eval "{% include \"foo.tmpl\" %}"
-- {% include "foo.tmpl" %}
-- >>> exec "{% include \"foo.tmpl\" %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{%include\"foo.tmpl\"%}"
-- {% include "foo.tmpl" %}
-- >>> eval "{% include 'foo.tmpl' %}"
-- {% include "foo.tmpl" %}
-- >>> eval "  {% include \"foo.tmpl\" %}"
-- {% include "foo.tmpl" %}
-- >>> exec "  {% include \"foo.tmpl\" %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just   , haijiParserStateInBaseTemplate = True}
-- >>> eval "  {%- include \"foo.tmpl\" -%}   "
-- {% include "foo.tmpl" %}
-- >>> exec "  {%- include \"foo.tmpl\" -%}   "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
includeParser :: HaijiParser (AST 'Unloaded)
includeParser = statement $ string "include" >> skipSpace >> Include . T.unpack <$> (quotedBy '"' <|> quotedBy '\'') where
    quotedBy c = char c *> takeTill (== c) <* char c -- TODO: ここもっとマジメにやらないと

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser rawParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser rawParser)
-- >>> eval "{% raw %}test{% endraw %}"
-- {% raw %}test{% endraw %}
-- >>> exec "{% raw %}test{% endraw %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{%raw%}test{%endraw%}"
-- {% raw %}test{% endraw %}
-- >>> eval "{% raw %}{{ test }}{% endraw %}"
-- {% raw %}{{ test }}{% endraw %}
-- >>> eval "  {% raw %}  test  {% endraw %}"
-- {% raw %}  test  {% endraw %}
-- >>> exec "  {% raw %}  test  {% endraw %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just   , haijiParserStateInBaseTemplate = True}
-- >>> eval "  {%- raw -%}   test  {%- endraw -%}  "
-- {% raw %}test{% endraw %}
-- >>> exec "  {%- raw -%}   test  {%- endraw -%}  "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
rawParser :: HaijiParser (AST 'Unloaded)
rawParser = withLeadingSpacesOf startRaw restRaw where
  startRaw = statement $ string "raw"
  restRaw _ = do
    (raw, leadingEndRawSpaces) <- till (liftParser anyChar) (statement (string "endraw") >> getLeadingSpaces)
    return $ Raw $ raw ++ maybe "" show leadingEndRawSpaces where
      till :: Alternative f => f a -> f b -> f ([a], b)
      till p end = go where
        go = ((,) [] <$> end) <|> ((\a (as,b) -> (a:as, b)) <$> p <*> go)

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser extendsParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser extendsParser)
-- >>> eval "{% extends \"foo.tmpl\" %}"
-- {% extends "foo.tmpl" %}
-- >>> exec "{% extends \"foo.tmpl\" %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = False}
-- >>> eval "{%extends\"foo.tmpl\"%}"
-- {% extends "foo.tmpl" %}
-- >>> eval "{% extends 'foo.tmpl' %}"
-- {% extends "foo.tmpl" %}
-- >>> eval "  {% extends \"foo.tmpl\" %}"
-- {% extends "foo.tmpl" %}
-- >>> exec "  {% extends \"foo.tmpl\" %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just   , haijiParserStateInBaseTemplate = False}
-- >>> eval "  {%- extends \"foo.tmpl\" -%}   "
-- {% extends "foo.tmpl" %}
-- >>> exec "  {%- extends \"foo.tmpl\" -%}   "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = False}
--
extendsParser :: HaijiParser (AST 'Unloaded)
extendsParser = do
  base <- getWhetherBaseTemplate
  unless base $ fail "extendsParser"
  go <* setWhetherBaseTemplate False where
    go = statement $ string "extends" >> skipSpace >> Extends . T.unpack <$> (quotedBy '"' <|> quotedBy '\'')
    quotedBy c = char c *> takeTill (== c) <* char c -- TODO: ここもっとマジメにやらないと

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser blockParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser blockParser)
-- >>> eval "{% block foo %}テスト{% endblock %}"
-- {% block foo %}テスト{% endblock %}
-- >>> exec "{% block foo %}テスト{% endblock %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "{% block foo %}テスト{% endblock foo %}"
-- {% block foo %}テスト{% endblock %}
-- >>> eval "{% block foo %}テスト{% endblock bar %}"
-- *** Exception: parse error
-- >>> eval "{%block foo%}テスト{%endblock%}"
-- {% block foo %}テスト{% endblock %}
-- >>> eval "{% blockfoo %}テスト{% endblock %}"
-- *** Exception: parse error
-- >>> eval "    {% block foo %}テスト{% endblock %}"
-- {% block foo %}テスト{% endblock %}
-- >>> exec "    {% block foo %}テスト{% endblock %}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just     , haijiParserStateInBaseTemplate = True}
-- >>> eval "    {%- block foo -%}    テスト    {%- endblock -%}    "
-- {% block foo %}テスト{% endblock %}
-- >>> exec "    {%- block foo -%}    テスト    {%- endblock -%}    "
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
--
blockParser :: HaijiParser (AST 'Unloaded)
blockParser = withLeadingSpacesOf startBlock restBlock where
  startBlock = statement $ string "block" >> skipMany1 space >> identifier
  restBlock name = do
    body <- haijiParser
    mayEndName <- statement $ string "endblock" >> option Nothing (Just <$> (skipMany1 space >> identifier))
    leadingEndBlockSpaces <- getLeadingSpaces
    base <- getWhetherBaseTemplate
    if maybe True (name ==) mayEndName
      then return $ Block base name False (body ++ maybeToList leadingEndBlockSpaces)
      else fail "blockParser"

superParser :: HaijiParser (AST 'Unloaded)
superParser = do
  saveLeadingSpaces
  _ <- liftParser ((string "{{" *> skipSpace) *>
                   (string "super" *> skipSpace >> char '(' >> skipSpace >> char ')') <*
                   (skipSpace *> string "}}"))
  return Super

-- |
--
-- >>> let eval = either (error "parse error") id . parseOnly (evalHaijiParser commentParser)
-- >>> let exec = either (error "parse error") id . parseOnly (execHaijiParser commentParser)
-- >>> eval "{# comment #}"
-- {# comment #}
-- >>> exec "{# comment #}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Nothing, haijiParserStateInBaseTemplate = True}
-- >>> eval "  {# comment #}"
-- {# comment #}
-- >>> exec "  {# comment #}"
-- HaijiParserState {haijiParserStateLeadingSpaces = Just   , haijiParserStateInBaseTemplate = True}
--
commentParser :: HaijiParser (AST 'Unloaded)
commentParser = saveLeadingSpaces *> liftParser (string "{#" >> Comment <$> manyTill anyChar (string "#}"))
