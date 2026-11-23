#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Scenarios for flake-sync-verify-locks, offline. Bare repositories on the
# local filesystem stand in for the upstreams:
#
#   dep.git    main C1-C2-C3, branch side S1 (from C1), and F1 (from C3)
#              behind refs/pull/1/head only; uploadpack.allowAnySHA1InWant
#              serves F1 by hash, as GitHub serves a commit of a fork by
#              hash through the upstream's name
#   evil.git   dep's C1 followed by E1, standing in for a fork
#   other.git  an unrelated flake, main O1
#
# The repository under review, app, has a flake with input dep locked at
# C1; ws is a superproject with dep as a submodule at C1. Each scenario
# is a branch of one of them, checked against its base the way the
# workflow checks a pull request.
#
# Env: VERIFY (the verifier executable).

set -euo pipefail

VL=${VERIFY:?set VERIFY to the flake-sync-verify-locks executable}
T=/tmp/vl
mkdir -p "$T"
export GIT_CONFIG_GLOBAL=$T.gitconfig GIT_CONFIG_SYSTEM=/dev/null
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = verify-locks-test
	email = test@example.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
[advice]
	detachedHead = false
EOF

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

commit_file() { # in repo $1, write $3 to file $2 and commit; print the commit
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
  git -C "$1" rev-parse HEAD
}

# ------------------------------------------------------------- upstreams

src=$T/dep-src
git init -q "$src"
printf '{ outputs = _: { }; }\n' >"$src/flake.nix"
C1=$(commit_file "$src" v C1)
C2=$(commit_file "$src" v C2)
C3=$(commit_file "$src" v C3)
git -C "$src" checkout -q -b side "$C1"
S1=$(commit_file "$src" v S1)
git -C "$src" checkout -q -b fork "$C3"
F1=$(commit_file "$src" v F1)
git init -q --bare "$T/dep.git"
git -C "$T/dep.git" config uploadpack.allowAnySHA1InWant true
git -C "$src" push -q "$T/dep.git" "$C3:refs/heads/main" "$S1:refs/heads/side" "$F1:refs/pull/1/head"

git -C "$src" checkout -q -b evil "$C1"
E1=$(commit_file "$src" v E1)
git init -q --bare "$T/evil.git"
git -C "$src" push -q "$T/evil.git" "$E1:refs/heads/main"

osrc=$T/other-src
git init -q "$osrc"
printf '{ outputs = _: { }; }\n' >"$osrc/flake.nix"
O1=$(commit_file "$osrc" v O1)
git init -q --bare "$T/other.git"
git -C "$osrc" push -q "$T/other.git" "$O1:refs/heads/main"

DEP=git+file://$T/dep.git

# ---------------------------------------------------------------- helpers

lock_at() { # lock input $1 of the flake in the current directory at $2 (a flake reference)
  nix flake lock --override-input "$1" "$2" 2>/dev/null
}

edit_lock() { # rewrite ./flake.lock with jq filter $1
  jq "$1" flake.lock >flake.lock.new
  mv flake.lock.new flake.lock
}

commit() { # commit everything in the current directory with message $1
  git add -A
  git commit -q -m "$1"
}

branch() { # start branch $1 at $2 (default main) in the current directory
  git checkout -q -B "$1" "${2:-main}"
}

accepts() { # $1 description, then the verifier arguments
  local desc=$1 out
  shift
  out=$("$VL" "$@" 2>&1) || fail "$desc: rejected: $out"
  echo "ok: $desc"
}

