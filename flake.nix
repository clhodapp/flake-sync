# SPDX-License-Identifier: MIT
{

  description = "Assess and converge a workspace's flake repos in DAG order";

  inputs = {
    caisson.url = "github:nix-caisson/caisson";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ caisson, ... }:
    let
      lib = caisson.lib.caisson-core.mkLib {
        inherit inputs;

        projects = {
          inherit caisson;
        };

        libOverlays = mkLibOverlay: {
          default = mkLibOverlay ./lib-overlays/default;
        };
      };
    in
    lib.caisson.mkFlake {
      name = "flake-sync";
      configModule = lib.caisson.mkFlakeModule ./configs/flake-parts/default;
    };

}
