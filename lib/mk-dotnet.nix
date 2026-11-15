{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  lttng-ust_2_12,
  autoPatchelfHook,
  unzip,
  icu,
  openssl,
  zlib,
  libkrb5,
  curl,
  pkgs,
  hostRid ? null
}:
let
  # The setup hooks nixpkgs' dotnet packages ship. They make `$HOME` writable
  # and point NuGet at the offline package sources (needed by
  # `buildDotnetModule` / `buildDotnetGlobalTool`, which are built with
  # `dotnet-sdk` in `nativeBuildInputs` and therefore source this hook).
  dotnetSetupHook =
    "${pkgs.path}/pkgs/development/compilers/dotnet/dotnet-setup-hook.sh";

  dotnetSdkSetupHook = pkgs.replaceVars
    "${pkgs.path}/pkgs/development/compilers/dotnet/dotnet-sdk-setup-hook.sh"
    {
      inherit (pkgs) lndir xmlstarlet;
    };

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
        passthru = { inherit rid url hash component; };
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
        passthru = { inherit rid url hash component; };
      };

  combine = name: artifacts:
    let
      hasSdk = lib.any (a: lib.hasPrefix "sdk" (a.component or "")) artifacts;

      # `buildDotnetModule` looks up `dotnet-sdk.targetPackages.<rid>`, so the
      # key has to exist even when we have no out-of-band nuget packs to offer.
      rids = lib.unique (
        lib.filter (r: r != null) (map (a: a.rid or null) artifacts ++ [ hostRid ])
      );

      combined = stdenvNoCC.mkDerivation {
        inherit name;
        setupHooks = [ dotnetSetupHook ] ++ lib.optional hasSdk dotnetSdkSetupHook;
        dontUnpack = true;
        installPhase = ''
          mkdir -p $out/share/dotnet
          ${lib.concatMapStringsSep "\n"
            (a: ''
              cp -a ${a}/share/dotnet/. $out/share/dotnet/
              chmod -R u+w $out/share/dotnet
            '')
            artifacts}
          # Symlink rather than wrap: `dotnet` resolves its own root from
          # argv[0], and nixpkgs' `useDotnetFromEnv` wrappers derive
          # DOTNET_ROOT via `realpath $(which dotnet)` + `dirname`. A wrapper
          # script would make that resolve to `$out/bin`, not `$out/share/dotnet`.
          mkdir -p $out/bin
          for exe in dotnet dnx; do
            if [ -e $out/share/dotnet/$exe ]; then
              ln -s $out/share/dotnet/$exe $out/bin/$exe
            fi
          done
        '';

        meta = {
          description = ".NET toolchain";
          homepage = "https://dotnet.microsoft.com/";
          license = lib.licenses.mit;
          mainProgram = "dotnet";
          platforms = [ stdenvNoCC.hostPlatform.system ];
        };
      };

      # Attributes nixpkgs' `buildDotnetModule` reads off of a `dotnet-sdk` /
      # `dotnet-runtime`. Keep them in sync with
      # pkgs/development/compilers/dotnet/binary/build-dotnet.nix.
      self = combined // {
        packages = [ ];
        targetPackages = lib.genAttrs rids (_: [ ]);
        inherit icu;
        # The combined toolchain contains the runtime, so it doubles as the
        # default `dotnet-runtime` (see `dotnet-runtime ? dotnet-sdk.runtime`).
        runtime = self;
        aspnetcore = null;
        __propagatedSandboxProfile = lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
          (allow file-read* (subpath "/usr/share/icu"))
          (allow file-read* (subpath "/private/var/db/mds/system"))
          (allow mach-lookup (global-name "com.apple.SecurityServer")
                             (global-name "com.apple.system.opendirectoryd.membership"))
        '';
      };
    in
    self;
}
