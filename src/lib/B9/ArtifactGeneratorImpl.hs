module B9.ArtifactGeneratorImpl (assembleArchives,assembleMountedArtifacts) where

import B9.ArtifactGenerator
import B9.DiskImages
import B9.B9Monad
import B9.B9Config
import B9.ConfigUtils hiding (tell)

import Data.Data
import Data.List
import Data.Function
import Control.Arrow
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Error
import System.FilePath
import System.Directory
import Text.Printf
import Text.Show.Pretty (ppShow)

import Test.QuickCheck

-- | Run an artifact generator to produce the artifacts *not* including
-- 'MountDuringBuild' targets
assembleArchives :: ArtifactGenerator -> B9 [AssembledArtifact]
assembleArchives artGen =
  assemble (agFilterAssemblies (not . asIsMountedDuringBuild) artGen)

-- | Run an artifact generator to produce the artifacts for 'MountDuringBuild'
-- targets
assembleMountedArtifacts :: ArtifactGenerator -> B9 [AssembledArtifact]
assembleMountedArtifacts artGen =
  assemble (agFilterAssemblies asIsMountedDuringBuild artGen)

asIsMountedDuringBuild :: ArtifactAssembly -> Bool
asIsMountedDuringBuild (MountDuringBuild _) = True
asIsMountedDuringBuild _ = False

-- | Run an artifact generator to produce the artifacts.
assemble :: ArtifactGenerator -> B9 [AssembledArtifact]
assemble artGen = do
  b9cfgEnvVars <- envVars <$> getConfig
  buildId <- getBuildId
  buildDate <- getBuildDate
  let ag = parseArtifactGenerator artGen
      e = Environment
            ((buildDateKey, buildDate):(buildIdKey, buildId):b9cfgEnvVars)
            []
  case execCGParser ag e of
    Left (CGError err) ->
      error err
    Right igs ->
      case execIGEnv `mapM` igs of
        Left err ->
          error (printf "Failed to parse:\n%s\nError: %s"
                                   (ppShow artGen)
                                   err)
        Right is ->
          createAssembledArtifacts is

parseArtifactGenerator :: ArtifactGenerator -> CGParser ()
parseArtifactGenerator g =
  case g of
    Sources srcs gs ->
      withArtifactSources srcs (mapM_ parseArtifactGenerator gs)
    Let bs gs ->
      withBindings bs (mapM_ parseArtifactGenerator gs)
    Each keySet valueSets gs -> do
      allBindings <- eachBindingSet g keySet valueSets
      mapM_ ($ mapM_ parseArtifactGenerator gs)
            (withBindings <$> allBindings)
    Artifact iid assemblies ->
      writeInstanceGenerator iid assemblies
    EmptyArtifact ->
      return ()

withArtifactSources :: [ArtifactSource] -> CGParser () -> CGParser ()
withArtifactSources srcs = local (\ce -> ce {agSources = agSources ce ++ srcs})

withBindings :: [(String,String)] -> CGParser () -> CGParser ()
withBindings bs = local (addBindings bs)

addBindings :: [(String, String)] -> Environment -> Environment
addBindings newEnv ce =
  let newEnvSubst = map resolveBinding newEnv
      resolveBinding (k,v) = (k, subst oldEnv v)
      oldEnv = agEnv ce
  in ce { agEnv = nubBy ((==) `on` fst) (newEnvSubst ++ oldEnv)}

eachBindingSet :: ArtifactGenerator
               -> [String]
               -> [[String]]
               -> CGParser [[(String,String)]]
eachBindingSet g vars valueSets =
  if all ((== length vars) . length) valueSets
     then return (zip vars <$> valueSets)
     else (cgError (printf "Error in 'Each' binding during artifact \
                           \generation in:\n '%s'.\n\nThe variable list\n\
                           \%s\n has %i entries, but this binding set\n%s\n\n\
                           \has a different number of entries!\n"
                           (ppShow g)
                           (ppShow vars)
                           (length vars)
                           (ppShow (head (dropWhile ((== length vars) . length)
                                                    valueSets)))))

