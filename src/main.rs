use crate::Media::{Movie, Series};
use crate::MediaRef::{MovieRef, SeriesRef};
use anyhow::{Context, anyhow, bail};
use serde::de::{Unexpected, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};
use std::collections::HashMap;
use std::env::vars;
use std::ffi::OsString;
use std::fmt;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tmdb_client::apis::client::APIClient;
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
    type Error = anyhow::Error;
    fn try_from(media: &Media) -> Result<Self, Self::Error> {
        Ok(match media {
            Movie(movie) => MovieRef(movie.id.context("missing id")?),
            Series(s) => SeriesRef(s.id.context("missing id")?),
        })
    }
}

impl TryFrom<String> for MediaRef {
    type Error = anyhow::Error;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        Ok((if s.starts_with('m') {
            MovieRef
        } else if s.starts_with('s') {
            SeriesRef
        } else {
            bail!("unknown prefix")
        })(
            s.get(1..)
                .ok_or_else(|| anyhow!("indexing"))?
                .parse()
                .map_err(|_| anyhow!("int parse"))?,
        ))
    }
}

#[derive(Debug, Serialize, Deserialize)]
enum Media {
    Movie(MovieDetails),
    Series(TvDetails),
}

fn media_poster_path(media: &Media) -> anyhow::Result<&String> {
    (match media {
        Movie(m) => &m.poster_path,
        Series(s) => &s.poster_path,
    })
    .as_ref()
    .context("missing poster path")
}

fn media_title(media: &Media) -> anyhow::Result<&str> {
    (match media {
        Movie(m) => &m.title,
        Series(s) => &s.name,
    })
    .as_deref()
    .context("missing title")
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

fn load_refs(path_buf: PathBuf) -> anyhow::Result<Vec<MediaRef>> {
    let file = File::open(path_buf).context("opening refs")?;

    let mut refs = vec![];
    for mline in BufReader::new(file).lines() {
        let line = mline?;
        refs.push(MediaRef::try_from(line)?);
    }
    Ok(refs)
}

fn fetch_media_details_into_cache(
    cache: &mut HashMap<MediaRef, Media>,
    tmdb_client: &APIClient,
    media_ref: MediaRef,
) -> anyhow::Result<()> {
    match cache.get(&media_ref) {
        Some(media) => {
            println!("Media \"{}\" found in cache", media_title(media)?);
            return Ok(());
        }
        None => {
            let s: String = media_ref.into();
            print!("Fetching {}... ", s);
        }
    }

    let details = fetch_media_details(tmdb_client, media_ref)?;
    println!("identified as {}", media_title(&details)?);
    cache.insert(media_ref, details);
    Ok(())
}

fn ensure_file(media: &Media) -> anyhow::Result<PathBuf> {
    let mref: MediaRef = media.try_into()?;
    let s: String = mref.into();
    let path = PathBuf::from(STORE_DIR).join(s + ".jpg");
    if !path.exists() {
        println!("Downloading poster for \"{}\"... ", media_title(media)?);
        let response = reqwest::blocking::get(String::from(IMG_API) + media_poster_path(media)?)
            .context("downloading poster")?;
        let mut dest = File::create(&path)?;
        dest.write_all(&(response.bytes()?)).context("writing poster file")?;
    } else {
        println!("Poster for \"{}\" already present", media_title(media)?);
    };
    Ok(path)
}

const STORE_DIR: &str = "store/";
const CACHE_FILE: &str = "cache-rs.json";
const REFS_FILE: &str = "movies.txt";

const IMG_API: &str = "https://image.tmdb.org/t/p/original";

fn main() -> anyhow::Result<()> {
    let key = vars().find(|(k, _)| k == "TMDB_KEY").context("no api key in env")?.1;
    let client = APIClient::new_with_api_key(key);

    let mut cache: HashMap<MediaRef, Media> = match File::open(CACHE_FILE) {
        Ok(file) => serde_json::from_reader(file)?,
        _ => HashMap::new(),
    };

    let media_refs = load_refs(PathBuf::from(REFS_FILE))?;
    for &mref in media_refs.iter() {
        fetch_media_details_into_cache(&mut cache, &client, mref)?;
    }
    serde_json::to_writer_pretty(File::create(CACHE_FILE).context("creating cache file")?, &cache)?;

    let medias = media_refs
        .iter()
        .map(|mref| cache.get(mref))
        .collect::<Option<Vec<&Media>>>()
        .context("missing from cache")?;

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
        .context("running gmic")?;

    Ok(())
}
