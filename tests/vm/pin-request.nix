# SPDX-License-Identifier: MIT
#
# Offline NixOS VM test of flake-sync-pin-request: pin-request.sh files
# requests against a repository of local bare repos and checks what
# `serve` pushes.
{ pkgs, flake-sync-pin-request }:
pkgs.testers.runNixOSTest {
  name = "flake-sync-pin-request";

  nodes.machine =
    { pkgs, ... }:
    {
      virtualisation.writableStore = true;
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        flake-registry = "";
      };
      environment.systemPackages = with pkgs; [
        git
        jq
        openssh
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("PIN_REQUEST=${pkgs.lib.getExe flake-sync-pin-request} bash ${./pin-request.sh} >&2")
  '';
}
