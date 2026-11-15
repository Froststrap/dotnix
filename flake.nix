{
  description = ".NET toolchain management.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      lib = nixpkgs.lib;

      hostRidFor = system: {
        x86_64-linux = "linux-x64";
        aarch64-linux = "linux-arm64";
        x86_64-darwin = "osx-x64";
        aarch64-darwin = "osx-arm64";
      }.${system};

      stableData = builtins.fromJSON (builtins.readFile ./data/stable.json);
      dailyData = builtins.fromJSON (builtins.readFile ./data/daily.json);

      # "11-0" -> 11
      channelMajor = ch: lib.toInt (lib.head (builtins.splitVersion ch));

      newestVersion =
        versions:
        lib.last (lib.sort (a: b: channelMajor a < channelMajor b) (builtins.attrNames versions));

      packagesFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hostRid = hostRidFor system;

          mk = pkgs.callPackage ./lib/mk-dotnet.nix { inherit hostRid pkgs; };

          normalizeName = lib.replaceStrings [ "." ] [ "-" ];

          # data file -> { <version> = { <component> = { <rid> = derivation; }; }; }
          #
          # stable.json is { files = { <component> = { <rid> = ...; }; }; }
          # daily.json  is { <component> = { files = { <rid> = ...; }; }; }
          mkArtifacts = data: lib.mapAttrs' (version_: info:
            let
              version = normalizeName version_;
              components =
                if info ? files
                then info.files
                else lib.mapAttrs (_: v: v.files) (lib.filterAttrs (_: v: v ? files) info);
            in
            lib.nameValuePair version (lib.mapAttrs (component: files:
              builtins.mapAttrs (rid: f: mk.mkArtifact {
                inherit rid;
                inherit (f) url hash;
                component = component + "-" + version;
              }) files
            ) components)
          ) data;

          stableArtifacts = mkArtifacts stableData;
          dailyArtifacts = mkArtifacts dailyData;

          # One release feed of one version, host RID baked in:
          #
          #   <component>          -> runtime | aspnetcore-runtime | sdk
          #   default              -> the combined toolchain
          #   all                  -> every component as a list (for `combine`)
          #   rids                 -> components keyed by every upstream RID
          #
          # Empty (filtered out) when the feed ships nothing for this host RID.
          mkSource = version: source: artifacts:
            let
              perRid = artifacts.${version} or { };
              host = lib.mapAttrs (_: files: files.${hostRid})
                (lib.filterAttrs (_: files: files ? ${hostRid}) perRid);
            in
            lib.optionalAttrs ((builtins.attrNames host) != [ ]) (
              host // {
                default = mk.combine "dotnet-toolchain-${version}-${source}-${hostRid}"
                  (lib.attrValues host);
                all = lib.attrValues host;
                rids = perRid;
              }
            );

          # { "11-0" = { stable = <source>; latest = <source>; }; "10-0" = ...; }
          allVersions =
            lib.unique (builtins.attrNames stableArtifacts ++ builtins.attrNames dailyArtifacts);

          versions = lib.filterAttrs (_: v: builtins.attrNames v != [ ])
            (lib.genAttrs allVersions (version:
              let
                stable = mkSource version "stable" stableArtifacts;
                latest = mkSource version "latest" dailyArtifacts;
              in
              lib.optionalAttrs (builtins.attrNames stable != [ ]) { inherit stable; }
              // lib.optionalAttrs (builtins.attrNames latest != [ ]) { inherit latest; }
            ));

          newest = versions.${newestVersion versions};
        in
        {
          # Raw, per-RID artifact builder.
          inherit (mk) mkArtifact;

          # Combine a list of components into one toolchain:
          #
          #   let dotnet = dotnix.packages.${system}; in
          #   dotnet.combine [ dotnet."11-0".stable.runtime dotnet."11-0".stable.sdk ]
          combine = artifacts: mk.combine "dotnet-toolchain-${hostRid}" artifacts;

          # Newest version's stable toolchain.
          default = (if newest ? stable then newest.stable else newest.latest).default;
        }
        // versions;
    in
    {
      packages = lib.genAttrs systems packagesFor;
    };
}
