# SPDX-License-Identifier: MIT
{

  description = "Assess and converge a workspace's flake repos in DAG order";

  # Honored only when this flake is evaluated directly (`nix build`,
  # `nix flake check`) and the settings are accepted: answer the prompt,
  # or pass `--accept-flake-config` (a non-interactive run otherwise
  # ignores them with a warning). A consumer that takes this flake as an
  # input gets nothing from it and must declare the caches itself. The
  # two upstreams are part of the deal: the clhodapp cache skips
  # uploading paths they already hold.
  nixConfig = {
    extra-substituters = [
      "https://clhodapp.cachix.org"
      "https://nix-community.cachix.org"
      "https://numtide.cachix.org"
    ];
    extra-trusted-public-keys = [
      "clhodapp.cachix.org-1:EW/0conxH0OQyo0o4ub/grdkFspholmQMSnQyj0vrZI="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    ];
  };

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
