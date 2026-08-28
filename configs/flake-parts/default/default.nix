# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  self,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  ch-flake = {
    configInfo.configName = "flake-sync";
    libOverlays.exported = libOverlays: {
      inherit (libOverlays)
        default
        ch-nixpkgs
        ;
    };
    modules = {
      flake.exported = modules: { inherit (modules) default; };
    };
  };

  ch-nixpkgs = {
    overlays.all = {
      packages = lib.ch-nixpkgs.mkPackagesOverlay (
        { callPackage, ... }: import ../../../pkgs/flake-sync { inherit callPackage; }
      );
    };
    overlays.export = {
      enabled = true;
    };
    overlays.exported = overlays: {
      inherit (overlays) packages;
    };
    pkgSets.pkgs = {
      pkgFunction = import inputs.nixpkgs;
      overlayImports = overlays: [
        inputs.ch-nixpkgs.overlays.default
        overlays.packages
      ];
    };
    packages.export.enabled = true;
  };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = lib.ch-flake.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = lib.ch-flake.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = {
              # Building the package proves its declared closure
              # (git/gh/nix/jq) is complete; it cannot exercise
              # scripts/flake-sync's own logic since no workspace
              # checkout exists inside the Nix build sandbox.
              package = self.packages.${system}.flake-sync;
            };
          };
      };
  };

}
