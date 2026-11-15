{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  lttng-ust_2_12,
  autoPatchelfHook,
  makeWrapper,
  unzip,
  icu,
  openssl,
  zlib,
  libkrb5,
  curl,
  hostRid ? null
}:
let
  runtimeBuildInputs = [
    stdenv.cc.cc.lib
    icu
    openssl
    zlib
    libkrb5
    curl
    lttng-ust_2_12
  ];

  isZip = url: lib.hasSuffix ".zip" (baseNameOf url);
  isLinuxNative = rid:
    hostRid == rid && lib.hasPrefix "linux-" rid && !lib.hasInfix "musl" rid;
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
      name' = if name != null then name else "dotnet-${component}-${rid}";
      src = fetchurl { inherit url; sha512 = hash; };
    in
    if isLinuxNative rid
    then
      stdenv.mkDerivation {
        name = name';
        inherit src;
        sourceRoot = ".";
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = runtimeBuildInputs;
        dontConfigure = true;
        dontBuild = true;
        installPhase = ''
          mkdir -p $out/share/dotnet
          cp -a . $out/share/dotnet/
        '';

        postFixup = lib.optionalString (isLinuxNative rid) ''
          addNeeded() {
            local libs="$1"; shift
            local f l
            for f in "$@"; do
              [ -e "$f" ] || continue
              for l in $libs; do
                patchelf --add-needed "$l" "$f"
              done
            done
          }

          nativeHosts=($out/share/dotnet/packs/Microsoft.NETCore.App.Host.${rid}/*/runtimes/${rid}/native/*host)
          aotLibs=($out/share/dotnet/sdk/*/libdotnet-aot.so)

          addNeeded "libicui18n.so libicuuc.so" \
            $out/share/dotnet/shared/Microsoft.NETCore.App/*/libcoreclr.so \
            $out/share/dotnet/shared/Microsoft.NETCore.App/*/*System.Globalization.Native.so \
            "''${nativeHosts[@]}" "''${aotLibs[@]}"

          addNeeded "libgssapi_krb5.so" \
            $out/share/dotnet/shared/Microsoft.NETCore.App/*/*System.Net.Security.Native.so \
            "''${nativeHosts[@]}" "''${aotLibs[@]}"

          addNeeded "libssl.so" \
            $out/share/dotnet/shared/Microsoft.NETCore.App/*/*System.Security.Cryptography.Native.OpenSsl.so \
            "''${nativeHosts[@]}" "''${aotLibs[@]}"
        '';
        passthru = { inherit rid url hash; };
      }
    else
      stdenvNoCC.mkDerivation {
        name = name';
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
