{-# LANGUAGE CPP #-}
{-# LANGUAGE MultiWayIf #-}

module Runner (
  runModules
, Summary(..)
) where

import           Prelude hiding (putStr, putStrLn, error)

import           Control.Concurrent (Chan, writeChan, readChan, newChan, forkIO)
import           Control.Exception (SomeException, catch)
import           Control.Monad hiding (forM_)
import           Text.Printf (printf)
import           System.IO (hPutStrLn, hPutStr, stderr, hIsTerminalDevice)
import           Data.Foldable (forM_)

import           Control.Monad.Trans.State
import           Control.Monad.IO.Class

import           Interpreter (Interpreter)
import qualified Interpreter
import           Parse
import           Options (ModuleName)
import           Location
import           Property
import           Runner.Example

import           System.IO.CodePage (withCP65001)

-- | Whether an "example" is part of setup block
data FromSetup = FromSetup | NotFromSetup

-- | Summary of a test run.
data Summary = Summary {
  sExamples :: Int
, sTried    :: Int
, sErrors   :: Int
, sFailures :: Int
} deriving Eq

-- | Format a summary.
instance Show Summary where
  show (Summary examples tried errors failures) =
    printf "Examples: %d  Tried: %d  Errors: %d  Failures: %d" examples tried errors failures


-- | Sum up summaries.
instance Monoid Summary where
  mempty = Summary 0 0 0 0

instance Semigroup Summary where
  (<>) (Summary x1 x2 x3 x4) (Summary y1 y2 y3 y4) =
    Summary (x1 + y1) (x2 + y2) (x3 + y3) (x4 + y4)

-- | Run all examples from a list of modules.
runModules
  :: Bool
  -- ^ Fast mode
  -> Bool
  -- ^ Preserve it
  -> Bool
  -- ^ Verbose
  -> Bool
  -- ^ Implicit Prelude
  -> [String]
  -- ^ Arguments passed to the GHCi process.
  -> [Module [Located DocTest]]
  -- ^ Modules under test
  -> IO Summary
runModules fastMode preserveIt verbose implicitPrelude args modules = do
  isInteractive <- hIsTerminalDevice stderr

  -- Start a thread pool. It sends status updates to this thread through 'output'.
  (input, output) <- makeThreadPool 24 (runModule fastMode preserveIt implicitPrelude args)

  -- Send instructions to threads
  liftIO (mapM_ (writeChan input) modules)

  let
    nExamples = (sum . map count) modules
    initState = ReportState 0 isInteractive verbose mempty {sExamples = nExamples}

  ReportState _ _ _ s <- (`execStateT` initState) $ do
    consumeUpdates output (length modules)
    verboseReport "# Final summary:"
    gets (show . reportStateSummary) >>= report

  return s
 where
  consumeUpdates _output 0 = pure ()
  consumeUpdates output modsLeft = do
    update <- liftIO (readChan output)
    consumeUpdates output =<<
      case update of
        UpdateInternalError loc e -> reportInternalError loc e >> pure (modsLeft - 1)
        UpdateImportError modName -> reportImportError modName >> pure (modsLeft - 1)
        UpdateSuccess fs loc -> reportSuccess fs loc >> reportProgress >> pure modsLeft
        UpdateFailure fs loc expr errs -> reportFailure fs loc expr errs >> pure modsLeft
        UpdateError fs loc expr err -> reportError fs loc expr err >> pure modsLeft
        UpdateVerbose msg -> verboseReport msg >> pure modsLeft
        UpdateStart loc expr msg -> reportStart loc expr msg >> pure modsLeft
        UpdateModuleDone -> pure (modsLeft - 1)

-- | Count number of expressions in given module.
count :: Module [Located DocTest] -> Int
count (Module _ _ tests) = sum (map length tests)

-- | A monad for generating test reports.
type Report = StateT ReportState IO

data ReportState = ReportState {
  reportStateCount        :: Int     -- ^ characters on the current line
, reportStateInteractive  :: Bool    -- ^ should intermediate results be printed?
, reportStateVerbose      :: Bool
, reportStateSummary      :: Summary -- ^ test summary
}

-- | Add output to the report.
report :: String -> Report ()
report msg = do
  overwrite msg

  -- add a newline, this makes the output permanent
  liftIO $ hPutStrLn stderr ""
  modify (\st -> st {reportStateCount = 0})

-- | Add intermediate output to the report.
--
-- This will be overwritten by subsequent calls to `report`/`report_`.
-- Intermediate out may not contain any newlines.
report_ :: String -> Report ()
report_ msg = do
  f <- gets reportStateInteractive
  when f $ do
    overwrite msg
    modify (\st -> st {reportStateCount = length msg})

-- | Add output to the report, overwrite any intermediate out.
overwrite :: String -> Report ()
overwrite msg = do
  n <- gets reportStateCount
  let str | 0 < n     = "\r" ++ msg ++ replicate (n - length msg) ' '
          | otherwise = msg
  liftIO (hPutStr stderr str)

-- | Run all examples from given module.
runModule
  :: Bool
  -> Bool
  -> Bool
  -> [String]
  -> Chan ReportUpdate
  -> Module [Located DocTest]
  -> IO ()
runModule fastMode preserveIt implicitPrelude ghciArgs output (Module module_ setup examples) = do
  Interpreter.withInterpreter ghciArgs $ \repl -> withCP65001 $ do
    -- Try to import this module, if it fails, something is off
    importResult <- Interpreter.safeEval repl importModule
    case importResult of
      Right "" -> do
        -- Run setup group
        successes <- mapM (runTestGroup FromSetup preserveIt repl (reload repl) output) setup

        -- only run tests, if setup does not produce any errors/failures
        when
          (and successes)
          (mapM_ (runTestGroup NotFromSetup preserveIt repl (setup_ repl) output) examples)
      _ ->
        writeChan output (UpdateImportError module_)

    -- Signal main thread a module has been tested
    writeChan output UpdateModuleDone

    pure ()

  where
    importModule = ":m +" ++ module_

    reload repl = do
      unless fastMode $
        void $ Interpreter.safeEval repl ":reload"

      mapM_ (Interpreter.safeEval repl) $
        if implicitPrelude
        then [":m Prelude", importModule]
        else [":m +" ++ module_]

      when preserveIt $
        -- Evaluate a dumb expression to populate the 'it' variable NOTE: This is
        -- one reason why we cannot have safeEval = safeEvalIt: 'it' isn't set in
        -- a fresh GHCi session.
        void $ Interpreter.safeEval repl $ "()"

    setup_ repl = do
      reload repl
      forM_ setup $ \l -> forM_ l $ \(Located _ x) -> case x of
        Property _  -> return ()
        Example e _ -> void $ safeEvalWith preserveIt repl e

data ReportUpdate
  = UpdateSuccess FromSetup Location
  -- ^ Test succeeded
  | UpdateFailure FromSetup Location Expression [String]
  -- ^ Test failed with unexpected result
  | UpdateError FromSetup Location Expression String
  -- ^ Test failed with an error
  | UpdateVerbose String
  -- ^ Message to send when verbose output is activated
  | UpdateModuleDone
  -- ^ All examples tested in module
  | UpdateStart Location Expression String
  -- ^ Indicate test has started executing (verbose output)
  | UpdateInternalError (Module [Located DocTest]) SomeException
  -- ^ Exception caught while executing internal code
  | UpdateImportError ModuleName
  -- ^ Could not import module

makeThreadPool ::
  Int ->
  (Chan ReportUpdate -> Module [Located DocTest] -> IO ()) ->
  IO (Chan (Module [Located DocTest]), Chan ReportUpdate)
makeThreadPool nThreads mutator = do
  input <- newChan
  output <- newChan
  forM_ [1..nThreads] $ \_ ->
    forkIO $ forever $ do
      i <- readChan input
      catch
        (mutator output i)
        (\e -> writeChan output (UpdateInternalError i e))
  return (input, output)

reportStart :: Location -> Expression -> String -> Report ()
reportStart loc expression testType = do
  verboseReport (printf "### Started execution at %s.\n### %s:\n%s" (show loc) testType expression)

reportFailure :: FromSetup -> Location -> Expression -> [String] -> Report ()
reportFailure fromSetup loc expression err = do
  report (printf "%s: failure in expression `%s'" (show loc) expression)
  mapM_ report err
  report ""
  updateSummary fromSetup (Summary 0 1 0 1)

reportError :: FromSetup -> Location -> Expression -> String -> Report ()
reportError fromSetup loc expression err = do
  report (printf "%s: error in expression `%s'" (show loc) expression)
  report err
  report ""
  updateSummary fromSetup (Summary 0 1 1 0)

reportInternalError :: Module a -> SomeException -> Report ()
reportInternalError mod_ err = do
  report (printf "Internal error when executing tests in %s" (moduleName mod_))
  report (show err)
  report ""

reportImportError :: ModuleName -> Report ()
reportImportError modName = do
  report ("Could not import module: " <> modName <> ". This can be caused by a number of issues: ")
  report ""
  report " 1. For Cabal users: Cabal did not generate a GHC environment file. Either:"
  report "   * Run with '--write-ghc-environment-files=always'"
  report "   * Add 'write-ghc-environment-files: always' to your cabal.project"
  report ""
  report " 2. The testsuite executable does not have a dependency on your project library. Please add it to the 'build-depends' section of the testsuite executable."
  report ""
  report "See the example project at https://github.com/martijnbastiaan/doctest-parallel/tree/master/examples for more information."

reportSuccess :: FromSetup -> Location -> Report ()
reportSuccess fromSetup loc = do
  verboseReport (printf "### Successful `%s'!\n" (show loc))
  updateSummary fromSetup (Summary 0 1 0 0)

verboseReport :: String -> Report ()
verboseReport xs = do
  verbose <- gets reportStateVerbose
  when verbose $ report xs

updateSummary :: FromSetup -> Summary -> Report ()
updateSummary FromSetup _summary = return ()
updateSummary NotFromSetup summary = do
  ReportState n f v s <- get
  put (ReportState n f v $ s `mappend` summary)

reportProgress :: Report ()
reportProgress = do
  verbose <- gets reportStateVerbose
  when (not verbose) $ gets (show . reportStateSummary) >>= report_

-- | Run given test group.
--
-- The interpreter state is zeroed with @:reload@ first.  This means that you
-- can reuse the same 'Interpreter' for several test groups.
runTestGroup ::
  FromSetup ->
  Bool ->
  Interpreter ->
  IO () ->
  Chan ReportUpdate ->
  [Located DocTest] ->
  IO Bool
runTestGroup fromSetup preserveIt repl setup output tests = do

  setup
  successExamples <- runExampleGroup fromSetup preserveIt repl output examples

  successesProperties <- forM properties $ \(loc, expression) -> do
    r <- do
      setup
      writeChan output (UpdateStart loc expression "property")
      runProperty repl expression

    case r of
      Success -> do
        writeChan output (UpdateSuccess fromSetup loc)
        pure True
      Error err -> do
        writeChan output (UpdateError fromSetup loc expression err)
        pure False
      Failure msg -> do
        writeChan output (UpdateFailure fromSetup loc expression [msg])
        pure False

  pure (successExamples && and successesProperties)
  where
    properties = [(loc, p) | Located loc (Property p) <- tests]

    examples :: [Located Interaction]
    examples = [Located loc (e, r) | Located loc (Example e r) <- tests]

-- |
-- Execute all expressions from given example in given 'Interpreter' and verify
-- the output.
runExampleGroup ::
  FromSetup ->
  Bool ->
  Interpreter ->
  Chan ReportUpdate ->
  [Located Interaction] ->
  IO Bool
runExampleGroup fromSetup preserveIt repl output = go
  where
    go ((Located loc (expression, expected)) : xs) = do
      writeChan output (UpdateStart loc expression "example")
      r <- fmap lines <$> safeEvalWith preserveIt repl expression
      case r of
        Left err -> do
          writeChan output (UpdateError fromSetup loc expression err)
          pure False
        Right actual -> case mkResult expected actual of
          NotEqual err -> do
            writeChan output (UpdateFailure fromSetup loc expression err)
            pure False
          Equal -> do
            writeChan output (UpdateSuccess fromSetup loc)
            go xs
    go [] =
      pure True

safeEvalWith :: Bool -> Interpreter -> String -> IO (Either String String)
safeEvalWith preserveIt
  | preserveIt = Interpreter.safeEvalIt
  | otherwise  = Interpreter.safeEval
