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

      channelMajor = ch: lib.toInt (lib.head (builtins.splitVersion ch));

      packagesFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hostRid = hostRidFor system;

          mk = pkgs.callPackage ./lib/mk-dotnet.nix { inherit hostRid; };

          normalizeName = lib.replaceStrings [ "." ] [ "_" ];

          fromData = data: lib.mapAttrs' (channel_: info:
            let
              channel = normalizeName channel_;
              components =
                if info ? files
                then info.files
                else lib.filterAttrs (_: v: v ? files) info;
            in
            lib.nameValuePair channel (builtins.mapAttrs (component: files:
              builtins.mapAttrs (rid: f: mk.mkArtifact {
                inherit rid;
                inherit (f) url hash;
                component = component + "-" + channel;
              }) files
            ) components)
          ) data;

          stable = fromData stableData;
          latest = fromData dailyData;

          toolchains = lib.mapAttrs'
            (ch: _: lib.nameValuePair ch (mk.combine
              "dotnet-toolchain-${ch}-${hostRid}" [
              stable.${ch}.runtime.${hostRid}
              stable.${ch}.aspnetcore-runtime.${hostRid}
              stable.${ch}.sdk.${hostRid}
            ]))
            (lib.filterAttrs
              (ch: _:
                stable.${ch}.runtime ? ${hostRid}
                && stable.${ch}.aspnetcore-runtime ? ${hostRid}
                && stable.${ch}.sdk ? ${hostRid})
              stable);

          newest =
            lib.last
              (lib.sort (a: b: channelMajor a < channelMajor b)
                (lib.attrNames toolchains));
        in
        {
          inherit stable latest toolchains;
          default = toolchains.${newest};
        };
    in
    {
      packages = lib.genAttrs systems packagesFor;
    };
}
