use crate::Errors::*;
use crate::Media::{Movie, Series};
use crate::MediaRef::{MovieRef, SeriesRef};
use serde::de::{Unexpected, Visitor};
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;
use std::env::vars;
use std::ffi::OsString;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::fmt;
use tmdb_client::apis::client::APIClient;
use tmdb_client::apis::{MoviesApi, TVApi};
use tmdb_client::models::{MovieDetails, TvDetails};

type TmdbID = i32;

#[derive(Debug, Eq, Hash, PartialEq, Copy, Clone)]
enum MediaRef {
    MovieRef(TmdbID),
    SeriesRef(TmdbID),
}

impl Serialize for MediaRef {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let s: String = (*self).into();
        serializer.serialize_str(&*s)
    }
}

impl<'de> Deserialize<'de> for MediaRef {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct MediaRefVisitor;

        impl<'de> Visitor<'de> for MediaRefVisitor {
            type Value = MediaRef;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a string of the form <m/s><id>")
            }

            fn visit_str<E>(self, s: &str) -> Result<Self::Value, E>
            where
                E: de::Error,
            {
                MediaRef::try_from(s.to_owned())
                    .map_err(|_| de::Error::invalid_value(Unexpected::Str(s), &self))
            }
        }

        deserializer.deserialize_string(MediaRefVisitor)
    }
}

impl Into<String> for MediaRef {
    fn into(self) -> String {
        match self {
            MovieRef(id) => format!("m{}", id),
            SeriesRef(id) => format!("s{}", id),
        }
    }
}

impl TryFrom<&Media> for MediaRef {
    type Error = ();
    fn try_from(media: &Media) -> Result<Self, Self::Error> {
        Ok(match media {
            Movie(movie) => MovieRef(movie.id.ok_or(())?),
            Series(s) => SeriesRef(s.id.ok_or(())?),
        })
    }
}

impl TryFrom<String> for MediaRef {
    type Error = &'static str;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        Ok((if s.starts_with('m') {
            MovieRef
        } else if s.starts_with('s') {
            SeriesRef
        } else {
            return Err("unknown prefix");
        })(
            s.get(1..)
                .ok_or("indexing")?
                .parse()
                .map_err(|_| "int parse")?,
        ))
    }
}

#[derive(Debug, Serialize, Deserialize)]
enum Media {
    Movie(MovieDetails),
    Series(TvDetails),
}

// fn media_lift<'a, FM, FS, F, R: 'a>(movie_map: FM, series_map: FS) -> impl FnOnce(&'a Media) -> R
// where
//     FM: FnOnce(&'a MovieDetails) -> R,
//     FS: FnOnce(&'a TvDetails) -> R,
//     F: FnOnce(&'a Media) -> R,
// {
//     |media: &Media| match media {
//         Movie(m) => movie_map(m),
//         Series(s) => series_map(s),
//     }
// }

fn media_poster_path(media: &Media) -> Result<&String, Errors> {
    (match media {
        Movie(m) => & m.poster_path,
        Series(s) => & s.poster_path,
    }).as_ref().ok_or(MissingPosterPath)
}

fn media_title(media: &Media) -> Result<&String, Errors> {
    (match media {
        Movie(m) => &  m.title,
        Series(s) => & s.name,
    }).as_ref().ok_or(MissingTitle)
}

fn fetch_media_details(
    tmdb_client: &APIClient,
    media_ref: MediaRef,
) -> Result<Media, tmdb_client::Error> {
    Ok(match media_ref {
        MovieRef(id) => Movie(
            tmdb_client
                .movies_api()
                .get_movie_details(id, None, None, None)?,
        ),
        SeriesRef(id) => Series(tmdb_client.tv_api().get_tv_details(id, None, None, None)?),
    })
}

