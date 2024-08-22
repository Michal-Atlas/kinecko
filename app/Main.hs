import Control.Monad
import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.Maybe
import Data.Text qualified as Text
import Network.API.TheMovieDB
import Network.HTTP.Simple
import System.Directory
import System.Environment
import System.Process

getKey :: IO Key
getKey = Text.pack <$> getEnv "TMDB_KEY"

run :: TheMovieDB a -> IO (Either Error a)
run i = do
  key <- getKey
  runTheMovieDB (defaultSettings key) i

loadIDs :: FilePath -> IO [ItemID]
loadIDs file = do
  idStrs <- readFile file
  return $ read <$> lines idStrs

type URL = Text.Text

idToUrl :: Configuration -> ItemID -> TheMovieDB [URL]
idToUrl conf movieID = do
  movie <- fetchMovie movieID
  return $ moviePosterURLs conf movie

configFile :: FilePath
configFile = "config.json"

listMovies :: FilePath -> IO (Either Error [Text.Text])
listMovies file =
  do
    ids <- loadIDs file
    l <- run $ mapM fetchMovie ids
    return $ map movieTitle <$> l

getCachedConfig :: IO Configuration
getCachedConfig = do
  exists <- doesFileExist configFile
  if exists
    then do
      mconf <- JSON.decodeFileStrict configFile
      return $ fromMaybe (error "Failed to decode config.json") mconf
    else do
      mconf <- run config
      let conf = case mconf of
            Left e -> error $ show e
            Right c -> c
      JSON.encodeFile configFile conf
      return conf

downloadDir :: FilePath
downloadDir = "store"

idToFilePath :: ItemID -> FilePath
idToFilePath item = downloadDir ++ "/" ++ show item ++ ".jpg"

ensureFile :: ItemID -> URL -> IO FilePath
ensureFile item url = do
  exists <- doesFileExist path
  when
    exists
    ( do
        putStr "Item "
        putStr $ show item
        putStrLn " already present"
    )
  unless
    exists
    ( do
        putStr "Will download item "
        putStr $ item
        putStr "... "
        do
          req <- parseRequest $ Text.unpack url
          imgData <- httpBS req
          BS.writeFile path $ getResponseBody imgData
        putStrLn "done"
    )

  return path
  where
    path = idToFilePath item

ensureDownloaded :: [(ItemID, URL)] -> IO [FilePath]
ensureDownloaded inp = do
  createDirectoryIfMissing True downloadDir
  mapM (uncurry ensureFile) inp

generateMontage :: [FilePath] -> IO ()
generateMontage files = do
  callProcess "gmic" $
    files
      ++ [ "rr2d",
           "2000,1000",
           "frame",
           ",3,0,0,0",
           "pack",
           "1,-k",
           "output",
           "output.jpg"
         ]

main :: IO ()
main = do
  args <- getArgs
  let file = fromMaybe (error "Give me file of IDs") $ listToMaybe args
  ids <- loadIDs file
  conf <- getCachedConfig
  urls <- run $ mapM (idToUrl conf) ids

  case urls of
    Right posters -> do
      files <- ensureDownloaded $ zip ids $ last <$> posters
      generateMontage files
      print files
    Left err -> error $ show err
