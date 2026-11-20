# SPDX-License-Identifier: MIT
#
# The checks of flake-sync: a flake-parts configuration declared inside
# the flake-parts caisson top (configs/flake/flake-sync), whose
# dependencies are those of the caisson top with the pins of
# tests/dependencies beside them. The caisson top gathers the checks
# declared here into its `checks` output. A flake that lists flake-sync
# as an input reads nothing of this configuration, so it locks none of
# the pins of tests/dependencies.
{ ... }:
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem =
    { pkgs, ... }:
    {
      # Duplicated in the formatter partition of configs/flake/flake-sync:
      # the partition and this configuration are separate evaluations.
      treefmt.programs.nixfmt.enable = true;

      caisson.checks = {
        treefmt = {
          category = "format";
          description = "the Nix files are formatted with nixfmt";
        };
        vm-lifecycle = {
          derivation = import ../../../tests/vm {
            inherit pkgs;
            inherit (pkgs.flake-sync) flake-sync;
          };
          category = "vm";
          description = "the packaged executable converges a workspace of local bare repositories and a fake GitHub, offline";
        };
      };
    };
}
