# SPDX-License-Identifier: MIT
#
# Offline NixOS VM test of flake-sync-verify-locks: verify-locks.sh builds
# upstream repositories as local bare repos and checks one branch per
# accepted or refused lock change against them.
{ pkgs, flake-sync-verify-locks }:
pkgs.testers.runNixOSTest {
  name = "flake-sync-verify-locks";

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
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("VERIFY=${pkgs.lib.getExe flake-sync-verify-locks} bash ${./verify-locks.sh} >&2")
  '';
}
