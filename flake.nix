{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default-linux";
    haskell-flake.url = "github:srid/haskell-flake";
    rust-flake.url = "github:juspay/rust-flake";
  };
  outputs =
    {
      nixpkgs,
      flake-parts,
      haskell-flake,
      rust-flake,
      systems,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;
      imports = [
        haskell-flake.flakeModule
        rust-flake.flakeModules.default
        rust-flake.flakeModules.nixpkgs
      ];
      perSystem =
        {
          self',
          pkgs,
          config,
          lib,
          ...
        }:
        let
          fs = lib.fileset;
        in
        {
          haskellProjects.default = {
            projectRoot = fs.toSource {
              root = ./haskell;
              fileset = fs.unions [
                ./haskell/app
                ./haskell/kinecko-hs.cabal
              ];
            };
            packages.themoviedb.source = "1.2.2";
            settings.themoviedb.jailbreak = true;
            autoWire = [
              "packages"
              "checks"
              "apps"
            ];
          };
          rust-project = {
            src = lib.cleanSourceWith {
              src = ./rust;
              filter = config.rust-project.crane-lib.filterCargoSources;
            };
            cargoToml = lib.importTOML ./rust/Cargo.toml;
            toolchain =
              (pkgs.rust-bin.fromRustupToolchainFile ./rust/rust-toolchain.toml).override
                {
                  extensions = [
                    "rust-src"
                    "rust-analyzer"
                    "clippy"
                  ];
                };
          };
          rust-project.crates.kinecko-rs.crane.args = {
            nativeBuildInputs = with pkgs; [
              pkg-config
              makeWrapper
            ];
            buildInputs = with pkgs; [ openssl.dev ];
          };
          devShells.haskell = config.haskellProjects.default.outputs.devShell;
          packages.kinecko-net = pkgs.buildDotnetModule {
            name = "kinecko-net";
            src = fs.toSource {
              root = ./fsharp;
              fileset = fs.unions [
                ./fsharp/kinecko-net.fsproj
                ./fsharp/Program.fs
              ];
            };
            nugetDeps = ./fsharp/nuget-deps.json;
            dotnet-sdk = pkgs.dotnetCorePackages.sdk_11_0;
          };
        };
    };
}
