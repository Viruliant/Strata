{
  description = "Nix environment for Strata";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { system, pkgs, ... }:
        let
          # Default: Desktop app (Tauri) for `nix run`
          pkg = pkgs.callPackage ./package.nix { };
        in {
          packages.default = pkg.default;
          packages.servePkg = pkg.servePkg;
          packages.engine-cpu  = pkg.engine-cpu;
          packages.engine-cuda = pkg.engine-cuda;
          packages.engine-rocm = pkg.engine-rocm;
          devShells.default = pkgs.mkShell {
            packages = [ pkg.servePkg ];
            inputsFrom = [ pkg.servePkg ];
          };
        };
    };
}
