# SPDX-License-Identifier: MIT
{
  lib,
  writeShellApplication,
  coreutils,
  gawk,
  gh,
  git,
  jq,
  nix,
  openssh,
}:
writeShellApplication {
  name = "flake-sync-pin-request";

  runtimeInputs = [
    coreutils
    gawk
    gh
    git
    jq
    nix
    openssh
  ];

  text = lib.removePrefix "#!/usr/bin/env bash\n" (
    builtins.readFile ../../../../src/flake-sync-pin-request
  );

  meta = {
    description = "Sign, file and carry out pin requests: issues that ask CI to move flake inputs";
    mainProgram = "flake-sync-pin-request";
    license = lib.licenses.mit;
  };
}
