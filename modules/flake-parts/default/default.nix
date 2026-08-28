# SPDX-License-Identifier: MIT
{ closure-inputs, ... }:
{ ... }:
{
  imports = [
    closure-inputs.ch-flake.flakeModules.default
    closure-inputs.ch-nixpkgs.flakeModules.default
  ];
}
