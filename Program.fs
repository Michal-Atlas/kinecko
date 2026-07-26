open System
open System.IO
open TMDbLib.Client
open TMDbLib.Objects
open System.Text.Json
open System.Net.Http
open SimpleExec

let img_api = "https://image.tmdb.org/t/p/original"

type MediaType =
    | Movie
    | Series

type MediaRef = { typ: MediaType; id: string }

type Media =
    | Movie of Movies.Movie
    | Series of TvShows.TvShow

// https://stackoverflow.com/questions/3722591/pattern-matching-on-the-beginning-of-a-string-in-f
let (|Prefix|_|) (p: string) (s: string) =
    if s.StartsWith(p) then
        Some(s.Substring(p.Length))
    else
        None

let parseMediaRef (str: string) =
    match str with
    | Prefix "s" rest -> { typ = MediaType.Series; id = rest }
    | Prefix "m" rest -> { typ = MediaType.Movie; id = rest }
    | _ -> Exception $"cannot parse {str} as Media Ref" |> raise

let loadMediaRefs file =
    file |> File.ReadLines |> Seq.map parseMediaRef

let fetchRef (client: TMDbClient) ref =
    match ref with
    | { typ = MediaType.Movie; id = id } -> id |> client.GetMovieAsync |> _.Result |> Movie
    | { typ = MediaType.Series; id = id } -> id |> Int32.Parse |> client.GetTvShowAsync |> _.Result |> Series

let cacheFile = "movieInfoCache-net.json"

type MediaCache = Map<MediaRef, Media>
type MediaCacheSerialization = (MediaRef * Media) list

let loadCache: MediaCache =
    if File.Exists cacheFile then
        cacheFile
        |> File.ReadAllText
        |> JsonSerializer.Deserialize<MediaCacheSerialization>
        |> Map.ofList
    else
        Map.empty

let saveCache (cache: MediaCache) =
    cache
    |> Map.toList
    |> JsonSerializer.Serialize<MediaCacheSerialization>
    |> (fun x -> File.WriteAllText(cacheFile, x))

let liftMedia mf sf m =
    match m with
    | Movie m -> mf m
    | Series s -> sf s

let mediaTitle = liftMedia _.Title _.Name

let mediaPosterPath = liftMedia _.PosterPath _.PosterPath

let mediaPosterUrl m = img_api + mediaPosterPath m

let fetchRefCached (cache: MediaCache) (client: TMDbClient) ref : MediaCache * Media =
    printf $"Processing {ref}..."

    match cache.TryFind ref with
    | Some media ->
        printfn $" found in cache as {mediaTitle media}"
        (cache, media)
    | None ->
        let media = fetchRef client ref
        printfn $" fetched as {mediaTitle media}"
        (cache.Add(ref, media), media)

let fetchRefsCached (cache: MediaCache) (client: TMDbClient) refs : MediaCache * Media list =
    Seq.foldBack
        (fun ref (oldCache, acc) ->
            let newCache, media = fetchRefCached oldCache client ref
            (newCache, media :: acc))
        refs
        (cache, [])

let downloadFile (url: string) (outputPath: string) =
    task {
        use client = new HttpClient()
        use! webStream = client.GetStreamAsync(url)

        use fileStream =
            new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None)

        do! webStream.CopyToAsync(fileStream)
    }

let fetchPoster media =
    let posterPath = mediaPosterPath media
    let filePath = "store/" + posterPath.Substring 1

    if File.Exists filePath then
        printfn $"Poster for {mediaTitle media} already present"
    else
        printf $"Downloading poster for {mediaTitle media}..."
        (downloadFile (mediaPosterUrl media) filePath).Result
        printfn "done"

    filePath

[<EntryPoint>]
let main args =
    match args with
    | [| ref_file; out_path |] ->
        printfn "Running"
        let api_key = Environment.GetEnvironmentVariable("TMDB_KEY")
        let tmdb_client = new TMDbClient(api_key)

        let newCache, medias =
            loadMediaRefs ref_file |> fetchRefsCached loadCache tmdb_client

        saveCache newCache

        let posterPaths = medias |> Seq.map fetchPoster

        Command.Run(
            "gmic",
            Seq.concat
                [| posterPaths
                   Array.toSeq
                       [| "rescale2d"
                          "0,2000"
                          "frame"
                          ",3,0,0,0"
                          "pack"
                          "1,-k"
                          "output"
                          out_path |] |]
        )

    | _ -> eprintfn "Usage: <ref-file> <output>"

    0
