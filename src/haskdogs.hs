{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, ViewPatterns, NoImplicitPrelude, ExtendedDefaultRules #-}
module Main (main) where

import ClassyPrelude.Conduit
import Data.Conduit.Shell (run, proc, conduit, ($|), Segment, ProcessException(..), CmdArg(..))
import Data.Conduit.Shell.PATH (test, cd, which, mkdir)
import qualified Data.Conduit.List as C
import qualified Data.Conduit.Binary as C
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L
import Data.List (nub)
import System.IO (openFile, IOMode(..))
import System.Directory (getHomeDirectory)

default (ByteString)

proc' :: CmdArg a => String -> [a] -> Segment ()
proc' a l = proc a (map (unpack . toTextArg) l)

stack_exec :: (CmdArg a, IsString a) => a -> [a] -> Segment ()
stack_exec cmd args = proc' "stack" (["exec", cmd, "--"] ++ args)

runOutput :: Segment () -> IO L.ByteString
runOutput cmd = do
    chunks <- run (cmd $| conduit C.consume)
    return $ L.fromChunks chunks

eprint :: (IOData a, MonadIO m) => a -> m ()
eprint = hPutStrLn stderr


-- Finds *hs in current dir, recursively
findSources :: [FilePath] -> IO [FilePath]
findSources dirs = do
    run (proc_find $| conduit (C.lines =$= C.map B.unpack =$= C.consume))
  where
    proc_find = proc' "find" $ dirs <> words "-type f -and ( -name *\\.hs -or -name *\\.lhs )"

grepImports :: ByteString -> Maybe ByteString
grepImports line = case B.words line of
    ("import":"qualified":x:_) -> Just x
    ("import":x:_) -> Just x
    _ -> Nothing

-- Produces list of imported modules for file.hs given
findModules :: [FilePath] -> IO [ByteString]
findModules files = do
    runResourceT $ forM_ files sourceFile $$
             ( C.lines
           =$= C.mapMaybe grepImports
           =$= C.consume
             )

-- Maps import name to haskell package name
iname2module :: ByteString -> IO (Maybe ByteString)
iname2module name = do
    out <- runOutput $
        stack_exec "ghc-pkg" ["--simple-output", "find-module", name]
    return $ do -- Maybe monad
        l <- lastMay (L.lines out)
        lbs <- headMay (L.words l)
        return $ L.toStrict lbs

inames2modules :: [ByteString] -> IO [FilePath]
inames2modules is = map B.unpack . nub . sort . catMaybes <$> forM is (iname2module)

testdir :: FilePath -> IO a -> IO a -> IO a
testdir dir fyes fno = do
    (ret :: Either ProcessException ()) <- try $ run $ test "-d" dir
    either (const fno) (const fyes) ret

-- Unapcks haskel package to the sourcedir
unpackModule :: FilePath -> IO (Maybe FilePath)
unpackModule p = do
    srcdir <- sourcedir
    let fullpath = srcdir </> p
    testdir fullpath
        (do
            eprint $ "Already unpacked " ++ p
            return (Just fullpath)
        )
        (do
            cd srcdir
            (run (proc' "stack" ["unpack", p]) >> return (Just fullpath)) `catch` (\(_ :: ProcessException) -> do
                eprint ("Can't unpack " ++ p)
                return Nothing)
        )

unpackModules :: [FilePath] -> IO [FilePath]
unpackModules ms = catMaybes <$> mapM unpackModule ms

-- Run GNU which tool
checkapp :: String -> IO ()
checkapp appname = do
    run (which appname) `onException`
            eprint ("Please Install \"" ++ appname ++ "\" application")

-- Directory to unpack sources into
sourcedir :: IO FilePath
sourcedir = do
    home <- getHomeDirectory
    return $ home </> ".haskdogs"

gentags :: [Text] -> [Text] -> IO ()
gentags (map unpack -> dirs) (map unpack -> flags) = do
    checkapp "stack"
    checkapp "hasktags"
    d <- sourcedir
    testdir d (return ()) (run $ mkdir "-p" d)
    files <- do
      ss_local <- findSources dirs
      when (null ss_local) $ do
        fail $ "haskdogs were not able to find any sources in " <> (intercalate ", " dirs)
      ss_l1deps <- findModules ss_local >>= inames2modules >>= unpackModules >>= findSources
      return $ ss_local ++ ss_l1deps
    run $ proc' "hasktags" (flags ++ files)

help :: IO ()
help = do
    eprint "haskdogs: generates tags file for haskell project directory"
    eprint "Usage:"
    eprint "    haskdogs [-d (FILE|'-')] [FLAGS]"
    eprint "        FLAGS will be passed to hasktags as-is followed by"
    eprint "        a list of files. Defaults to -c -x."

defflags :: [Text]
defflags = ["-c", "-x"]

amain :: [Text] -> IO ()
amain [] = gentags ["."] defflags
amain ("-d" : dirfile : flags) = do
    file <- if (dirfile=="-") then return stdin else openFile (unpack dirfile) ReadMode
    dirs <- lines <$> hGetContents file
    gentags dirs (if null flags then defflags else flags)
amain flags
  | "-h"     `elem` flags = help
  | "--help" `elem` flags = help
  | "-?"     `elem` flags = help
  | otherwise = gentags ["."] flags

main :: IO()
main = getArgs >>= amain
