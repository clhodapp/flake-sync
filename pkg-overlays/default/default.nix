# SPDX-License-Identifier: MIT
#
# The default package overlay: the flake-sync tool under
# `pkgs.flake-sync` (packages/default.nix lists it). A consumer that
# lists this flake in `projects` holds it as `flake-sync/default`, which
# its package sets apply by default. The scope name is bound here, so the
# package lands under `pkgs.flake-sync` in any consumer.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay (
    { callPackage, ... }: import ./packages { inherit callPackage; }
  ) "flake-sync";
}
