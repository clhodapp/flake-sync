# SPDX-License-Identifier: MIT
{
  lib,
  writeShellApplication,
  coreutils,
  diffutils,
  gawk,
  git,
  jq,
  nix,
}:
writeShellApplication {
  name = "flake-sync-verify-locks";

  runtimeInputs = [
    coreutils
    diffutils
    gawk
    git
    jq
    nix
  ];

  text = lib.removePrefix "#!/usr/bin/env bash\n" (
    builtins.readFile ../../../../src/flake-sync-verify-locks
  );

  meta = {
    description = "Check that the flake.lock changes of a pull request are what flake-sync would make";
    mainProgram = "flake-sync-verify-locks";
    license = lib.licenses.mit;
  };
}