writeInstanceGenerator :: InstanceId -> [ArtifactAssembly] -> CGParser ()
writeInstanceGenerator (IID iidStrT) assemblies = do
  env@(Environment bindings _) <- ask
  iid <- either (throwError . CGError) (return . IID) (substE bindings iidStrT)
  let env' = addBindings [(instanceIdKey, iidStr)] env
      IID iidStr = iid
  tell [IG iid env' assemblies]

-- | Monad for creating Instance generators.
newtype CGParser a =
  CGParser { runCGParser :: WriterT [InstanceGenerator Environment]
                                   (ReaderT Environment
                                            (Either CGError))
                                   a
           }
  deriving ( Functor, Applicative, Monad
           , MonadReader Environment
           , MonadWriter [InstanceGenerator Environment]
           , MonadError CGError
           )

data Environment = Environment { agEnv :: [(String, String)]
                               , agSources :: [ArtifactSource] }
  deriving (Read, Show, Typeable, Data, Eq)

data InstanceGenerator e = IG InstanceId e [ArtifactAssembly]
  deriving (Read, Show, Typeable, Data, Eq)

newtype CGError = CGError String
  deriving (Read, Show, Typeable, Data, Eq, Error)

cgError :: String -> CGParser a
cgError msg = throwError (CGError msg)

execCGParser :: CGParser ()
             -> Environment
             -> Either CGError [InstanceGenerator Environment]
execCGParser = runReaderT . execWriterT . runCGParser

execIGEnv :: InstanceGenerator Environment
          -> Either String (InstanceGenerator [SourceGenerator])
execIGEnv (IG iid (Environment env sources) assemblies) = do
  IG iid <$> sourceGens <*> assemblies'
  where
    sourceGens = join <$> mapM (toSourceGen env) sources
    assemblies' = substAssembly `mapM` assemblies
      where
        substAssembly (CloudInit ts f) = CloudInit ts <$> substE env f
        substAssembly (MountDuringBuild d) = MountDuringBuild <$> substE env d

toSourceGen :: [(String, String)]
            -> ArtifactSource
            -> Either String [SourceGenerator]
toSourceGen env src =
  case src of
    Template f -> do
      f' <- substE env f
      return [SGConcat env [SGFrom SGT f'] KeepPerm (takeFileName f')]
    Templates fs ->
      join <$> mapM (toSourceGen env . Template) fs
    File f -> do
      f' <- substE env f
      return [SGConcat env [SGFrom SGF f'] KeepPerm (takeFileName f')]
    Files fs ->
      join <$> mapM (toSourceGen env . File) fs
    Concatenation t src' -> do
      sgs <- join <$> mapM (toSourceGen env) src'
      t' <- substE env t
      let froms = join (sgGetFroms <$> sgs)
      return [SGConcat env froms KeepPerm t']
    SetPermissions o g a src' -> do
      sgs <- join <$> mapM (toSourceGen env) src'
      mapM (setSGPerm o g a) sgs
    FromDirectory fromDir src' -> do
      sgs <- join <$> mapM (toSourceGen env) src'
      fromDir' <- substE env fromDir
      return (setSGFromDirectory fromDir' <$> sgs)
    IntoDirectory toDir src' -> do
      sgs <- join <$> mapM (toSourceGen env) src'
      toDir' <- substE env toDir
      return (setSGToDirectory toDir' <$> sgs)

createAssembledArtifacts :: [InstanceGenerator [SourceGenerator]]
                         -> B9 [AssembledArtifact]
createAssembledArtifacts igs = do
  buildDir <- getBuildDir
  let outDir = buildDir </> "artifact-instances"
  ensureDir (outDir ++ "/")
  generated <- generateSources outDir `mapM` igs
  createTargets `mapM` generated

generateSources :: FilePath
                -> InstanceGenerator [SourceGenerator]
                -> B9 (InstanceGenerator FilePath)
generateSources outDir (IG iid sgs assemblies) = do
  uiid@(IID uiidStr) <- generateUniqueIID iid
  dbgL (printf "generating sources for %s" uiidStr)
  let instanceDir = outDir </> uiidStr
  traceL (printf "generating sources for %s:\n%s\n" uiidStr (ppShow sgs))
  generateSourceTo instanceDir `mapM_` sgs
  return (IG uiid instanceDir assemblies)

createTargets :: InstanceGenerator FilePath -> B9 AssembledArtifact
createTargets (IG uiid@(IID uiidStr) instanceDir assemblies) = do
  targets <- createTarget instanceDir `mapM` assemblies
  dbgL (printf "assembled all artifacts for %s" uiidStr)
  return (AssembledArtifact uiid (join targets))

generateUniqueIID :: InstanceId -> B9 InstanceId
generateUniqueIID (IID iid) = do
  buildId <- getBuildId
  return (IID (printf "%s-%s" iid buildId))

generateSourceTo :: FilePath -> SourceGenerator -> B9 ()
generateSourceTo instanceDir (SGConcat env froms p to) = do
  let toAbs = instanceDir </> to
  ensureDir toAbs
  case froms of
    [from] ->
      sgProcess env from toAbs
    [] ->
      error (printf "File '%s' has no sources." toAbs)
    _froms -> do
      let tmpTos = zipWith (<.>) (repeat toAbs) (show <$> [1..length froms])
          tmpTosQ = intercalate " " (printf "'%s'" <$> tmpTos)
      mapM_ (uncurry (sgProcess env)) (froms `zip` tmpTos)
      cmd (printf "cat %s > '%s'" tmpTosQ toAbs)
      cmd (printf "rm %s" tmpTosQ)
  sgChangePerm toAbs p

sgProcess :: [(String,String)] -> SGFrom -> FilePath -> B9 ()
sgProcess _ (SGFrom SGF f) t = do
  traceL (printf "copy '%s' to '%s'" f t)
  liftIO (copyFile f t)
sgProcess env (SGFrom SGT f) t = do
  traceL (printf "translate '%s' to '%s'" f t)
  substFile env f t

sgChangePerm :: FilePath -> SGPerm -> B9 ()
sgChangePerm _ KeepPerm = return ()
sgChangePerm f (SGSetPerm (o,g,a)) = cmd (printf "chmod 0%i%i%i '%s'" o g a f)

-- | Internal data type simplifying the rather complex source generation by
--   bioling down 'ArtifactSource's to a flat list of uniform 'SourceGenerator's.
data SourceGenerator = SGConcat [(String,String)] [SGFrom] SGPerm FilePath
  deriving (Read, Show, Typeable, Data, Eq)
data SGFrom = SGFrom SGType FilePath
  deriving (Read, Show, Typeable, Data, Eq)
data SGType = SGT | SGF
  deriving (Read, Show, Typeable, Data, Eq)
data SGPerm = SGSetPerm (Int,Int,Int) | KeepPerm
  deriving (Read, Show, Typeable, Data, Eq)

sgGetFroms :: SourceGenerator -> [SGFrom]
sgGetFroms (SGConcat _ fs _ _) = fs

setSGPerm :: Int -> Int -> Int -> SourceGenerator
          -> Either String SourceGenerator
setSGPerm o g a (SGConcat env from KeepPerm dest) =
  Right (SGConcat env from (SGSetPerm (o,g,a)) dest)
setSGPerm o g a sg
  | o < 0 || o > 7 =
    Left (printf "Bad 'owner' permission %i in \n%s" o (ppShow sg))
  | g < 0 || g > 7 =
    Left (printf "Bad 'group' permission %i in \n%s" g (ppShow sg))
  | a < 0 || a > 7 =
    Left (printf "Bad 'all' permission %i in \n%s" a (ppShow sg))
  | otherwise =
   Left (printf "Permission for source already defined:\n %s" (ppShow sg))

setSGFromDirectory :: FilePath -> SourceGenerator -> SourceGenerator
setSGFromDirectory fromDir (SGConcat e fs p d) =
  SGConcat e (setSGFrom <$> fs) p d
  where
    setSGFrom (SGFrom t f) = SGFrom t (fromDir </> f)

setSGToDirectory :: FilePath -> SourceGenerator -> SourceGenerator
setSGToDirectory toDir (SGConcat e fs p d) =
  SGConcat e fs p (toDir </> d)

-- | Create the actual target, either just a mountpoint, or an ISO or VFAT
-- image.
createTarget :: FilePath -> ArtifactAssembly -> B9 [ArtifactTarget]
createTarget instanceDir (MountDuringBuild mountPoint) = do
  dbgL (printf "add config mount point '%s' -> '%s'"
               instanceDir mountPoint)
  infoL (printf "MOUNTED CI_DIR '%s' TO '%s'"
                (takeFileName instanceDir) mountPoint)
  return [ArtifactMount instanceDir (MountPoint mountPoint)]
createTarget instanceDir (CloudInit types outPath) = do
  mapM create_ types
  where
    create_ CI_DIR = do
      let ciDir = outPath
      ensureDir (ciDir ++ "/")
      dbgL (printf "creating directory '%s'" ciDir)
      files <- getDirectoryFiles instanceDir
      traceL (printf "copying files: %s" (show files))
      liftIO (mapM_
                (\(f,t) -> do
                   ensureDir t
                   copyFile f t)
                (((instanceDir </>) &&& (ciDir </>)) <$> files))
      infoL (printf "CREATED CI_DIR: '%s'" (takeFileName ciDir))
      return (CloudInitTarget CI_DIR ciDir)

    create_ CI_ISO = do
      buildDir <- getBuildDir
      let isoFile = outPath <.> "iso"
          tmpFile = buildDir </> takeFileName isoFile
      ensureDir tmpFile
      dbgL (printf "creating cloud init iso temp image '%s',\
                   \ destination file: '%s" tmpFile isoFile)
      cmd (printf "genisoimage\
                  \ -output '%s'\
                  \ -volid cidata\
                  \ -rock\
                  \ -d '%s' 2>&1"
                  tmpFile
                  instanceDir)
      dbgL (printf "moving iso image '%s' to '%s'" tmpFile isoFile)
      ensureDir isoFile
      liftIO (copyFile tmpFile isoFile)
      infoL (printf "CREATED CI_ISO IMAGE: '%s'" (takeFileName isoFile))
      return (CloudInitTarget CI_ISO isoFile)

    create_ CI_VFAT = do
      buildDir <- getBuildDir
      let vfatFile = outPath <.> "vfat"
          tmpFile = buildDir </> takeFileName vfatFile
      ensureDir tmpFile
      files <- (map (instanceDir </>)) <$> getDirectoryFiles instanceDir
      dbgL (printf "creating cloud init vfat image '%s'" tmpFile)
      traceL (printf "adding '%s'" (show files))
      cmd (printf "truncate --size 2M '%s'" tmpFile)
      cmd (printf "mkfs.vfat -n cidata '%s' 2>&1" tmpFile)
      cmd (intercalate " " ((printf "mcopy -oi '%s' " tmpFile)
                            : (printf "'%s'" <$> files))
           ++ " ::")
      dbgL (printf "moving vfat image '%s' to '%s'" tmpFile vfatFile)
      ensureDir vfatFile
      liftIO (copyFile tmpFile vfatFile)
      infoL (printf "CREATED CI_VFAT IMAGE: '%s'" (takeFileName vfatFile))
      return (CloudInitTarget CI_ISO vfatFile)

-- * tests

test_GenerateNoInstanceGeneratorsForEmptyArtifact =
  let (Right igs) = execCGParser (parseArtifactGenerator EmptyArtifact) undefined
  in igs == []

prop_GenerateNoInstanceGeneratorsForArtifactWithoutArtifactInstance =
  forAll (arbitrary `suchThat` (not . containsArtifactInstance))
         (\g -> execCGParser (parseArtifactGenerator g) undefined == Right [])
  where
    containsArtifactInstance g =
      let nested = case g of
                     Sources _ gs -> gs
                     Let _ gs -> gs
                     Each _ _ gs -> gs
                     Artifact _ _ -> []
                     EmptyArtifact -> []
      in any containsArtifactInstance nested