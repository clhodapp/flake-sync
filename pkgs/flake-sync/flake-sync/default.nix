# SPDX-License-Identifier: MIT
{
  lib,
  writeShellApplication,
  coreutils,
  gawk,
  git,
  gnugrep,
  gnused,
  jq,
  nix,
}:
writeShellApplication {
  name = "flake-sync";

  # Everything the script invokes must be declared: this package is
  # consumed inside Claude Code sandbox toolsets, where PATH is the
  # deliberately minimal union of declared toolset closures, not an
  # interactive shell's ambient PATH. Nothing may be assumed already
  # present.
  runtimeInputs = [
    coreutils
    gawk
    git
    gnugrep
    gnused
    jq
    nix
  ];

  # writeShellApplication supplies its own shebang (and shellchecks the
  # result at build time); the file keeps one so it also runs directly
  # from a checkout during development.
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./flake-sync);

  meta = {
    description = "Assess and converge a workspace's flake repos in DAG order";
    mainProgram = "flake-sync";
    license = lib.licenses.mit;
  };
}
