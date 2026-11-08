{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.API.TheMovieDB.Extras where

import Data.Aeson
import Network.API.TheMovieDB

instance ToJSON Movie where
  toJSON Movie {..} =
    object
      [ "id" .= movieID,
        "title" .= movieTitle,
        "poster_path" .= moviePosterPath
      ]

instance ToJSON TV where
  toJSON TV {..} =
    object
      [ "id" .= tvID,
        "name" .= tvName,
        "poster_path" .= tvPosterPath
      ]
