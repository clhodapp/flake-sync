# SPDX-License-Identifier: MIT
{ ... }:
{

  overlay = final: prev: {
    flake-sync = prev.flake-sync or { };
  };

}
