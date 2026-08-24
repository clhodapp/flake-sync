# SPDX-License-Identifier: GPL-3.0-or-later
{
  lib,
  writeShellApplication,
  git,
  gh,
  nix,
  jq,
}:
writeShellApplication {
  name = "flake-sync";

  # git/gh/nix/jq are hard runtime dependencies of scripts/flake-sync
  # itself, not just of this wrapper, and must be declared explicitly:
  # this package is meant to be consumed inside Claude Code sandbox
  # toolsets, where PATH is the deliberately minimal union of declared
  # toolset closures, not an interactive shell's ambient PATH. Nothing
  # may be assumed already present.
  runtimeInputs = [
    git
    gh
    nix
    jq
  ];

  text = ''
    # Locate a checked-out scripts/flake-sync to exec — never a store
    # copy, which would go stale and have no workspace to operate on.
    # This lookup only has to find A checkout: scripts/flake-sync
    # re-derives the true workspace root itself, from its own on-disk
    # location (BASH_SOURCE[0]) once exec'd, independent of our cwd.
    root=$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)
    if [ -z "$root" ]; then
      root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    fi

    if [ -z "$root" ] || [ ! -x "$root/scripts/flake-sync" ]; then
      echo "flake-sync: error: not inside a ch-nix-workspace checkout" \
           "(run from within the workspace or one of its submodules)" >&2
      exit 1
    fi

    exec "$root/scripts/flake-sync" "$@"
  '';

  meta = with lib; {
    description = "Wrapper that execs the checked-out ch-nix-workspace scripts/flake-sync";
    mainProgram = "flake-sync";
    license = licenses.gpl3Plus;
  };
}