#[derive(Debug)]
enum Errors {
    NoEnvKey,
    IO(std::io::Error),
    IORefFile(std::io::Error),
    WriteCache(std::io::Error),
    SerdeError(serde_json::Error),
    ParseRefError(&'static str),
    TmdbError(tmdb_client::Error),
    ReqwestError(reqwest::Error),
    MissingFromCache,
    MissingTitle,
    MissingPosterPath,
    NoId,
}

fn load_refs(path_buf: PathBuf) -> Result<Vec<MediaRef>, Errors> {
    let file = File::open(path_buf).map_err(IORefFile)?;

    let mut refs = vec![];
    for mline in BufReader::new(file).lines() {
        let line = mline.map_err(IO)?;
        refs.push(MediaRef::try_from(line).map_err(ParseRefError)?);
    }
    Ok(refs)
}

fn fetch_media_details_into_cache(
    cache: &mut HashMap<MediaRef, Media>,
    tmdb_client: &APIClient,
    media_ref: MediaRef,
) -> Result<(), Errors> {
    match cache.get(&media_ref) {
        Some(media) => {
            println!(
                "Media \"{}\" found in cache",
                media_title(media)?
            );
            return Ok(());
        }
        None => {
            let s: String = media_ref.into();
            print!("Fetching {}... ", s);
        }
    }

    let details = fetch_media_details(tmdb_client, media_ref).map_err(TmdbError)?;
    println!(
        "identified as {}",
        media_title(&details)?
    );
    cache.insert(media_ref, details);
    Ok(())
}

fn ensure_file(m: &Media) -> Result<PathBuf, Errors> {
    let path = PathBuf::from(STORE_DIR)
        .join(<MediaRef as Into<String>>::into(MediaRef::try_from(m).map_err(|_| NoId)?) + ".jpg");
    if !path.exists() {
        println!("Downloading poster for \"{}\"... ", media_title(m)?);
        let response = reqwest::blocking::get(
            String::from(IMG_API) + media_poster_path(m)?,
        )
        .map_err(ReqwestError)?;
        let mut dest = File::create(&path).map_err(IO)?;
        dest.write_all(&(response.bytes().map_err(ReqwestError)?))
            .map_err(IO)?;
    } else {
        println!("Poster for \"{}\" already present", media_title(m)?);
    };
    Ok(path)
}

const STORE_DIR: &str = "store/";
const CACHE_FILE: &str = "cache-rs.json";
const REFS_FILE: &str = "movies.txt";

const IMG_API: &str = "https://image.tmdb.org/t/p/original";

fn main() -> Result<(), Errors> {
    let key = vars().find(|(k, v)| k == "TMDB_KEY").ok_or(NoEnvKey)?.1;
    let client = APIClient::new_with_api_key(key);

    let mut cache: HashMap<MediaRef, Media> = match File::open(CACHE_FILE) {
        Ok(file) => serde_json::from_reader(file).map_err(SerdeError)?,
        _ => HashMap::new(),
    };

    let media_refs = load_refs(PathBuf::from(REFS_FILE))?;
    for &mref in media_refs.iter() {
        fetch_media_details_into_cache(&mut cache, &client, mref)?;
    }
    serde_json::to_writer_pretty(File::create(CACHE_FILE).map_err(WriteCache)?, &cache)
        .map_err(SerdeError)?;

    let medias = media_refs
        .iter()
        .map(|mref| cache.get(mref))
        .collect::<Option<Vec<&Media>>>()
        .ok_or(MissingFromCache)?;

    let poster_paths = medias
        .iter()
        .map(|mref| ensure_file(mref))
        .collect::<Result<Vec<PathBuf>, _>>()?;
    let output = "output-rs.jpg";
    Command::new("gmic")
        .args(
            poster_paths
                .into_iter()
                .map(|p| p.into_os_string())
                .chain(
                    [
                        "rescale2d",
                        "0,2000",
                        "frame",
                        ",3,0,0,0",
                        "pack",
                        "1,-k",
                        "output",
                        output,
                    ]
                    .into_iter()
                    .map(|s| OsString::from(s)),
                )
                .collect::<Vec<OsString>>(),
        )
        .stdout(Stdio::inherit())
        .stdin(Stdio::inherit())
        .output()
        .map_err(IO)?;

    Ok(())
}
