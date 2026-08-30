#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Builds a miniature "fake GitHub" for testing flake-sync: bare git
# repos on the local filesystem act as the remote hub, and a workspace clone
# with flake submodules cross-pinned via git+file inputs mirrors a real
# submodule workspace layout (lib <- app <- machines, plus the workspace
# itself pinning lib and tracking all three as submodules). Entirely offline.
# extdep is a fourth hub repo, pinned by app but never tracked as a
# workspace submodule, standing in for a real external input like nixpkgs.
#
# Env: HUB (bare repo dir), WORK (workspace clone dir).

set -euo pipefail

HUB=${HUB:?set HUB to the directory for the bare fake-github repos}
WORK=${WORK:?set WORK to the directory for the workspace clone}

export GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-$HUB.gitconfig}
export GIT_CONFIG_SYSTEM=/dev/null
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = flake-sync-test
	email = test@example.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
EOF

mkdir -p "$HUB"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

mkflake() { # $1 = dir; remaining args = input=url pairs
  local dir=$1; shift
  {
    echo '{'
    local pair
    for pair in "$@"; do
      echo "  inputs.${pair%%=*}.url = \"${pair#*=}\";"
    done
    echo '  outputs = _: { };'
    echo '}'
  } >"$dir/flake.nix"
}

hub_url() { echo "git+file://$HUB/$1.git"; }

mkrepo() { # $1 = name; remaining args = input=url pairs.
  # DEVDEPS (input=url pairs, space-separated) adds a partition-style
  # tests/dependencies subflake with its own tracked lock.
  local name=$1; shift
  local dir=$BUILD/$name
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo "$name v1" >"$dir/README.md"
  mkflake "$dir" "$@"
  if [ -n "${DEVDEPS:-}" ]; then
    mkdir -p "$dir/tests/dependencies"
    # shellcheck disable=SC2086
    mkflake "$dir/tests/dependencies" $DEVDEPS
    git -C "$dir" add -A
    nix flake lock "$dir/tests/dependencies"
    # Always-unlocked test flake: inputs come from nix wiring at eval time,
    # so its lockfile is gitignored (mirrors tests/integration/* upstream).
    mkdir -p "$dir/tests/integration/basic"
    # shellcheck disable=SC2086
    mkflake "$dir/tests/integration/basic" $DEVDEPS
    echo 'tests/integration/*/flake.lock' >"$dir/.gitignore"
  fi
  git -C "$dir" add -A
  [ $# -eq 0 ] || nix flake lock "$dir"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "init $name"
  git init -q --bare "$HUB/$name.git"
  git -C "$dir" push -q "file://$HUB/$name.git" main
}

# extdep is a plain hub repo never tracked as a workspace submodule: app's
# pin to it is "external" (--with-external) rather than a sibling pin.
mkrepo extdep
mkrepo lib
DEVDEPS="lib=$(hub_url lib)"
mkrepo app "lib=$(hub_url lib)" "extdep=$(hub_url extdep)"
unset DEVDEPS
mkrepo machines "lib=$(hub_url lib)" "app=$(hub_url app)"

ws=$BUILD/workspace
mkdir -p "$ws"
git -C "$ws" init -q
mkflake "$ws" "lib=$(hub_url lib)"
git -C "$ws" add -A
nix flake lock "$ws"
for sub in lib app machines; do
  git -C "$ws" submodule -q add "file://$HUB/$sub.git" "projects/$sub"
done
git -C "$ws" add -A
git -C "$ws" commit -qm "init workspace"
git init -q --bare "$HUB/workspace.git"
git -C "$ws" push -q "file://$HUB/workspace.git" main

git clone -q --recurse-submodules "file://$HUB/workspace.git" "$WORK"
git -C "$WORK" submodule -q foreach 'git checkout -q main'

echo "fixture ready: hub=$HUB work=$WORK"
