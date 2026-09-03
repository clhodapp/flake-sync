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

  debug = false;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  caisson = {
    configInfo.configName = "flake-sync";
    libOverlays.exported = libOverlays: { inherit (libOverlays) default; };
  };

  caisson.nixpkgs = {
    overlays.all = {
      packages = lib.caisson.nixpkgs.mkPackagesOverlay (
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
      overlayImports = overlays: [ overlays.packages ];
    };
    packages.export.enabled = true;
  };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = lib.caisson-core.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = lib.caisson-core.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = {
              # Building the package proves its declared runtime closure
              # is complete and shellchecks the script.
              package = self.packages.${system}.flake-sync;
              # Full offline lifecycle test against a fake GitHub of
              # local bare repos, driving the packaged executable.
              vm-lifecycle = import ../../../tests/vm {
                inherit pkgs;
                flake-sync = self.packages.${system}.flake-sync;
              };
            };
          };
      };
  };

}
