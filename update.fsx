#!/usr/bin/env -S dotnet fsi

open System
open System.IO
open System.Net.Http
open System.Text.Json
open System.Text.Json.Nodes

let releaseIndexUrl =
  "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"

let dailyFeed = "https://builds.dotnet.microsoft.com/dotnet"

let http = new HttpClient(Timeout = TimeSpan.FromSeconds 30.)

let fetchJson (url: string) =
  http.GetStringAsync(url).GetAwaiter().GetResult() |> JsonNode.Parse

let fetchText (url: string) =
  http.GetStringAsync(url).GetAwaiter().GetResult().Trim()

let ridTargets = [
  "linux-x64"
  "linux-arm64"
  "linux-musl-x64"
  "linux-musl-arm64"
  "osx-x64"
  "osx-arm64"
  "win-x64"
  "win-arm64"
]

let ridExtension (rid: string) = if rid.StartsWith "win" then "zip" else "tar.gz"

let productPath = function
  | "sdk" -> "Sdk"
  | "runtime" -> "Runtime"
  | "aspnetcore-runtime" -> "aspnetcore/Runtime"
  | "windowsdesktop-runtime" -> "WindowsDesktop"
  | c -> failwithf "unknown component: %s" c

let dailyComponents = [
  "sdk",
  "{feed}/Sdk/{channel}/latest.version",
  "dotnet-sdk-{version}-{rid}.{ext}", false
  "runtime",
  "{feed}/Runtime/{channel}/latest.version",
  "dotnet-runtime-{version}-{rid}.{ext}", false
  "aspnetcore-runtime",
  "{feed}/aspnetcore/Runtime/{channel}/latest.version",
  "aspnetcore-runtime-{version}-{rid}.{ext}", false
  "windowsdesktop-runtime",
  "{feed}/WindowsDesktop/{channel}/latest.version",
  "windowsdesktop-runtime-{version}-{rid}.{ext}", true
]

let fill (tpl: string) (subs: (string * string) list) =
  (tpl, subs) ||> List.fold (fun s (k, v) -> s.Replace(sprintf "{%s}" k, v))

let artifactScore (rid: string) (name: string) =
  let n = name.ToLowerInvariant()
  let mutable s = 0
  if n.Contains "composite" then s <- s + 2
  if rid.StartsWith "win" then
    if n.EndsWith ".zip" then s <- s + 1
    elif n.EndsWith ".exe" then s <- s - 1
  elif n.EndsWith ".tar.gz" then s <- s + 1
  s

