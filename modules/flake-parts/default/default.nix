# SPDX-License-Identifier: GPL-3.0-or-later
{ closure-inputs, ... }:
{ ... }:
{
  imports = [
    closure-inputs.ch-flake.flakeModules.default
    closure-inputs.ch-nixpkgs.flakeModules.default
  ];
}
