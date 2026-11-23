# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  flake-sync = callPackage ./flake-sync { };
  flake-sync-skills = callPackage ./flake-sync-skills { };
  flake-sync-verify-locks = callPackage ./flake-sync-verify-locks { };
}