let fetchStable () =
  let index = fetchJson releaseIndexUrl
  let out = JsonObject()

  for channel in index["releases-index"].AsArray() do
    let cv = channel["channel-version"].GetValue<string>()
    let major = cv.Split('.') |> Array.head |> int
    if major >= 5 then
      let manifestUrl = channel["releases.json"].GetValue<string>()
      match (try Some(fetchJson manifestUrl) with _ -> None) with
      | None -> ()
      | Some manifest ->
        let releases = manifest["releases"]
        if releases <> null && releases.AsArray().Count > 0 then
          let latest = releases.AsArray()[0]
          let files = JsonObject()

          for component, prefix in
              [ "runtime", "dotnet-runtime-"
                "sdk", "dotnet-sdk-"
                "aspnetcore-runtime", "aspnetcore-runtime-"
                "windowsdesktop-runtime", "windowsdesktop-runtime-" ] do
            match latest[component] with
            | null -> ()
            | entry ->
              let perRid =
                System.Collections.Generic.Dictionary<string, ResizeArray<JsonNode>>()

              for f in entry["files"].AsArray() do
                match f["rid"] with
                | null -> ()
                | ridNode ->
                  let rid = ridNode.GetValue<string>()
                  let name = f["name"].GetValue<string>()
                  let lname = name.ToLowerInvariant()
                  if name.StartsWith prefix
                     && not (lname.Contains "targeting-pack")
                     && not (lname.Contains "crossgen") then
                    match perRid.TryGetValue rid with
                    | true, l -> l.Add f
                    | false, _ ->
                      let l = ResizeArray()
                      perRid[rid] <- l
                      l.Add f

              if perRid.Count > 0 then
                let compNode = JsonObject() :> JsonNode
                files[component] <- compNode
                for KeyValue(rid, cands) in perRid do
                  let best =
                    cands
                    |> Seq.maxBy (fun f -> artifactScore rid (f["name"].GetValue<string>()))
                  let o = JsonObject()
                  o["name"] <- best["name"].GetValue<string>()
                  o["url"] <- best["url"].GetValue<string>()
                  match best["hash"] with
                  | null -> o["hash"] <- ""
                  | h -> o["hash"] <- h.GetValue<string>()
                  compNode[rid] <- o

          let meta = JsonObject()
          meta["channel-version"] <- cv
          meta["latest-release"] <- channel["latest-release"].GetValue<string>()
          meta["latest-release-date"] <- channel["latest-release-date"].GetValue<string>()
          meta["latest-runtime"] <- channel["latest-runtime"].GetValue<string>()
          meta["latest-sdk"] <- channel["latest-sdk"].GetValue<string>()
          meta["support-phase"] <- channel["support-phase"].GetValue<string>()
          meta["release-type"] <- channel["release-type"].GetValue<string>()
          meta["eol-date"] <-
            match channel["eol-date"] with
            | null -> ""
            | e -> e.GetValue<string>()
          meta["files"] <- files
          out[cv] <- meta

  out

let fetchDaily (channels: string list) =
  let out = JsonObject()

  for cv in channels do
    let major = cv.Split('.') |> Array.head |> int
    if major >= 6 then
      let chanNode = JsonObject() :> JsonNode

      for component, latestTpl, fileTpl, windowsOnly in dailyComponents do
        let latestUrl = fill latestTpl [ "feed", dailyFeed; "channel", cv ]
        match (try Some(fetchText latestUrl) with _ -> None) with
        | Some version when version <> "" ->
          let files = JsonObject() :> JsonNode

          for rid in ridTargets do
            if not windowsOnly || rid.StartsWith "win" then
              let baseName =
                fill fileTpl
                  [ "version", version
                    "rid", rid
                    "ext", ridExtension rid ]
              let candidates =
                if component = "aspnetcore-runtime" then
                  [ baseName.Replace("aspnetcore-runtime-", "aspnetcore-runtime-composite-")
                    baseName ]
                else [ baseName ]

              let mutable found = None
              for filename in candidates do
                if found.IsNone then
                  let url =
                    sprintf "%s/%s/%s/%s" dailyFeed (productPath component) version filename
                  match (try Some(fetchText (url + ".sha512")) with _ -> None) with
                  | Some sidecar when sidecar <> "" ->
                    let hash =
                      sidecar.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                      |> Array.head
                    found <- Some(filename, url, hash)
                  | _ -> ()

              match found with
              | Some(filename, url, hash) ->
                let o = JsonObject()
                o["name"] <- filename
                o["url"] <- url
                o["hash"] <- hash
                files[rid] <- o
              | None -> ()

          let comp = JsonObject()
          comp["version"] <- version
          comp["files"] <- files
          chanNode[component] <- comp
        | _ -> ()

      out[cv] <- chanNode

  out

let writeJson (name: string) (node: JsonNode) =
  let opts = JsonSerializerOptions(WriteIndented = true)
  File.WriteAllText(sprintf "data/%s.json" name, node.ToJsonString(opts) + "\n")

Directory.CreateDirectory "data" |> ignore

printfn "Fetching stable release manifests…"
let stable = fetchStable ()
writeJson "stable" stable
printfn "  wrote data/stable.json (%d channels)" stable.Count

printfn "Fetching latest builds + sha512 sidecars…"
let daily = fetchDaily [ for e in stable -> e.Key ]
writeJson "daily" daily
printfn "  wrote data/daily.json (%d channels)" daily.Count
