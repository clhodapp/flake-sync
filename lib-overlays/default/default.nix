# SPDX-License-Identifier: GPL-3.0-or-later
{ ... }:
{

  overlay = final: prev: {
    flake-sync = prev.flake-sync or { };
  };

}
