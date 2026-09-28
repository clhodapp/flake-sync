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
  caisson = {
    libOverlays.exported = libOverlays: { inherit (libOverlays) default; };
  };

  # The tool's package is the `default` entry of this flake's package
  # overlay registry (pkg-overlays/, registered on mkLib): the package set
  # applies it by default, and the flake exports it as `pkgOverlays` and
  # as the plain `overlays.default`.
  caisson.nixpkgs = {
    pkgSets.pkgs.pkgFunction = import inputs.nixpkgs;
    packages.export.enabled = true;
  };

  # `nix run github:clhodapp/flake-sync` is the first thing a reader of
  # the README tries, and it needs packages.default to resolve. This
  # repo ships exactly one program, so the alias is unambiguous.
  perSystem =
    { config, ... }:
    {
      packages.default = config.packages.flake-sync;
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson-core.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson-core.pins.flake-compat ../../../tests/dependencies).sources;
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
