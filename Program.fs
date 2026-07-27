open System
open System.IO
open TMDbLib.Client
open TMDbLib.Objects
open System.Text.Json
open System.Net.Http
open SimpleExec

[<Literal>]
let img_api = "https://image.tmdb.org/t/p/original"

type MediaType =
    | Movie
    | Series

type MediaRef = { typ: MediaType; id: string }

type Media =
    | Movie of Movies.Movie
    | Series of TvShows.TvShow

// https://stackoverflow.com/questions/3722591/pattern-matching-on-the-beginning-of-a-string-in-f
let (|Prefix|_|) (p: string) (s: string) : string option =
    if s.StartsWith(p) then
        Some(s.Substring(p.Length))
    else
        None

let parseMediaRef (str: string) : MediaRef =
    match str with
    | Prefix "s" rest -> { typ = MediaType.Series; id = rest }
    | Prefix "m" rest -> { typ = MediaType.Movie; id = rest }
    | _ -> Exception $"cannot parse {str} as Media Ref" |> raise

let loadMediaRefs (file: string) : Async<MediaRef seq> =
    async {
        let! lines = file |> File.ReadAllLinesAsync |> Async.AwaitTask
        return lines |> Seq.map parseMediaRef
    }

let fetchRef (client: TMDbClient) (ref: MediaRef) : Async<Media> =
    match ref with
    | { typ = MediaType.Movie; id = id } ->
        async {
            let! m = id |> client.GetMovieAsync |> Async.AwaitTask
            return Movie m
        }
    | { typ = MediaType.Series; id = id } ->
        async {
            let! s = id |> Int32.Parse |> client.GetTvShowAsync |> Async.AwaitTask
            return Series s
        }

[<Literal>]
let cacheFile = "movieInfoCache-net.json"

type MediaCache = Map<MediaRef, Media>
type MediaCacheSerialization = (MediaRef * Media) list

let loadCache (_: unit) : MediaCache =
    if File.Exists cacheFile then
        cacheFile
        |> File.ReadAllText
        |> JsonSerializer.Deserialize<MediaCacheSerialization>
        |> Map.ofList
    else
        Map.empty

let saveCache (cache: MediaCache) : unit =
    cache
    |> Map.toList
    |> JsonSerializer.Serialize<MediaCacheSerialization>
    |> (fun x -> File.WriteAllText(cacheFile, x))

let liftMedia (mf: Movies.Movie -> 'a) (sf: TvShows.TvShow -> 'a) (m: Media) : 'a =
    match m with
    | Movie m -> mf m
    | Series s -> sf s

let mediaTitle: Media -> string = liftMedia _.Title _.Name

let mediaPosterPath: Media -> string = liftMedia _.PosterPath _.PosterPath

let mediaPosterUrl (m: Media) : string = img_api + mediaPosterPath m

let fetchRefCached (cache: MediaCache) (client: TMDbClient) (ref: MediaRef) : Async<MediaCache * Media> =
    async {
        printf $"Processing {ref}..."

        match cache.TryFind ref with
        | Some media ->
            printfn $" found in cache as {mediaTitle media}"
            return (cache, media)
        | None ->
            let! media = fetchRef client ref
            printfn $" fetched as {mediaTitle media}"
            return (cache.Add(ref, media), media)
    }

let fetchRefsCached (cache: MediaCache) (client: TMDbClient) (refs: MediaRef seq) : Async<MediaCache * Media list> =
    Seq.foldBack
        (fun ref prev ->
            async {
                let! oldCache, acc = prev
                let! newCache, media = fetchRefCached oldCache client ref
                return (newCache, media :: acc)
            })
        refs
        (async { return (cache, []) })

let downloadFile (client: HttpClient) (url: string) (outputPath: string) : Async<unit> =
    async {
        use! webStream = client.GetStreamAsync(url) |> Async.AwaitTask

        use fileStream =
            new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None)

        do! webStream.CopyToAsync(fileStream) |> Async.AwaitTask
    }

let fetchPoster (client: HttpClient) (media: Media) : Async<string> =
    async {
        let posterPath = mediaPosterPath media
        let filePath = "store/" + posterPath.Substring 1

        if File.Exists filePath then
            printfn $"Poster for {mediaTitle media} already present"
        else
            printf $"Downloading poster for {mediaTitle media}..."
            do! downloadFile client (mediaPosterUrl media) filePath
            printfn "done"

        return filePath
    }

[<EntryPoint>]
let main args =
    match args with
    | [| ref_file; out_path |] ->
        printfn "Running"
        let api_key = Environment.GetEnvironmentVariable("TMDB_KEY")
        let tmdb_client = new TMDbClient(api_key)
        let client = new HttpClient()

        let posterPaths =
            async {

                let cache = loadCache ()

                let! refs = loadMediaRefs ref_file
                let! newCache, medias = fetchRefsCached cache tmdb_client refs

                saveCache newCache

                let! posterPaths = medias |> Seq.map (fetchPoster client) |> Async.Parallel
                return posterPaths
            }
            |> Async.RunSynchronously

        Command.Run(
            "gmic",
            [ yield! posterPaths
              "rescale2d"
              "0,2000"
              "frame"
              ",3,0,0,0"
              "pack"
              "1,-k"
              "output"
              out_path ]
        )

    | _ -> eprintfn "Usage: <ref-file> <output>"

    0
