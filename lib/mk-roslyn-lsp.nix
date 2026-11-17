# SPDX-FileCopyrightText: 2026 Froststrap
#
# SPDX-License-Identifier: MPL-2.0

# Builds the Roslyn-based C# language server (`roslyn-language-server`) from
# its RID-specific NuGet tool package. Unlike nixpkgs' `omnisharp-roslyn` this
# is framework-dependent and runs on the .NET runtime managed by dotnix (it
# targets `net10.0` with `rollForward: Major`), so it does not drag in a second,
# older .NET SDK.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  makeWrapper,
  autoPatchelfHook,
}:
{
  # Upstream RID, e.g. "linux-x64" / "osx-arm64".
  rid,
  version,
  # SRI hash of the per-RID .nupkg, e.g. "sha256-...".
  hash,
  # A dotnix combined runtime (must provide `share/dotnet`).
  dotnet-runtime,
}:
let
  src = fetchurl {
    url = "https://api.nuget.org/v3-flatcontainer/roslyn-language-server.${rid}/${version}/roslyn-language-server.${rid}.${version}.nupkg";
    inherit hash;
  };
in
stdenv.mkDerivation {
  pname = "roslyn-language-server";
  inherit version src;

  # binutils' strip happily rewrites the managed PE assemblies and corrupts
  # them; only the native apphosts/sqlite need touching, which autoPatchelf does.
  dontStrip = true;

  nativeBuildInputs = [
    unzip
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];

  unpackPhase = ''
    runHook preUnpack
    mkdir -p source
    unzip -q "$src" -d source
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/roslyn-language-server $out/bin
    cp -a source/tools/net10.0/${rid}/. $out/lib/roslyn-language-server/
    chmod -R u+w $out/lib/roslyn-language-server
    # NuGet strips the exec bit; the thin client spawns these apphosts directly.
    chmod +x \
      $out/lib/roslyn-language-server/roslyn-language-server \
      $out/lib/roslyn-language-server/Microsoft.CodeAnalysis.LanguageServer
    makeWrapper ${dotnet-runtime}/share/dotnet/dotnet $out/bin/roslyn-language-server \
      --add-flags "$out/lib/roslyn-language-server/roslyn-language-server.dll" \
      --set DOTNET_ROOT ${dotnet-runtime}/share/dotnet
    runHook postInstall
  '';

  meta = {
    description = "Roslyn-based language server for C# and Razor";
    homepage = "https://github.com/dotnet/roslyn";
    license = lib.licenses.mit;
    mainProgram = "roslyn-language-server";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
