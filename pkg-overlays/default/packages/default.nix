# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  flake-sync = callPackage ./flake-sync { };
  flake-sync-pin-request = callPackage ./flake-sync-pin-request { };
  flake-sync-skills = callPackage ./flake-sync-skills { };
  flake-sync-verify-locks = callPackage ./flake-sync-verify-locks { };
}
