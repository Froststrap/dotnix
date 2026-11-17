#!/usr/bin/env -S dotnet fsi

open System
open System.IO
open System.Text.Json
open System.Text.Json.Nodes
open System.Text.RegularExpressions

let sh (cmdline: string) =
  let psi = System.Diagnostics.ProcessStartInfo()
  psi.FileName <- "/bin/sh"
  psi.RedirectStandardOutput <- true
  psi.RedirectStandardError <- true
  psi.ArgumentList.Add "-c"
  psi.ArgumentList.Add cmdline
  use p = System.Diagnostics.Process.Start psi
  let out = p.StandardOutput.ReadToEnd()
  let err = p.StandardError.ReadToEnd()
  p.WaitForExit()
  p.ExitCode, out.Trim(), err.Trim()

let mutable passed = 0
let mutable failed = 0

let check (cond: bool) (label: string) (detail: string) =
  if cond then
    passed <- passed + 1
    printfn "  PASS  %s" label
  else
    failed <- failed + 1
    printfn "  FAIL  %s%s" label (if detail = "" then "" else sprintf " (%s)" detail)

printfn "flake root: %s" (Directory.GetCurrentDirectory())

printfn "\n[data]"

let stable =
  match (try Some(JsonNode.Parse(File.ReadAllText "data/stable.json")) with _ -> None) with
  | Some n -> check true "data/stable.json exists and parses" ""; Some n
  | None ->
    check false "data/stable.json exists and parses" "missing or invalid JSON"
    None

match (try Some(JsonNode.Parse(File.ReadAllText "data/daily.json")) with _ -> None) with
| Some _ -> check true "data/daily.json exists and parses" ""
| None -> check false "data/daily.json exists and parses" "missing or invalid JSON"

match (try Some(JsonNode.Parse(File.ReadAllText "data/roslyn-language-server.json")) with _ -> None) with
| Some _ -> check true "data/roslyn-language-server.json exists and parses" ""
| None -> check false "data/roslyn-language-server.json exists and parses" "missing or invalid JSON"

printfn "\n[nix]"

let (nvCode, nvOut, _) = sh "nix --version"
check (nvCode = 0) "nix is available" nvOut

let hostSystem =
  match sh "uname -s", sh "uname -m" with
  | (_, "Darwin", _), (_, "arm64", _) -> Some "aarch64-darwin"
  | (_, "Darwin", _), (_, "x86_64", _) -> Some "x86_64-darwin"
  | (_, "Linux", _), (_, "x86_64", _) -> Some "x86_64-linux"
  | (_, "Linux", _), (_, "aarch64", _) -> Some "aarch64-linux"
  | _ -> None

match stable with
| None -> ()
| Some stable ->
  match hostSystem with
  | None -> check false "host system recognized" "unsupported uname output"
  | Some sys ->
    let (ec, eo, eerr) =
      sh (sprintf "nix eval --json .#packages.%s --apply 'p: builtins.filter (n: builtins.match \"[0-9]+-[0-9]+\" n != null) (builtins.attrNames p)'" sys)
    check (ec = 0) (sprintf "flake evaluates for %s" sys) eerr

    if ec = 0 then
      let channels =
        match (try Some(JsonSerializer.Deserialize<string list>(eo)) with _ -> None) with
        | Some chs -> chs
        | None -> []

      check (not channels.IsEmpty) "versions are listed" eo

      if not channels.IsEmpty then
        let major (ch: string) =
          ch.Split('-') |> Array.head |> int

        let newest = channels |> List.maxBy major
        printfn "  -> testing toolchain %s (%s)" newest sys

        printfn "\n[build]"
        let (bc, _, berr) =
          sh (sprintf "nix build -o result .#packages.%s.%s.stable.default" sys newest)
        check (bc = 0) (sprintf "toolchain %s builds" newest) berr

        if bc = 0 then
          printfn "\n[built toolchain]"

          let (ec1, _, _) = sh "test -f result/bin/dotnet"
          check (ec1 = 0) "result/bin/dotnet exists" ""

          let (ec2, _, _) = sh "test -d result/share/dotnet/sdk"
          check (ec2 = 0) "result/share/dotnet/sdk exists" ""

          let (vc, vOut, verr) = sh "./result/bin/dotnet --version"
          check (vc = 0) "built dotnet runs" verr
          check (Regex.IsMatch(vOut, @"^\d+\.\d+")) "dotnet reports a version" vOut

          let (lc, lOut, _) = sh "./result/bin/dotnet --list-sdks"
          check (lc = 0) "dotnet --list-sdks runs" lOut
          check (lOut.Contains vOut) "--list-sdks shows the SDK" lOut

          let (hc, _, _) = sh "test -f result/nix-support/setup-hook"
          check (hc = 0) "result/nix-support/setup-hook exists" ""

          let (hh, _, _) = sh "grep -q DOTNET_NOLOGO result/nix-support/setup-hook"
          check (hh = 0) "setup hook makes HOME writable" ""

          let (nh, _, _) = sh "grep -q configureNuget result/nix-support/setup-hook"
          check (nh = 0) "setup hook configures NuGet" ""

          let compatExpr =
            sprintf "nix eval --raw .#packages.%s.%s.stable.default --apply 'p: if p.packages == [] && p ? targetPackages && p ? meta.platforms && p.runtime.drvPath == p.drvPath then \"ok\" else \"missing\"'" sys newest
          let (cc, ccOut, ccErr) = sh compatExpr
          check
            (cc = 0 && ccOut.Trim() = "ok")
            "exposes buildDotnetModule compatibility attributes"
            ccErr

          let dataChannel = newest.Replace('-', '.')
          match stable[dataChannel] with
          | null -> ()
          | channel ->
            match channel["latest-sdk"] with
            | null -> ()
            | expected ->
            let expected = expected.GetValue<string>()
            check
              (vOut = expected)
              (sprintf "built version matches stable latest-sdk (%s)" expected)
              (sprintf "got %s" vOut)

        printfn "\n[roslyn-language-server]"
        let (rc, rout, _) =
          sh (sprintf "nix build --no-link --print-out-paths .#packages.%s.roslyn-language-server" sys)
        check (rc = 0) "roslyn-language-server builds" ""
        if rc = 0 then
          let lspRoot = rout.Trim()
          let (lr, lout, lerr) = sh (sprintf "%s/bin/roslyn-language-server" lspRoot)
          check
            (lr = 0 && (lout + lerr).Contains "stdio")
            "roslyn-language-server runs and asks for --stdio/--pipe"
            (lout + lerr)

printfn "\n%d passed, %d failed" passed failed
exit (if failed = 0 then 0 else 1)
