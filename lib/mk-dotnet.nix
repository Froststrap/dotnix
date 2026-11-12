{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  unzip,
  icu,
  openssl,
  zlib,
  libkrb5,
  curl,
}:
{ hostRid ? null }:
let
  runtimeBuildInputs = [
    stdenv.cc.cc.lib
    icu
    openssl
    zlib
    libkrb5
    curl
  ];

  isZip = url: lib.hasSuffix ".zip" (baseNameOf url);
in
{
  mkArtifact =
    { rid
    , url
    , hash
    , component ? "artifact"
    , name ? null
    }:
    let
      name_ = if name != null then
        name
      else "dotnet-${component}-${rid}";
      src = fetchurl { inherit url; sha512 = hash; };
    in
    if hostRid == rid && lib.hasPrefix "linux-" rid && !lib.hasInfix "musl" rid
    then
      stdenv.mkDerivation {
        name = name_;
        inherit src;
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = runtimeBuildInputs;
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          mkdir -p $out/share/dotnet
          cp -a . $out/share/dotnet/
        '';
        passthru = { inherit rid url hash; };
      }
    else
      stdenvNoCC.mkDerivation {
        name = name_;
        inherit src;
        sourceRoot = ".";
        nativeBuildInputs = lib.optionals (isZip url) [ unzip ];
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;
        installPhase = ''
          mkdir -p $out/share/dotnet
          cp -a . $out/share/dotnet/
        '';
        passthru = { inherit rid url hash; };
      };

  combine = name: artifacts:
    stdenvNoCC.mkDerivation {
      inherit name;
      nativeBuildInputs = [ makeWrapper ];
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out/share/dotnet
        ${lib.concatMapStringsSep "\n"
          (a: ''
            cp -a ${a}/share/dotnet/. $out/share/dotnet/
            chmod -R u+w $out/share/dotnet
          '')
          artifacts}
        if [ -f $out/share/dotnet/dotnet ]; then
          mkdir -p $out/bin
          makeWrapper $out/share/dotnet/dotnet $out/bin/dotnet \
            --set-default DOTNET_ROOT $out/share/dotnet \
            --set-default DOTNET_CLI_TELEMETRY_OPTOUT 1
        fi
      '';
    };
}
