# SPDX-License-Identifier: MIT
#
# Hermetic NixOS VM test for the flake-sync package. The VM has no
# network; fixture.sh builds a "fake GitHub" out of local bare repos and
# scenarios.sh drives the packaged executable through a full DAG-ordered
# convergence lifecycle against it, including workspace-root discovery
# from the cwd. Run via: nix build .#checks.x86_64-linux.vm-lifecycle
{ pkgs, flake-sync }:
pkgs.testers.runNixOSTest {
  name = "flake-sync";

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
    env = "HUB=/tmp/hub WORK=/tmp/workspace"
    machine.succeed(f"{env} bash ${./fixture.sh} >&2")
    machine.succeed(f"{env} FLAKE_SYNC=${pkgs.lib.getExe flake-sync} bash ${./scenarios.sh} >&2")
  '';
}
