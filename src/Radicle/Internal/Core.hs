{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Radicle.Internal.Core where

import           Control.Monad.Except (ExceptT(..), MonadError, catchError,
                                       runExceptT, throwError)
import           Control.Monad.State
import           Data.Bifunctor (first)
import           Data.Data (Data)
import           Data.Deriving (deriveEq1, deriveShow1)
import           Data.Foldable (foldlM, foldrM)
import           Data.Functor.Foldable (Fix(..), cata)
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Map (Map)
import           Data.IntMap (IntMap)
import qualified Data.Map as Map
import qualified Data.IntMap as IntMap
import           Data.Maybe (catMaybes, isJust)
import           Data.Scientific (Scientific)
import           Data.Semigroup (Semigroup, (<>))
import           Data.Text (Text)
import           Data.Void (Void)
import           GHC.Exts (IsList(..), fromString)
import           GHC.Generics (Generic)
import qualified Text.Megaparsec.Error as Par
import           Unsafe.Coerce (unsafeCoerce)
import qualified Data.Text as T


-- * Value

-- | An error throw during parsing or evaluating expressions in the language.
data LangError r =
      UnknownIdentifier Ident
    | Impossible Text
    | TypeError Text
    -- | Takes the function name, expected number of args, and actual number of
    -- args
    | WrongNumberOfArgs Text Int Int
    | OtherError Text
    | ParseError (Par.ParseError Char Void)
    | ThrownError Ident r
    | Exit
    deriving (Eq, Show, Read, Generic, Functor)

-- | Convert an error to a radicle value, and the label for it. Used for
-- catching exceptions.
errorToValue
    :: Monad m
    => LangError (Value Reference)
    -> Lang m (Ident, Value Reference)
errorToValue e = case e of
    UnknownIdentifier i -> makeVal
        ( "unknown-identifier"
        , [("identifier", makeA i)]
        )
    -- "Now more than ever seems it rich to die"
    Impossible _ -> throwError e
    TypeError i -> makeVal
        ( "type-error"
        , [("info", String i)]
        )
    WrongNumberOfArgs i expected actual -> makeVal
        ( "wrong-number-of-args"
        , [ ("function", makeA $ Ident i)
          , ("expected", Number $ fromIntegral expected)
          , ("actual", Number $ fromIntegral actual)]
        )
    OtherError i -> makeVal
        ( "other-error"
        , [("info", String i)]
        )
    ParseError _ -> makeVal ("parse-error", [])
    ThrownError label val -> pure (label, val)
    Exit -> makeVal ("exit", [])
  where
    makeA = quote . Atom
    makeVal (t,v) = pure (Ident t, Dict $ Map.mapKeys Ident . fromList $ v)

newtype Reference = Reference { getReference :: Int }
    deriving (Show, Read, Ord, Eq, Generic)

-- | Create a new ref with the supplied initial value.
newRef :: Monad m => Value Reference -> Lang m (Value Reference)
newRef v = do
    b <- get
    let ix = bindingsNextRef b
    put $ b { bindingsNextRef = succ ix
            , bindingsRefs = IntMap.insert ix v $ bindingsRefs b
            }
    pure . Ref $ Reference ix

-- | Read the value of a reference.
readRef :: MonadError (LangError (Value Reference)) m => Reference -> Lang m (Value Reference)
readRef (Reference r) = do
    refs <- gets bindingsRefs
    case IntMap.lookup r refs of
        Nothing -> throwError $ Impossible "undefined reference"
        Just v  -> pure v

-- | An expression or value in the language.
--
-- The parameter is for refs. Usually it is 'Reference'. However, we first
-- parse into 'Fix Value' before converting it into 'Reference' (see
-- 'makeRefs').
--
-- A Value that no longer contains any references can have type 'Value Void',
-- indicating it is safe to share between threads or chains.
data Value r =
    -- | A regular (hyperstatic) variable.
      Atom Ident
    | String Text
    | Number Scientific
    | Boolean Bool
    | List [Value r]
    | Primop Ident
    | Dict (Map.Map Ident (Value r))
    | Ref r
    -- | Takes the arguments/parameters, a body, and possibly a closure.
    --
    -- The value of an application of a lambda is always the last value in the
    -- body. The only reason to have multiple values is thus only for (local)
    -- "define"s.
    | Lambda [Ident] (NonEmpty (Value r)) (Maybe (Env (Value r)))
    deriving (Eq, Show, Read, Generic, Functor, Foldable, Traversable)


-- | Replace all Refs containing 'Fix Value' into ones containing references to
-- those values.
makeRefs :: Monad m => Value (Fix Value) -> Lang m (Value Reference)
makeRefs v = cata go (Fix v)
  where
    go x = case x of
        Atom i -> pure $ Atom i
        String i -> pure $ String i
        Boolean i -> pure $ Boolean i
        Number i -> pure $ Number i
        Primop i -> pure $ Primop i
        Dict m -> Dict <$> sequence (go <$> m)
        List vs -> List <$> sequence (go <$> vs)
        Ref i -> i >>= eval >>= newRef
        Lambda is bd e -> Lambda is <$> sequence (go <$> bd)
                                    <*> traverse sequence (fmap go <$> e)

-- | Safely coerce a 'Value' containing no refs into one of a different type.
coerceRefs :: Value Void -> Value a
coerceRefs = unsafeCoerce

-- | An identifier in the language.
--
-- Not all `Text`s are valid identifiers, so we do not export the constructor.
-- Instead, use `makeIdent`.
newtype Ident = Ident { fromIdent :: Text }
    deriving (Eq, Show, Read, Ord, Generic, Data)

-- Unsafe! Only use this if you know the string at compile-time and know it's a
-- valid identifier
toIdent :: String -> Ident
toIdent = Ident . fromString

-- | The environment, which keeps all known bindings.
newtype Env s = Env { fromEnv :: Map Ident s }
    deriving (Eq, Semigroup, Monoid, Show, Read, Generic, Functor, Foldable, Traversable)

instance IsList (Env s) where
    type Item (Env s) = (Ident, s)
    fromList = Env . fromList
    toList = GHC.Exts.toList . fromEnv

-- | Primop mappings. The parameter specifies the monad the primops run in.
type Primops m = Map Ident ([Value Reference] -> Lang m (Value Reference))

-- | Bindings, either from the env or from the primops.
data Bindings m = Bindings
    { bindingsEnv     :: Env (Value Reference)
    , bindingsPrimops :: Primops m
    , bindingsRefs    :: IntMap (Value Reference)
    , bindingsNextRef :: Int
    } deriving (Generic)

instance Semigroup (Bindings m) where
    (<>) = mappend

instance Monoid (Bindings m) where
    mempty = Bindings
        { bindingsEnv = mempty
        , bindingsPrimops = mempty
        , bindingsRefs = mempty
        , bindingsNextRef = 0
        }
    a `mappend` b = Bindings
        { bindingsEnv = bindingsEnv a <> bindingsEnv b
        , bindingsPrimops = bindingsPrimops a <> bindingsPrimops b
        , bindingsRefs = bindingsRefs a
                      <> IntMap.mapKeys (+ bindingsNextRef a) (bindingsRefs b)
        , bindingsNextRef = bindingsNextRef a + bindingsNextRef b
        }

-- | The environment in which expressions are evaluated.
newtype LangT r m a = LangT
    { fromLangT :: ExceptT (LangError (Value Reference)) (StateT r m) a }
    deriving (Functor, Applicative, Monad, MonadError (LangError (Value Reference)), MonadState r)

instance MonadTrans (LangT r) where lift = LangT . lift . lift

-- | A monad for language operations specialized to have as state the Bindings
-- with appropriate underlying monad.
type Lang m = LangT (Bindings m) m

runLang
    :: Monad m
    => Bindings m
    -> Lang m a
    -> m (Either (LangError (Value Reference)) a, Bindings m)
runLang e l = runStateT (runExceptT $ fromLangT l) e


-- | Like 'local' or 'withState'
withEnv :: Monad m => (Bindings m -> Bindings m) -> Lang m a -> Lang m a
withEnv modifier action = do
    oldEnv <- get
    modify modifier
    res <- action
    put oldEnv
    pure res

-- * Functions

-- | A Bindings with an Env containing only 'eval' and only pure primops.
pureEnv :: (Monad m) => Bindings m
pureEnv = Bindings e purePrimops mempty 0
  where
    e = fromList [(toIdent "eval", Primop $ toIdent "base-eval")]

addBinding :: Monad m => Ident -> Value Reference -> Bindings m -> Bindings m
addBinding i v b = b
    { bindingsEnv = Env . Map.insert i v . fromEnv $ bindingsEnv b }

-- | Lookup an atom in the environment
lookupAtom :: Monad m => Ident -> Lang m (Value Reference)
lookupAtom i = get >>= \e -> case Map.lookup i . fromEnv $ bindingsEnv e of
    Nothing -> throwError $ UnknownIdentifier i
    Just v  -> pure v

-- | Lookup a primop.
lookupPrimop :: Monad m => Ident -> Lang m ([Value Reference] -> Lang m (Value Reference))
lookupPrimop i = get >>= \e -> case Map.lookup i $ bindingsPrimops e of
    Nothing -> throwError $ Impossible "Unknown primop"
    Just v  -> pure v

defineAtom :: Monad m => Ident -> Value Reference -> Lang m ()
defineAtom i v = modify $ addBinding i v

quote :: Value r -> Value r
quote v = List [Primop (Ident "quote"), v]

-- | The universal primops. These are available in chain evaluation, and are
-- not shadowable via 'define'.
purePrimops :: forall m. (Monad m) => Primops m
purePrimops = Map.fromList $ first Ident <$>
    [ ("base-eval", evalArgs $ \args -> case args of
          [x] -> baseEval x
          xs  -> throwError $ WrongNumberOfArgs "base-eval" 1 (length xs))
    , ("list", evalArgs $ \args -> pure $ List args)
    , ("quote", \args -> case args of
          [v] -> pure v
          xs  -> throwError $ WrongNumberOfArgs "quote" 1 (length xs))
    , ("define", \args -> case args of
          [Atom name, val] -> do
              val' <- baseEval val
              defineAtom name val'
              pure nil
          [_, _]           -> throwError $ OtherError "define expects atom for first arg"
          xs               -> throwError $ WrongNumberOfArgs "define" 2 (length xs))
    , ("catch", \args -> case args of
          [l, form, handler] -> do
              mlabel <- baseEval l
              case mlabel of
                  Atom label -> baseEval form `catchError` \e -> do
                     (thrownLabel, thrownValue) <- errorToValue e
                     if thrownLabel == label || label == Ident "any"
                         then handler $$ [thrownValue]
                         else baseEval form
                  _ -> throwError $ TypeError "catch: first argument must be atom"
          xs -> throwError $ WrongNumberOfArgs "catch" 3 (length xs))
    , ("throw", evalArgs $ \args -> case args of
          [Atom label, exc] -> throwError $ ThrownError label exc
          [_, _]            -> throwError $ TypeError "throw: first argument must be atom"
          xs                -> throwError $ WrongNumberOfArgs "throw" 2 (length xs))
    , ("eq?", evalArgs $ \args -> case args of
          [a, b] -> pure $ Boolean (a == b)
          xs     -> throwError $ WrongNumberOfArgs "eq?" 2 (length xs))
    , ("cons", evalArgs $ \args -> case args of
          [x, List xs] -> pure $ List (x:xs)
          [_, _]       -> throwError $ TypeError "cons: second argument must be list"
          xs           -> throwError $ WrongNumberOfArgs "cons" 2 (length xs))
    , ("head", evalArgs $ \args -> case args of
          [List (x:_)] -> pure x
          [List []]    -> throwError $ OtherError "head: empty list"
          [_]          -> throwError $ TypeError "head: expects list argument"
          xs           -> throwError $ WrongNumberOfArgs "head" 1 (length xs))
    , ("tail", evalArgs $ \args -> case args of
          [List (_:xs)] -> pure $ List xs
          [List []]     -> throwError $ OtherError "tail: empty list"
          [_]           -> throwError $ TypeError "tail: expects list argument"
          xs            -> throwError $ WrongNumberOfArgs "tail" 1 (length xs))
    , ("lookup", evalArgs $ \args -> case args of
          [Atom a, Dict m] -> pure $ case Map.lookup a m of
              Just v  -> v
              -- Probably an exception is better, but that seems cruel
              -- when you have no exception handling facilities.
              Nothing -> nil
          [Atom _, _]           -> throwError
                                 $ TypeError "lookup: second argument must be map"
          [_, Dict _]      -> throwError
                                 $ TypeError "lookup: first argument must be atom"
          xs -> throwError $ WrongNumberOfArgs "lookup" 2 (length xs))
    , ("string-append", evalArgs $ \args ->
          let fromStr (String s) = Just s
              fromStr _          = Nothing
              ss = fromStr <$> args
          in if all isJust ss
              then pure . String . mconcat $ catMaybes ss
              else throwError $ TypeError "string-append: non-string argument")
    , ("insert", evalArgs $ \args -> case args of
          [Atom k, v, Dict m] -> pure . Dict $ Map.insert k v m
          [Atom _, _, _]           -> throwError
                                    $ TypeError "insert: third argument must be map"
          [_, _, _]                -> throwError
                                    $ TypeError "insert: first argument must be an atom"
          xs -> throwError $ WrongNumberOfArgs "insert" 3 (length xs))
    -- The semantics of + and - in Scheme is a little messed up. (+ 3)
    -- evaluates to 3, and of (- 3) to -3. That's pretty intuitive.
    -- But while (+ 3 2 1) evaluates to 6, (- 3 2 1) evaluates to 0. So with -
    -- it is *not* correct to say that it's a foldl (-) 0. Instead, it
    -- special-cases on one-argument application. (Similarly with * and /.)
    --
    -- In order to avoid this sort of thing, we don't allow +,*,- and / to be
    -- applied to a single argument.
    , numBinop (+) "+"
    , numBinop (*) "*"
    , numBinop (-) "-"
    , ("<", evalArgs $ \args -> case args of
          [Number x, Number y] -> pure $ Boolean (x < y)
          [_, _]               -> throwError $ TypeError "<: expecting number"
          xs                   -> throwError $ WrongNumberOfArgs "<" 2 (length xs))
    , (">", evalArgs $ \args -> case args of
          [Number x, Number y] -> pure $ Boolean (x > y)
          [_, _]               -> throwError $ TypeError ">: expecting number"
          xs                   -> throwError $ WrongNumberOfArgs ">" 2 (length xs))
    , ("foldl", evalArgs $ \args -> case args of
          [fn, init', List ls] -> foldlM (\b a -> (fn $$) [b,a]) init' ls
          [_, _, _]            -> throwError
                                $ TypeError "foldl: third argument should be a list"
          xs                   -> throwError $ WrongNumberOfArgs "foldl" 3 (length xs))
    , ("foldr", evalArgs $ \args -> case args of
          [fn, init', List ls] -> foldrM (\b a -> (fn $$) [b,a]) init' ls
          [_, _, _]            -> throwError
                                $ TypeError "foldr: third argument should be a list"
          xs                   -> throwError $ WrongNumberOfArgs "foldr" 3 (length xs))
    , ("map", evalArgs $ \args -> case args of
          [fn, List ls] -> List <$> traverse (fn $$) (pure <$> ls)
          [_, _]        -> throwError $ TypeError "map: second argument should be a list"
          xs            -> throwError $ WrongNumberOfArgs "map" 3 (length xs))
    , ("string?", evalArgs $ \args -> case args of
          [String _] -> pure $ Boolean True
          [_]        -> pure $ Boolean False
          xs         -> throwError $ WrongNumberOfArgs "string?" 1 (length xs))
    , ("boolean?", evalArgs $ \args -> case args of
          [Boolean _] -> pure $ Boolean True
          [_]         -> pure $ Boolean False
          xs          -> throwError $ WrongNumberOfArgs "boolean?" 1 (length xs))
    , ("number?", evalArgs $ \args -> case args of
          [Number _] -> pure $ Boolean True
          [_]        -> pure $ Boolean False
          xs         -> throwError $ WrongNumberOfArgs "number?" 1 (length xs))
    , ("member?", evalArgs $ \args -> case args of
          [x, List xs] -> pure . Boolean $ elem x xs
          [_, _]       -> throwError
                        $ TypeError "member?: second argument must be list"
          xs           -> throwError $ WrongNumberOfArgs "eq?" 2 (length xs))
    , ("if", \args -> case args of
          [cond, t, f] -> do
            b <- baseEval cond
            -- I hate this as much as everyone that might ever read Haskell, but
            -- in Lisps a lot of things that one might object to are True...
            if b == Boolean False then baseEval f else baseEval t
          xs -> throwError $ WrongNumberOfArgs "if" 3 (length xs))
    , ("read-ref", evalArgs $ \args -> case args of
          [Ref (Reference x)] -> gets bindingsRefs >>= \m -> case IntMap.lookup x m of
              Nothing -> throwError $ Impossible "undefined reference"
              Just v  -> pure v
          [_]                 -> throwError $ TypeError "read-ref: argument must be a ref"
          xs                  -> throwError $ WrongNumberOfArgs "read-ref" 1 (length xs))
    , ("write-ref", evalArgs $ \args -> case args of
          [Ref (Reference x), v] -> do
              st <- get
              put $ st { bindingsRefs = IntMap.insert x v $ bindingsRefs st }
              pure nil
          [_, _]                 -> throwError
                                  $ TypeError "write-ref: first argument must be a ref"
          xs                     -> throwError
                                  $ WrongNumberOfArgs "write-ref" 2 (length xs))
    ]
  where
    -- Many primops evaluate their arguments just as normal functions do.
    evalArgs f args = traverse baseEval args >>= f

    numBinop :: (Scientific -> Scientific -> Scientific)
             -> Text
             -> (Text, [Value Reference] -> Lang m (Value Reference))
    numBinop fn name = (name, evalArgs $ \args -> case args of
        Number x:x':xs -> foldM go (Number x) (x':xs)
          where
            go (Number a) (Number b) = pure . Number $ fn a b
            go _ _ = throwError . TypeError
                   $ name <> ": expecting number"
        [Number _] -> throwError
                    $ OtherError $ name <> ": expects at least 2 arguments"
        _ -> throwError $ TypeError $ name <> ": expecting number")

-- * Eval

-- | The buck-passing eval. Uses whatever 'eval' is in scope.
eval :: Monad m => Value Reference -> Lang m (Value Reference)
eval val = do
    e <- lookupAtom (toIdent "eval")
    case e of
        Primop i -> do
            fn <- lookupPrimop i
            -- Primops get to decide whether and how their args are
            -- evaluated.
            fn [quote val]
        Lambda _ _ Nothing -> throwError $ Impossible
            "lambda should already have an env"
        Lambda [bnd] body (Just closure) -> do
              let mappings = fromList [(bnd, val)]
                  modEnv = mappings <> closure
              NonEmpty.last <$> withEnv (\e' -> e' { bindingsEnv = modEnv})
                                        (traverse eval body)
        _ -> throwError $ TypeError "Trying to apply a non-function"

-- | The built-in, original, eval.
baseEval :: Monad m => Value Reference -> Lang m (Value Reference)
baseEval val = case val of
    Atom i -> lookupAtom i
    Ref i -> pure $ Ref i
    List (f:vs) -> f $$ vs
    List xs -> throwError
        $ WrongNumberOfArgs ("application: " <> T.pack (show xs))
                            2
                            (length xs)
    String s -> pure $ String s
    Number n -> pure $ Number n
    Boolean b -> pure $ Boolean b
    Primop i -> pure $ Primop i
    e@(Lambda _ _ (Just _)) -> pure e
    Lambda args body Nothing -> gets $ Lambda args body . Just . bindingsEnv
    Dict mp -> do
        let evalSnd (a,b) = (a ,) <$> baseEval b
        Dict . Map.fromList <$> traverse evalSnd (Map.toList mp)



-- * Helpers

-- | Infix function application
infixr 1 $$
($$) :: Monad m => Value Reference -> [Value Reference] -> Lang m (Value Reference)
mfn $$ vs = do
    mfn' <- baseEval mfn
    case mfn' of
        Primop i -> do
            fn <- lookupPrimop i
            -- Primops get to decide whether and how their args are
            -- evaluated.
            fn vs
        -- This happens if a quoted lambda is explicitly evaled. We then
        -- give it the current environment.
        Lambda bnds body Nothing ->
            if length bnds /= length vs
                then throwError $ WrongNumberOfArgs "lambda" (length bnds)
                                                             (length vs)
                else do
                    vs' <- traverse baseEval vs
                    let mappings = fromList (zip bnds vs')
                    NonEmpty.last <$> withEnv
                        (\e -> e { bindingsEnv = mappings <> bindingsEnv e })
                        (traverse baseEval body)
        Lambda bnds body (Just closure) ->
            if length bnds /= length vs
                then throwError $ WrongNumberOfArgs "lambda" (length bnds)
                                                             (length vs)
                else do
                    vs' <- traverse baseEval vs
                    let mappings = fromList (zip bnds vs')
                        modEnv = mappings <> closure
                    NonEmpty.last <$> withEnv (\e -> e { bindingsEnv = modEnv })
                                              (traverse baseEval body)
        _ -> throwError $ TypeError "Trying to apply a non-function"

nil :: Value r
nil = List []

-- TH
-- Needed for the Eq and Show instances for Fix.
deriveEq1 ''Env
deriveEq1 ''Value
deriveShow1 ''Env
deriveShow1 ''Value
