{-# LANGUAGE ScopedTypeVariables #-}
module Radicle.Internal.Subscriber where

import           Control.Monad (void, forever)
import           Control.Monad.Except (throwError)
import           Control.Monad.State (gets, get)
import           Data.Bifunctor (first)
import           Data.List (isPrefixOf)
import qualified Data.Map as Map
import           Data.Monoid ((<>))
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Prettyprint.Doc (pretty)
import           Data.Text.Prettyprint.Doc.Render.Terminal (putDoc)
import           System.Console.Haskeline (CompletionFunc, InputT, completeWord,
                                           defaultSettings, historyFile,
                                           runInputT, setComplete,
                                           simpleCompletion)

import           Radicle.Internal.Core
import           Radicle.Internal.Parse
import           Radicle.Internal.Pretty
import           Radicle.Internal.Subscriber.Capabilities


type ReplM m =
    ( Monad m, Stdout (Lang m), Stdin (Lang m)
    , GetEnv (Lang m) (Value Reference)
    , SetEnv (Lang m) (Value Reference) )

repl :: FilePath -> Text -> IO ()
repl histFile preCode = do
    let settings = setComplete completion
                 $ defaultSettings { historyFile = Just histFile }
    r <- runInputT settings
        $ fmap fst $ runLang replBindings
        $ void $ interpretMany "[pre]" preCode
    case r of
        Left Exit -> pure ()
        Left e    -> putDoc $ pretty e
        Right ()  -> pure ()

completion :: Monad m => CompletionFunc m
completion = completeWord Nothing ['(', ')', ' ', '\n'] go
  where
    -- Any type for first param will do
    bnds :: Bindings (InputT IO)
    bnds = replBindings

    go s = pure $ fmap simpleCompletion
         $ filter (s `isPrefixOf`)
         $ fmap (T.unpack . fromIdent)
         $ (Map.keys . fromEnv $ bindingsEnv bnds)
        <> Map.keys (bindingsPrimops bnds)

replBindings :: forall m. ReplM m => Bindings m
replBindings = e { bindingsPrimops = bindingsPrimops e <> replPrimops }
    where
      e :: Bindings m
      e = pureEnv

replPrimops :: forall m. ReplM m => Primops m
replPrimops = Map.fromList $ first toIdent <$>
    [ ("print!", \args -> case args of
        [x] -> do
            v <- eval x
            putStrS (renderPrettyDef v)
            pure nil
        xs  -> throwError $ WrongNumberOfArgs "print!" 1 (length xs))

    , ("set-env!", \args -> case args of
        [Atom x, v] -> do
            v' <- eval v
            defineAtom x v'
            pure nil
        [_, _] -> throwError $ TypeError "Expected atom as first arg"
        xs  -> throwError $ WrongNumberOfArgs "set-env!" 2 (length xs))

    , ("get-line!", \args -> case args of
        [] -> do
            ln <- getLineS
            allPrims <- gets bindingsPrimops
            let p = parse "[stdin]" ln (Map.keys allPrims)
            case p of
                Right v -> makeRefs v
                Left e -> throwError $ ThrownError (Ident "parse-error")
                                                   (String $ T.pack e)
        xs  -> throwError $ WrongNumberOfArgs "get-line!" 0 (length xs))

    , ("subscribe-to!", \args -> case args of
        [x, v] -> do
            x' <- eval x
            v' <- eval v
            s <- get
            case (x', v') of
                (Dict m, fn) -> case Map.lookup (toIdent "getter") m of
                    Nothing -> throwError
                        $ OtherError "subscribe-to!: Expected 'getter' key"
                    Just g -> forever go
                      where
                        go = do
                            -- We need to evaluate the getter in the original
                            -- environment in which it was defined, but the
                            -- /result/ of the getter is then evaluated in the
                            -- current environment.
                            line <- eval =<< (g $$ [])
                            -- Similarly, the application of the subscriber
                            -- function is evaluated in the original
                            -- environment.
                            void $ withEnv (const s) (fn $$ [quote line])
                _  -> throwError $ TypeError "subscribe-to!: Expected dict"
        xs  -> throwError $ WrongNumberOfArgs "subscribe-to!" 2 (length xs))
    ]
