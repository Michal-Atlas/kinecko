{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    haskell-flake.url = "github:srid/haskell-flake";
  };
  outputs = {
    nixpkgs,
    flake-parts,
    haskell-flake,
    systems,
    ...
  } @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = import systems;
      imports = [haskell-flake.flakeModule];
      perSystem = {
        pkgs,
        config,
        ...
      }: {
        haskellProjects.default = {
          projectRoot = ./.;
          packages.themoviedb.source = "1.2.2";
          settings.themoviedb.jailbreak = true;
          autoWire = [
            "packages"
            "checks"
            "apps"
          ];
        };
        devShells.default = pkgs.mkShell {
          inputsFrom = [config.haskellProjects.default.outputs.devShell];
        };
      };
    };
}
