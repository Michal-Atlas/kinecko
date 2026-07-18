{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Control.Monad
import Data.Aeson (eitherDecodeFileStrict, encodeFile)
import Data.Aeson qualified as JSON
import Data.Bifunctor (Bifunctor (first))
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Text qualified as Text
import GHC.Generics
import Network.API.TheMovieDB qualified as TMDB
import Network.API.TheMovieDB.Extras
import Network.HTTP.Simple
import Polysemy
import Polysemy.Error as PSE
import Polysemy.State (State, get, put, runState)
import System.Directory
import System.Environment
import System.Process

data MediaRef = SeriesRef TMDB.ItemID | MovieRef TMDB.ItemID
  deriving (Ord, Eq)

instance Read MediaRef where
  readsPrec _ ('s' : i) = [(SeriesRef $ read i, "")]
  readsPrec _ ('m' : i) = [(MovieRef $ read i, "")]

instance Show MediaRef where
  show (SeriesRef i) = "s" ++ show i
  show (MovieRef i) = "m" ++ show i

data Media = Series TMDB.TV | Movie TMDB.Movie

deriving instance Generic Media

deriving instance Generic MediaRef

instance JSON.ToJSON Media

instance JSON.FromJSON Media

instance JSON.FromJSON MediaRef

instance JSON.FromJSONKey MediaRef

instance JSON.ToJSON MediaRef

instance JSON.ToJSONKey MediaRef

data Errors = TMDB TMDB.Error | Aeson String
  deriving (Show)

getKey :: (Member (Embed IO) r) => Sem r TMDB.Key
getKey = Text.pack <$> (embed $ getEnv "TMDB_KEY")

embedTmdb :: (Members '[Embed IO, PSE.Error Errors] r) => TMDB.Settings -> TMDB.TheMovieDB b -> Sem r b
embedTmdb settings action = fromEitherM $ first TMDB <$> TMDB.runTheMovieDB settings action

tmdbToIO :: (Members '[Embed IO, PSE.Error Errors] r) => Sem (Embed TMDB.TheMovieDB ': r) a -> Sem r a
tmdbToIO = interpret $ \case
  Embed action -> do
    key <- getKey
    result <- embed $ TMDB.runTheMovieDB (TMDB.defaultSettings key) action
    fromEither $ first TMDB result

loadIDs :: (Member (Embed IO) r) => FilePath -> Sem r [MediaRef]
loadIDs file = do
  idStrs <- embed $ readFile file
  return $ read <$> lines idStrs

type URL = Text.Text

configFile :: FilePath
configFile = "config.json"

fetchMedia' :: (Member (Embed TMDB.TheMovieDB) r) => MediaRef -> Sem r Media
fetchMedia' (SeriesRef i) = embed $ Series <$> TMDB.fetchTV i
fetchMedia' (MovieRef i) = embed $ Movie <$> TMDB.fetchMovie i

data MediaFetcher m a where
  FetchMediaRef :: MediaRef -> MediaFetcher m Media

makeSem ''MediaFetcher

type InfoCache = Map.Map MediaRef Media

cacheFile :: String
cacheFile = "movieInfoCache.json"

loadCache :: (Members '[Embed IO, Error Errors] r) => Sem r InfoCache
loadCache = fromEitherM $ first Aeson <$> eitherDecodeFileStrict cacheFile

saveCache :: (Member (Embed IO) r) => InfoCache -> Sem r ()
saveCache cache = embed $ encodeFile cacheFile cache

interpretFetchMedia :: (Members '[Embed IO, State InfoCache, Embed TMDB.TheMovieDB] r) => Sem (MediaFetcher ': r) a -> Sem r a
interpretFetchMedia = interpret $ \case
  (FetchMediaRef ref) -> do
    cache <- get
    case Map.lookup ref cache of
      (Just found) -> do
        embed $ putStrLn $ "Found " ++ (show $ mediaTitle found) ++ " in cache"
        return found
      Nothing -> do
        embed $ putStr $ "Fetching " ++ (show $ ref) ++ "..."
        media <- fetchMedia' ref
        embed $ putStrLn $ " identified as " ++ (show $ mediaTitle media)
        put $ Map.insert ref media cache
        return media

interpretFetchMediaCached :: (Members '[Embed IO, Error Errors] r) => Sem (State InfoCache ': r) a -> Sem r a
interpretFetchMediaCached action = do
  exists <- embed $ doesFileExist cacheFile
  c <- if exists then loadCache else return Map.empty
  (newCache, value) <- runState c action
  saveCache newCache
  return value

getCachedConfig :: (Members '[Embed IO, Embed TMDB.TheMovieDB] r) => Sem r TMDB.Configuration
getCachedConfig = do
  exists <- embed $ doesFileExist configFile
  if exists
    then do
      mconf <- embed $ JSON.decodeFileStrict configFile
      return $ fromMaybe (error "Failed to decode config.json") mconf
    else do
      conf <- embed TMDB.config
      embed $ JSON.encodeFile configFile conf
      return conf

downloadDir :: FilePath
downloadDir = "store"

liftMedia :: (TMDB.Movie -> t) -> (TMDB.TV -> t) -> Media -> t
liftMedia movf _ (Movie m) = movf m
liftMedia _ tvf (Series m) = tvf m

mediaTitle :: Media -> Text.Text
mediaTitle = liftMedia TMDB.movieTitle TMDB.tvName

mediaPosterUrls :: TMDB.Configuration -> Media -> Text.Text
mediaPosterUrls conf = last . liftMedia (TMDB.moviePosterURLs conf) (TMDB.tvPosterURLs conf)

mediaToRef :: Media -> MediaRef
mediaToRef (Movie (TMDB.Movie {movieID})) = MovieRef movieID
mediaToRef (Series (TMDB.TV {tvID})) = SeriesRef tvID

ensureFile :: (Member (Embed IO) r) => TMDB.Configuration -> Media -> Sem r FilePath
ensureFile conf item = do
  exists <- embed $ doesFileExist path
  when
    exists
    ( embed $ do
        putStr "Poster for "
        putStr $ show $ mediaTitle item
        putStrLn " already present"
    )
  unless
    exists
    ( embed $ do
        putStr "Downloading poster for "
        putStr $ show $ mediaTitle item
        putStr "... "
        do
          req <- parseRequest $ Text.unpack url
          imgData <- httpBS req
          BS.writeFile path $ getResponseBody imgData
        putStrLn "done"
    )

  return path
  where
    url = mediaPosterUrls conf item
    path = downloadDir ++ "/" ++ (show $ mediaToRef item) ++ ".jpg"

ensureDownloaded :: (Member (Embed IO) r) => TMDB.Configuration -> [Media] -> Sem r [FilePath]
ensureDownloaded conf inp = do
  embed $ createDirectoryIfMissing True downloadDir
  mapM (ensureFile conf) inp

generateMontage :: (Member (Embed IO) r) => [FilePath] -> FilePath -> Sem r ()
generateMontage files output =
  embed $
    callProcess "gmic" $
      files
        ++ [ "rescale2d",
             "0,2000",
             "frame",
             ",3,0,0,0",
             "pack",
             "1,-k",
             "output",
             output
           ]

program :: (Members '[Embed IO, MediaFetcher, Embed TMDB.TheMovieDB] r) => Sem r ()
program = do
  args <- embed $ getArgs
  let (file, output) =
        fromMaybe
          (error "Usage: <input> <output>")
          ( case args of
              [file, output] -> Just (file, output)
              _ -> Nothing
          )
  ids <- loadIDs file
  medias <- mapM fetchMediaRef ids
  conf <- getCachedConfig
  files <- ensureDownloaded conf medias
  generateMontage files output
  embed $ print files

main :: IO ()
main = do
  v <- runM . runError . tmdbToIO . interpretFetchMediaCached . interpretFetchMedia $ program
  print v
