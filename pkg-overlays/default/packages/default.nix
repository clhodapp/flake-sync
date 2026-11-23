# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  flake-sync = callPackage ./flake-sync { };
  flake-sync-skills = callPackage ./flake-sync-skills { };
}
