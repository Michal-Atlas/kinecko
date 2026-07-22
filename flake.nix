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
        {
          haskellProjects.default = {
            projectRoot =
              let
                fs = lib.fileset;
              in
              fs.toSource {
                root = ./.;
                fileset = fs.unions [
                  ./app
                  ./kinecko.cabal
                  ./LICENSE
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
          rust-project.crates.kinecko-rs.crane.args = {
            nativeBuildInputs = with pkgs; [
              pkg-config
              makeWrapper
            ];
            buildInputs = with pkgs; [ openssl.dev ];
          };
          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.haskellProjects.default.outputs.devShell ];
          };
          packages.default = pkgs.runCommand "kinecko" { } ''
            . ${pkgs.makeWrapper}/nix-support/setup-hook
            makeWrapper ${self'.packages.kinecko}/bin/kinecko $out/bin/kinecko \
                          --suffix PATH : ${lib.makeBinPath [ pkgs.gmic ]}
          '';
        };
    };
}