rejects() { # $1 description, $2 text the reasons contain, then the verifier arguments
  local desc=$1 pat=$2 out rc=0
  shift 2
  out=$("$VL" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "$desc: expected exit 1, got $rc: $out"
  grep -qF -- "$pat" <<<"$out" || fail "$desc: expected '$pat' in: $out"
  echo "ok: $desc"
}

# -------------------------------------------------------------- app flake

app=$T/app
git init -q "$app"
cd "$app"
printf '{\n  inputs.dep.url = "%s";\n  outputs = _: { };\n}\n' "$DEP" >flake.nix
echo app >README.md
git add -A
lock_at dep "$DEP?ref=refs/heads/main&rev=$C1"
commit "base"

# A pin move as flake-sync makes it: the override that `update-pins` passes.
branch pm-ok
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
commit "maint: update flake pins (dep)"
accepts "a pin move along the tracked branch passes" --pin-move main pm-ok
rejects "the same move in an ordinary pull request is refused" "pull requests carry no pin moves" main pm-ok

branch pm-two
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
commit "maint: update flake pins (dep)"
lock_at dep "$DEP?ref=refs/heads/main&rev=$C3"
commit "maint: update flake pins (dep)"
accepts "a pin move of two commits passes" --pin-move main pm-two

branch pm-update
nix flake update dep 2>/dev/null
commit "maint: update flake pins (dep)"
accepts "a pin move made with nix flake update passes" --pin-move main pm-update

branch pm-side
lock_at dep "$DEP?ref=refs/heads/side&rev=$S1"
commit "maint: update flake pins (dep)"
rejects "a move to a commit on another branch is refused" "which is not on HEAD of" --pin-move main pm-side

# F1 is fetched through its hidden ref; the lock then claims main.
branch pm-fork
lock_at dep "$DEP?ref=refs/pull/1/head&rev=$F1"
edit_lock '.nodes.dep.locked.ref = "refs/heads/main"'
commit "maint: update flake pins (dep)"
rejects "a move to a commit only behind a hidden ref is refused" "locks $F1, which is not on HEAD" --pin-move main pm-fork

branch at-c3
lock_at dep "$DEP?ref=refs/heads/main&rev=$C3"
commit "maint: update flake pins (dep)"
branch pm-back at-c3
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
commit "maint: update flake pins (dep)"
rejects "a move back to an older commit is refused" "which does not descend from it" --pin-move at-c3 pm-back

branch pm-narhash
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
edit_lock '.nodes.dep.locked.narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
commit "maint: update flake pins (dep)"
rejects "a changed narHash is refused" "is not what nix flake lock writes" --pin-move main pm-narhash

branch pm-lastmod
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
edit_lock '.nodes.dep.locked.lastModified = 1'
commit "maint: update flake pins (dep)"
rejects "a changed lastModified is refused" "is not what nix flake lock writes" --pin-move main pm-lastmod

# The override keeps `original` from flake.nix, so the lock below names
# dep as its source while it locks a commit of evil.
branch pm-locked-url
lock_at dep "git+file://$T/evil.git?ref=refs/heads/main&rev=$E1"
commit "maint: update flake pins (dep)"
[ "$(jq -r .nodes.dep.original.url flake.lock)" = "file://$T/dep.git" ] || fail "the override was expected to keep the original URL"
rejects "a lock of another repository's commit under the input's source is refused" "locks a commit of another repository" --pin-move main pm-locked-url

branch pm-source
lock_at dep "git+file://$T/evil.git?ref=refs/heads/main&rev=$E1"
edit_lock ".nodes.dep.original.url = \"file://$T/evil.git\""
commit "maint: update flake pins (dep)"
rejects "a pin move that changes the input's source is refused" "a pin move adds input dep of flake.lock, or changes where it comes from" --pin-move main pm-source
rejects "an ordinary pull request that changes the source in the lock only is refused" "is not what nix flake lock writes" main pm-source

branch pm-extra-node
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
edit_lock '.nodes.extra = .nodes.dep'
commit "maint: update flake pins (dep)"
rejects "an added node is refused" "is not what nix flake lock writes" --pin-move main pm-extra-node

branch pm-rewire
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
edit_lock '.nodes.dep_2 = .nodes.dep | del(.nodes.dep) | .nodes.root.inputs.dep = "dep_2"'
commit "maint: update flake pins (dep)"
rejects "a rewired root input is refused" "is not what nix flake lock writes" --pin-move main pm-rewire

# jq reads the last of two equal keys; the bytes differ from Nix's output.
branch pm-dupkey
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
sed -i "s|\"rev\": \"$C2\"|\"rev\": \"$S1\", \"rev\": \"$C2\"|" flake.lock
grep -q "\"rev\": \"$S1\", \"rev\": \"$C2\"" flake.lock || fail "the duplicate key was not written"
commit "maint: update flake pins (dep)"
rejects "a duplicated key is refused" "is not what nix flake lock writes" --pin-move main pm-dupkey

branch pm-version
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
edit_lock '.version = 8'
commit "maint: update flake pins (dep)"
rejects "a changed lock version is refused" "is not what nix flake lock writes" --pin-move main pm-version

branch pm-format
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
jq -c . flake.lock >flake.lock.new
mv flake.lock.new flake.lock
commit "maint: update flake pins (dep)"
rejects "a reformatted lock is refused" "the JSON values match; the bytes differ" --pin-move main pm-format

branch pm-readme
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
echo changed >README.md
commit "maint: update flake pins (dep)"
rejects "a pin move that changes another file is refused" "a pin move changes README.md" --pin-move main pm-readme

branch pm-hidden
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
echo changed >README.md
commit "maint: update flake pins (dep)"
hidden=$(git rev-parse HEAD)
echo app >README.md
commit "maint: update flake pins"
rejects "a pin move whose history changes another file is refused" "commit $hidden changes README.md" --pin-move main pm-hidden

branch pm-merge
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
commit "maint: update flake pins (dep)"
git reset -q --hard "$(git commit-tree -p HEAD -p main -m merge 'HEAD^{tree}')"
rejects "a pin move with a merge commit is refused" "parents; a pin move is a line of single-parent commits" --pin-move main pm-merge

branch pr-symlink
cp flake.lock real.lock
ln -sf real.lock flake.lock
commit "use a symlink"
rejects "a lock replaced by a symlink is refused" "flake.lock is not a regular file (mode 120000)" main pr-symlink

branch pr-delete
git rm -q flake.lock
commit "drop the lock"
rejects "a lock deleted while flake.nix remains is refused" "flake.lock is deleted while flake.nix remains" main pr-delete

branch pr-orphan
mkdir -p sub
cp flake.lock sub/flake.lock
commit "add a lock"
rejects "a lock with no flake.nix beside it is refused" "sub/flake.lock has no regular file sub/flake.nix beside it" main pr-orphan

branch pr-code
echo more >>README.md
commit "docs: more"
accepts "a pull request that changes no lock passes" main pr-code

# New inputs: other, on its default branch, and dep2, which is dep again.
add_input() { # add input $1 with URL $2 to flake.nix
  sed -i "s|^  outputs|  inputs.$1.url = \"$2\";\n  outputs|" flake.nix
}

branch pr-add
add_input other "git+file://$T/other.git"
nix flake lock 2>/dev/null
commit "feat: use other"
accepts "an added input locked by nix flake lock passes" main pr-add
rejects "an added input in a pin move is refused" "a pin move changes flake.nix" --pin-move main pr-add

branch pr-add-old
add_input dep2 "$DEP"
lock_at dep2 "$DEP?ref=refs/heads/main&rev=$C1"
commit "feat: use dep2"
accepts "an added input locked at an older commit of its branch passes" main pr-add-old

branch pr-add-side
add_input dep2 "$DEP"
lock_at dep2 "$DEP?ref=refs/heads/side&rev=$S1"
commit "feat: use dep2"
rejects "an added input locked at a commit off its branch is refused" "input dep2 of flake.lock locks $S1, which is not on HEAD" main pr-add-side

branch pr-add-fork
add_input dep2 "$DEP"
lock_at dep2 "$DEP?ref=refs/pull/1/head&rev=$F1"
edit_lock '.nodes.dep2.locked.ref = "refs/heads/main"'
commit "feat: use dep2"
rejects "an added input locked at a hidden commit is refused" "input dep2 of flake.lock locks $F1, which is not on HEAD" main pr-add-fork

branch pr-add-ext
add_input dep2 "$DEP"
lock_at dep2 "$DEP?ref=refs/heads/main&rev=$C1"
edit_lock '.nodes.dep2.original.url = "ext::sh -c touch% /tmp/vl-pwned" | .nodes.dep2.locked.url = .nodes.dep2.original.url'
commit "feat: use dep2"
rejects "an added input with a command URL is refused" "has a URL that is not an https or local URL" main pr-add-ext
[ ! -e /tmp/vl-pwned ] || fail "the command URL ran"
echo "ok: the command URL did not run"

# The base branch moves the pin while the pull request adds an input.
branch moved-base
lock_at dep "$DEP?ref=refs/heads/main&rev=$C2"
commit "maint: update flake pins (dep)"
rejects "a pull request whose lock changed on the base branch since it branched is refused" "rebase the pull request" moved-base pr-add

# --------------------------------------------------------- submodule pointers

ws=$T/ws
git init -q "$ws"
cd "$ws"
git remote add origin "$T/ws.git"
cat >.gitmodules <<EOF
[submodule "dep"]
	path = dep
	url = ../dep.git
	branch = main
EOF
git add .gitmodules
point() { git update-index --add --cacheinfo "160000,$1,dep"; }
point "$C1"
git commit -q -m base

branch ws-ok
point "$C2"
git commit -q -m "maint: bump submodules (dep)"
accepts "a pointer move along the tracked branch passes" --pin-move main ws-ok
rejects "a pointer move in an ordinary pull request is refused" "pull requests carry no pointer moves" main ws-ok

branch ws-side
point "$S1"
git commit -q -m "maint: bump submodules (dep)"
rejects "a pointer move to another branch is refused" "submodule dep locks $S1, which is not on main" --pin-move main ws-side

branch ws-fork
point "$F1"
git commit -q -m "maint: bump submodules (dep)"
rejects "a pointer move to a hidden commit is refused" "submodule dep locks $F1, which is not on main" --pin-move main ws-fork

branch ws-c3
point "$C3"
git commit -q -m "maint: bump submodules (dep)"
branch ws-back ws-c3
point "$C2"
git commit -q -m "maint: bump submodules (dep)"
rejects "a pointer move back to an older commit is refused" "which does not descend from it" --pin-move ws-c3 ws-back

branch ws-url
git config -f .gitmodules submodule.dep.url ../evil.git
git add .gitmodules
point "$E1"
git commit -q -m "maint: bump submodules (dep)"
rejects "a pin move that changes .gitmodules is refused" "a pin move changes .gitmodules" --pin-move main ws-url

echo "ALL VERIFY-LOCKS SCENARIOS PASSED"
