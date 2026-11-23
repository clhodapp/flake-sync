#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Drives flake-sync through a convergence lifecycle against the
# fake-github fixture from fixture.sh. Exits nonzero on the first failed
# assertion. Env: HUB, WORK (as passed to fixture.sh), FLAKE_SYNC (the
# flake-sync executable under test; it discovers the workspace from the
# cwd, so it lives outside $WORK).

set -euo pipefail

HUB=${HUB:?}
WORK=${WORK:?}
FLAKE_SYNC=${FLAKE_SYNC:?set FLAKE_SYNC to the flake-sync executable under test}
case $FLAKE_SYNC in /*) ;; *) FLAKE_SYNC=$PWD/$FLAKE_SYNC ;; esac
export GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL:-$HUB.gitconfig}
export GIT_CONFIG_SYSTEM=/dev/null

cd "$WORK"
FS=$FLAKE_SYNC

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { # haystack, needle, description
  case $1 in
    *"$2"*) echo "ok: $3" ;;
    *) printf 'output was:\n%s\n' "$1" >&2; fail "$3 (missing: '$2')" ;;
  esac
}

hub_rev() { git --git-dir="$HUB/$1.git" rev-parse main; }
head_rev() { git -C "$1" rev-parse HEAD; }
lock_rev() { # flake dir, input name -> locked rev
  jq -r --arg i "$2" '.nodes[.nodes[.root].inputs[$i]].locked.rev' "$1/flake.lock"
}
assert_converged() {
  local out; out=$($FS status)
  expect_contains "$out" "Converged" "$1"
}

echo "=== 1. fresh fixture is converged"
assert_converged "initial state is converged"

echo "=== 2. new commit in lib -> downstream stale, next is push lib"
echo change >projects/lib/feature.txt
git -C projects/lib add feature.txt
git -C projects/lib commit -qm "feat: change lib"
out=$($FS status)
expect_contains "$out" "ahead 1" "lib shows an unpushed commit"
out=$($FS next)
expect_contains "$out" "push lib" "next action is push lib"

echo "=== 3. one step pushes lib to the fake github"
$FS step
[ "$(hub_rev lib)" = "$(head_rev projects/lib)" ] || fail "hub lib.git did not advance"
echo "ok: hub lib.git is at lib HEAD"
out=$($FS next)
expect_contains "$out" "update-pins app" "next action re-pins app"

echo "=== 3b. override-inputs prints a flake ref with the overrides that move its stale workspace inputs to the hub heads, read-only"
state_of_repos() { # HEADs, hub refs, and porcelain status of every repo
  local r
  for r in lib app machines; do head_rev "projects/$r"; done
  head_rev .
  for r in lib app machines extdep workspace; do hub_rev "$r"; done
  git status --porcelain --ignore-submodules=none
  for r in lib app machines; do git -C "projects/$r" status --porcelain; done
}
before=$(state_of_repos)
machines_ref="git+file://$HUB/machines.git"
lib_tip=$(hub_rev lib)
flags="--override-input app/lib git+file://$HUB/lib.git?rev=$lib_tip --override-input lib git+file://$HUB/lib.git?rev=$lib_tip"
out=$($FS override-inputs "$machines_ref")
[ "$out" = "$machines_ref $flags" ] || { printf 'output was:\n%s\n' "$out" >&2; fail "override-inputs prints the ref, then lib and app/lib, and nothing else"; }
echo "ok: override-inputs names the stale lib inputs, not the current app or the external extdep"
out=$($FS override-inputs "$machines_ref#host")
[ "$out" = "$machines_ref#host $flags" ] || { printf 'output was:\n%s\n' "$out" >&2; fail "override-inputs keeps the #attr on the ref"; }
echo "ok: override-inputs keeps the #attr and looks up the flake without it"
[ "$before" = "$(state_of_repos)" ] || fail "override-inputs must not change any repo state"
echo "ok: override-inputs is read-only"
# The output is meant to be split into words.
# shellcheck disable=SC2046
resolved=$(nix flake metadata --json $($FS override-inputs "$machines_ref") | jq -r '.locks as $L | $L.nodes[$L.nodes[$L.root].inputs.lib].locked.rev')
[ "$resolved" = "$lib_tip" ] || fail "the output does not move lib to the hub head ($resolved)"
echo "ok: the output, passed in place of a flake ref, resolves lib to the hub head"

echo "=== 3c. override-inputs encodes a local flake ref with a space"
spaced="$(dirname "$WORK")/machines copy"
git clone -q "file://$HUB/machines.git" "$spaced"
out=$($FS override-inputs "$spaced")
ref=${out%% *}
case $ref in
  git+file://*%20copy) ;;
  *) printf 'output was:\n%s\n' "$out" >&2; fail "a ref with a space is printed encoded" ;;
esac
[ "${out#* }" = "$flags" ] || { printf 'output was:\n%s\n' "$out" >&2; fail "the encoded ref keeps its overrides"; }
# shellcheck disable=SC2046
resolved=$(nix flake metadata --json $($FS override-inputs "$spaced") | jq -r '.locks as $L | $L.nodes[$L.nodes[$L.root].inputs.lib].locked.rev')
[ "$resolved" = "$lib_tip" ] || fail "the encoded output does not resolve ($resolved)"
echo "ok: a local ref with a space is printed encoded and resolves"
rm -rf "$spaced"

echo "=== 3d. override-inputs --local moves inputs to the HEADs of this checkout's submodules"
echo local >projects/lib/local.txt
git -C projects/lib add local.txt
git -C projects/lib commit -qm "feat: an unpushed change"
local_rev=$(head_rev projects/lib)
local_flags="--override-input app/lib git+file://$WORK/projects/lib?rev=$local_rev --override-input lib git+file://$WORK/projects/lib?rev=$local_rev"
out=$($FS --local override-inputs "$machines_ref" 2>"$HUB.err")
[ "$out" = "$machines_ref $local_flags" ] || { printf 'output was:\n%s\n' "$out" >&2; fail "--local moves lib and app/lib to the submodule HEAD"; }
[ ! -s "$HUB.err" ] || { cat "$HUB.err" >&2; fail "a clean submodule needs no warning"; }
echo "ok: --local names the unpushed lib HEAD of the checkout"
# shellcheck disable=SC2046
resolved=$(nix flake metadata --json $($FS --local override-inputs "$machines_ref") | jq -r '.locks as $L | $L.nodes[$L.nodes[$L.root].inputs.lib].locked.rev')
[ "$resolved" = "$local_rev" ] || fail "the --local output does not resolve lib to the submodule HEAD ($resolved)"
echo "ok: the --local output resolves lib to the submodule HEAD"
echo edited >>projects/lib/README.md
out=$($FS --local override-inputs "$machines_ref" 2>"$HUB.err")
[ "$out" = "$machines_ref $local_flags" ] || fail "uncommitted changes do not change the pinned HEAD"
expect_contains "$(cat "$HUB.err")" "uncommitted changes" "a dirty submodule is warned about on stderr"
git -C projects/lib checkout -q -- README.md
git -C projects/lib reset -q --hard HEAD~1
[ "$before" = "$(state_of_repos)" ] || fail "3d did not restore the repos"

echo "=== 3e. --latest-flake-sync runs the flake named by FLAKE_SYNC_UPSTREAM with the same arguments"
upstream=$HUB.upstream
mkdir -p "$upstream"
printf '#!/bin/sh\necho "upstream $*"\n' >"$upstream/run"
chmod +x "$upstream/run"
cat >"$upstream/flake.nix" <<'EOF'
{
  outputs = _: let app = { type = "app"; program = "${./run}"; }; in {
    apps.x86_64-linux.default = app;
    apps.aarch64-linux.default = app;
  };
}
EOF
out=$(FLAKE_SYNC_UPSTREAM="path:$upstream" $FS status --latest-flake-sync --fetch)
[ "$out" = "upstream status --fetch" ] || fail "--latest-flake-sync runs the upstream with the other arguments (got '$out')"
echo "ok: --latest-flake-sync runs the upstream with the same arguments, less the flag"
out=$(FLAKE_SYNC_LATEST_ACTIVE=1 FLAKE_SYNC_UPSTREAM="path:$upstream" $FS --latest-flake-sync status)
case $out in upstream*) fail "the started copy ran the upstream again" ;; esac
expect_contains "$out" "machines" "the started copy ignores --latest-flake-sync and runs its status"

echo "=== 4. converge finishes everything in DAG order"
$FS converge
for consumer in app machines; do
  [ "$(lock_rev "projects/$consumer" lib)" = "$(head_rev projects/lib)" ] \
    || fail "$consumer lock is not on lib HEAD"
done
[ "$(lock_rev projects/machines app)" = "$(head_rev projects/app)" ] \
  || fail "machines lock is not on app HEAD"
[ "$(lock_rev . lib)" = "$(head_rev projects/lib)" ] || fail "workspace lock is not on lib HEAD"
for sub in lib app machines; do
  [ "$(git ls-tree HEAD -- "projects/$sub" | awk '{print $3}')" = "$(head_rev "projects/$sub")" ] \
    || fail "workspace pointer for $sub is stale"
  [ "$(hub_rev "$sub")" = "$(head_rev "projects/$sub")" ] || fail "hub $sub.git is not at local HEAD"
done
[ "$(hub_rev workspace)" = "$(head_rev .)" ] || fail "hub workspace.git is not at local HEAD"
echo "ok: locks, pointers, and hub refs all advanced"
git -C projects/app log -1 --format=%s | grep -q '^maint: update flake pins (lib)$' \
  || fail "app pin commit message is wrong"
echo "ok: pin commit message"
assert_converged "converge reaches converged state"

echo "=== 5. dirty consumer blocks the re-pin of that consumer; the rest proceeds"
echo dirt >>projects/app/README.md
echo change2 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: change lib again"
rc=0; out=$($FS converge) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should exit nonzero while blocked"
expect_contains "$out" "update-pins app" "dirty app reported as blocker"
expect_contains "$out" "uncommitted" "blocker mentions uncommitted changes"
[ "$(lock_rev projects/machines lib)" = "$(head_rev projects/lib)" ] \
  || fail "machines should converge around the dirty app"
echo "ok: machines converged around dirty app"
git -C projects/app commit -aqm "fix: app change"
$FS converge
assert_converged "converged after committing app"

echo "=== 6. detached HEAD blocks automation"
git -C projects/lib checkout -q --detach
echo change3 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: detached change"
rc=0; out=$($FS converge) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should block on detached HEAD"
expect_contains "$out" "detached" "detached HEAD reported"
git -C projects/lib checkout -q -B main
$FS converge
assert_converged "converged after re-attaching branch"

echo "=== 7. remote moved under us: clear message, no auto-rebase, rest proceeds"
side=$(mktemp -d)/lib
git clone -q "$HUB/lib.git" "$side"
echo upstream-change >>"$side/README.md"
git -C "$side" commit -aqm "feat: concurrent upstream change"
git -C "$side" push -q
echo local-change >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: local lib change"
echo app-change >>projects/app/README.md
git -C projects/app commit -aqm "feat: independent app change"
rc=0; out=$($FS converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should report the rejected push"
expect_contains "$out" "rejected" "rejected push gets a clear message"
expect_contains "$out" "behind by 1 commit" "message states how far behind"
expect_contains "$out" "pull --rebase" "message suggests the manual fix"
[ "$(hub_rev app)" = "$(head_rev projects/app)" ] || fail "independent app push should still happen"
echo "ok: converge continued with independent work"
[ "$(git -C projects/lib rev-parse HEAD)" != "$(hub_rev lib)" ] || fail "lib must not be auto-rebased/pushed"
echo "ok: no auto-rebase happened"
[ "$(lock_rev projects/machines app)" = "$(head_rev projects/app)" ] \
  || fail "machines should advance its app pin while the lib pin is held"
[ "$(lock_rev projects/machines lib)" != "$(head_rev projects/lib)" ] \
  || fail "machines must not pin the unpushed lib rev"
expect_contains "$out" "held back" "partial advance is reported"
echo "ok: sibling pin advanced; unpushed lib pin held individually"
git -C projects/lib pull --rebase -q
$FS converge
assert_converged "converged after manual rebase"

echo "=== 8. partition locks are managed only with --with-partitions"
assert_converged "default view stays converged despite stale dev pin"
[ "$(lock_rev projects/app/tests/dependencies lib)" != "$(head_rev projects/lib)" ] \
  || fail "expected app's dev pin to be stale by now"
out=$($FS --with-partitions status)
expect_contains "$out" "tests/dependencies:lib=stale" "dev pin staleness visible with the flag"
out=$($FS --with-partitions next)
expect_contains "$out" "update-pins app" "next action re-pins app's dev lock"
$FS --with-partitions converge
[ "$(lock_rev projects/app/tests/dependencies lib)" = "$(head_rev projects/lib)" ] \
  || fail "dev pin should advance to lib HEAD"
git -C projects/app log -1 --format=%s | grep -q 'tests/dependencies:lib' \
  || fail "commit message should name the dev pin"
[ "$(hub_rev app)" = "$(head_rev projects/app)" ] || fail "app dev-pin commit should be pushed"
out=$($FS --with-partitions status)
expect_contains "$out" "Converged" "fully converged including partitions"
echo "ok: partition pins converge under --with-partitions"

echo "=== 9. stray locks in always-unlocked test flakes are reported with --all"
out=$($FS --all status)
expect_contains "$out" "Converged" "no stray lock yet"
echo '{"nodes":{},"root":"root","version":7}' >projects/app/tests/integration/basic/flake.lock
out=$($FS --all status)
expect_contains "$out" "Converged" "stray lock is informational, not blocking"
expect_contains "$out" "stray untracked lock" "stray lock reported"
expect_contains "$out" "tests/integration/basic/flake.lock" "stray lock path named"
out=$($FS --with-partitions status)
case $out in *stray*) fail "stray-lock check should need --with-tests/--all" ;; esac
echo "ok: stray-lock check is opt-in"
$FS --all converge >/dev/null
echo "ok: warnings don't fail converge"
rm projects/app/tests/integration/basic/flake.lock
out=$($FS --all status)
case $out in *stray*) fail "stray warning should clear after removal" ;; esac
echo "ok: warning clears after deleting the stray lock"

echo "=== 9b. external pins are opt-in via --with-external and advance like siblings"
out=$($FS status)
case $out in *ext:*) fail "external pins must not show without --with-external" ;; esac
out=$($FS --with-external status)
expect_contains "$out" "ext:extdep=ok" "extdep shows as an ok external pin under --with-external"
side=$(mktemp -d)/extdep
git clone -q "$HUB/extdep.git" "$side"
echo upstream-change >>"$side/README.md"
git -C "$side" commit -aqm "feat: upstream extdep change"
git -C "$side" push -q
out=$($FS --with-external status)
expect_contains "$out" "ext:extdep=stale" "extdep goes stale once upstream advances"
out=$($FS --with-external next)
expect_contains "$out" "update-pins app" "next action re-pins app's external input"
prev_extdep_rev=$(lock_rev projects/app extdep)
$FS --with-external converge
[ "$(lock_rev projects/app extdep)" = "$(git -C "$side" rev-parse HEAD)" ] \
  || fail "app's extdep pin should advance to the new upstream rev"
[ "$(lock_rev projects/app extdep)" != "$prev_extdep_rev" ] || fail "extdep pin did not move"
git -C projects/app log -1 --format=%s | grep -q '^maint: update flake pins (extdep)$' \
  || fail "external pin commit message should name the input"
echo "ok: external pin commit message"
[ "$(lock_rev projects/machines app)" = "$(head_rev projects/app)" ] \
  || fail "machines should re-pin to app's new HEAD after the external-pin advance cascades"
out=$($FS --with-external status)
expect_contains "$out" "Converged" "fully converged including the external pin"
echo "ok: external pins advance under --with-external and cascade like sibling pins"

echo "=== 10. failing check holds only its target; siblings still advance"
cat >projects/machines/flake.nix <<EOF
{
  inputs.lib.url = "git+file://$HUB/lib.git";
  inputs.app.url = "git+file://$HUB/app.git";
  outputs = inputs: { checks = inputs.lib.checks or { }; };
}
EOF
git -C projects/machines commit -aqm "feat: machines consumes lib checks"
$FS converge >/dev/null
assert_converged "converged after wiring machines to lib checks"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: throw "lib exploded";
}
EOF
git -C projects/lib commit -aqm "feat: breaking lib change"
echo benign >>projects/app/README.md
git -C projects/app commit -aqm "feat: benign app change"
rc=0; out=$($FS converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should report the held pin"
expect_contains "$out" "holding lib (fails nix flake check)" "check failure holds lib"
expect_contains "$out" "held back" "partial advance reported"
[ "$(lock_rev projects/machines app)" = "$(head_rev projects/app)" ] \
  || fail "machines should still advance its app pin"
[ "$(lock_rev projects/machines lib)" != "$(head_rev projects/lib)" ] \
  || fail "machines must not pin the check-failing lib rev"
[ "$(lock_rev projects/app lib)" = "$(head_rev projects/lib)" ] \
  || fail "app (which does not consume lib outputs) should advance its lib pin"
echo "ok: check failure held lib pin; siblings and unaffected repos advanced"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: { };
}
EOF
git -C projects/lib commit -aqm "fix: lib works again"
$FS converge >/dev/null
[ "$(lock_rev projects/machines lib)" = "$(head_rev projects/lib)" ] \
  || fail "machines should advance its lib pin once the check passes"
assert_converged "converged after fixing lib"

echo "=== 11. --check mode flags"
echo change4 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: one more lib change"
$FS step lib >/dev/null # push lib so downstream re-pins become ready
out=$($FS -n step app)
expect_contains "$out" "nix flake check" "default mode validates with nix flake check"
expect_contains "$out" "--no-build" "eval mode (--no-build) is the default"
out=$($FS --check=full -n step app)
expect_contains "$out" "nix flake check" "--check=full still validates"
case $out in *--no-build*) fail "--check=full must not pass --no-build" ;; esac
echo "ok: full mode builds the checks"
out=$($FS --check=none -n step app)
case $out in *"nix flake check"*) fail "--check=none must skip validation" ;; esac
expect_contains "$out" "nix flake lock" "--check=none still advances pins"
rc=0; $FS --check=bogus status >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "unknown --check mode should be rejected"
echo "ok: unknown --check mode rejected"
$FS converge >/dev/null
assert_converged "converged at the end of the check-mode scenarios"

echo "=== 12. step skips a failing action when another move is available"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: throw "lib exploded again";
}
EOF
git -C projects/lib commit -aqm "feat: breaking lib change 2"
rc=0; $FS converge >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "converge should hold machines while lib is broken"
echo note >NOTES.md
git add NOTES.md
git commit -qm "docs: workspace note"
rc=0; out=$($FS step 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "step should succeed via the next available move"
expect_contains "$out" "update-pins machines failed; trying the next ready action" "failing action is skipped"
[ "$(hub_rev workspace)" = "$(head_rev .)" ] \
  || fail "step should have fallen through to pushing the workspace"
[ "$(lock_rev projects/machines lib)" != "$(head_rev projects/lib)" ] \
  || fail "machines must still not pin the broken lib"
echo "ok: step made progress around the failing action"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: { };
}
EOF
git -C projects/lib commit -aqm "fix: lib works once more"
$FS converge >/dev/null
assert_converged "converged after the final lib fix"

echo "=== 13. graph, --fetch, and explicit step forms"
out=$($FS graph)
expect_contains "$out" "topological order" "graph prints the ordering"
expect_contains "$out" "machines" "graph lists repos"
expect_contains "$out" "<- " "graph lists dependency edges"
$FS status --fetch >/dev/null || fail "status --fetch should succeed"
echo "ok: status --fetch works"
echo change5 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: yet another lib change"
$FS step push lib >/dev/null
[ "$(hub_rev lib)" = "$(head_rev projects/lib)" ] || fail "explicit push did not push lib"
$FS step update-pins app >/dev/null
[ "$(lock_rev projects/app lib)" = "$(head_rev projects/lib)" ] \
  || fail "explicit update-pins did not advance app's lib pin"
$FS step app >/dev/null # repo-filtered: next ready app action is its push
[ "$(hub_rev app)" = "$(head_rev projects/app)" ] || fail "repo-filtered step did not push app"
echo "ok: explicit and repo-filtered step forms work"
$FS converge >/dev/null
assert_converged "converged at the very end"

echo "=== 14. check runs every repo's checks without moving anything"
snapshot_state() { # HEADs, hub refs, and porcelain status of every repo
  local r
  for r in lib app machines; do head_rev "projects/$r"; done
  head_rev .
  for r in lib app machines extdep workspace; do hub_rev "$r"; done
  git status --porcelain --ignore-submodules=none
  for r in lib app machines; do git -C "projects/$r" status --porcelain; done
}
before=$(snapshot_state)
out=$($FS check)
expect_contains "$out" "All checks passed" "check passes on the converged workspace"
expect_contains "$out" "--no-build" "check defaults to eval depth"
[ "$before" = "$(snapshot_state)" ] || fail "check must not change any repo state"
echo "ok: check is read-only"
out=$($FS --with-partitions check app)
expect_contains "$out" "check passed: app:tests/dependencies" "partition flakes join check with --with-partitions"
case $out in *"check passed: lib"*) fail "check app must not check other repos" ;; esac
echo "ok: repo-filtered check with partitions"
rc=0; $FS --check=none check >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "check with --check=none should be rejected"
echo "ok: --check=none is rejected for check"
out=$($FS --check=full -n check lib)
expect_contains "$out" "nix flake check" "dry-run check prints the command"
case $out in *--no-build*) fail "--check=full check must not pass --no-build" ;; esac
echo "ok: dry-run and --check=full forms"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: throw "lib exploded for the check sweep";
}
EOF
git -C projects/lib commit -aqm "feat: breaking lib change 3"
rc=0; out=$($FS check 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "check should exit nonzero when a repo fails"
expect_contains "$out" "check FAILED: lib" "failing repo is named"
expect_contains "$out" "flake check(s) failed" "summary reports the failures"
expect_contains "$out" "check passed: app" "sweep continues past the failure"
before=$(snapshot_state)
$FS check >/dev/null 2>&1 || true
[ "$before" = "$(snapshot_state)" ] || fail "a failing check must not change any repo state"
echo "ok: failing check is loud, non-fatal to the sweep, and still read-only"
cat >projects/lib/flake.nix <<'EOF'
{
  outputs = _: { };
}
EOF
git -C projects/lib commit -aqm "fix: lib works at last"
$FS converge >/dev/null
assert_converged "converged after the check-command scenarios"

echo "=== 15. converge --local advances working-tree locks, commits and pushes nothing"
echo change6 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: lib change for local mode"
$FS step push lib >/dev/null # publish lib; downstream pins become ready
echo dirt >>projects/app/README.md            # a dirty tree must not block --local
git -C projects/machines checkout -q --detach # nor a detached HEAD
before_heads=$(head_rev projects/app; head_rev projects/machines; head_rev .)
before_hub=$(hub_rev lib; hub_rev app; hub_rev machines; hub_rev workspace)
out=$($FS converge --local)
expect_contains "$out" "Locally converged" "local converge reports local convergence"
[ "$(lock_rev projects/app lib)" = "$(head_rev projects/lib)" ] \
  || fail "local mode should advance app's lib pin in the working tree"
[ "$(lock_rev projects/machines lib)" = "$(head_rev projects/lib)" ] \
  || fail "local mode should advance machines' lib pin despite the detached HEAD"
[ "$(lock_rev . lib)" = "$(head_rev projects/lib)" ] \
  || fail "local mode should advance the lock of the workspace repo"
[ "$before_heads" = "$(head_rev projects/app; head_rev projects/machines; head_rev .)" ] \
  || fail "local mode must not create commits"
[ "$before_hub" = "$(hub_rev lib; hub_rev app; hub_rev machines; hub_rev workspace)" ] \
  || fail "local mode must not push"
! git -C projects/app diff --quiet -- flake.lock \
  || fail "app's lock change should be uncommitted"
out=$($FS --local status)
expect_contains "$out" "Locally converged" "--local status agrees"
rc=0; $FS --local step push lib >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--local must refuse an explicit push"
echo "ok: --local advanced locks only and refused publication"
# The locks --local wrote are previews of exactly what publication will
# commit; drop them and let the publishing path redo the same advances
# through the same gate.
git -C projects/app checkout -q -- README.md flake.lock
git -C projects/machines checkout -q -- flake.lock
git -C projects/machines checkout -q main
git checkout -q -- flake.lock
$FS converge >/dev/null
git -C projects/app log -1 --format=%s | grep -q '^maint: update flake pins (lib)$' \
  || fail "publication should commit the same pin advance --local previewed"
assert_converged "full converge publishes what --local previewed"

echo "=== 16. a drv-closure check is held by the eval gate until it is rewritten"
# A check that consumes another derivation's drvPath carries a
# derivation-deep string context, which derivationStrict expands by
# reading every .drv in the graph from the store. The read-only
# --no-build eval never wrote them, so the check fails with "is not
# valid" and the gate holds the pin (NixOS/nix#15448; the workspace
# keeps its flakes free of the pattern, see known-issues.md). Embedding
# the source path of the flake makes the inner derivation unique per
# fixture run, so a warm host store cannot mask the failure.
cat >projects/app/flake.nix <<EOF
{
  inputs.lib.url = "git+file://$HUB/lib.git";
  inputs.extdep.url = "git+file://$HUB/extdep.git";
  outputs = _: {
    checks.x86_64-linux.drv-read-back =
      let
        base = derivation {
          name = "drv-warm-base";
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [ "-c" "echo \${toString ./.} > \$out" ];
        };
      in
      derivation {
        name = "drv-warm-probe";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "echo ok > \$out" ];
        baseDrv = base.drvPath;
      };
  };
}
EOF
git -C projects/app commit -aqm "feat: app gains a drv-closure check"
echo change7 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: lib change for the drv-closure scenario"
rc=0; out=$($FS converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should report the held pin"
expect_contains "$out" "is not valid" "nix names the .drv the read-only eval could not write"
expect_contains "$out" "holding lib (fails nix flake check)" "the drv-closure check holds app's lib pin"
[ "$(lock_rev projects/app lib)" != "$(head_rev projects/lib)" ] \
  || fail "app must not pin lib while its check cannot evaluate read-only"
rc=0; out=$($FS check app 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "check should fail on the drv-closure pattern"
expect_contains "$out" "check FAILED: app" "standalone check reports the same failure"
cat >projects/app/flake.nix <<EOF
{
  inputs.lib.url = "git+file://$HUB/lib.git";
  inputs.extdep.url = "git+file://$HUB/extdep.git";
  outputs = _: { };
}
EOF
git -C projects/app commit -aqm "fix: app drops the drv-closure check"
$FS converge >/dev/null
[ "$(lock_rev projects/app lib)" = "$(head_rev projects/lib)" ] \
  || fail "app's lib pin should advance once its check evaluates read-only"
assert_converged "converged after dropping the drv-closure check"

echo "=== 17. pull down-syncs a checkout the remotes have moved past"
old_ws=$(head_rev .)
old_lib=$(head_rev projects/lib)
old_app=$(head_rev projects/app)
old_machines=$(head_rev projects/machines)
echo change8 >>projects/lib/feature.txt
git -C projects/lib commit -aqm "feat: lib change for the pull scenario"
$FS converge >/dev/null
# Rewind to the classic stale checkout: workspace behind its upstream,
# submodule mains old, HEADs detached at the old pointers, one submodule
# registered (git submodule init) but not cloned.
git reset -q --hard "$old_ws"
git -C projects/lib reset -q --hard "$old_lib"
git -C projects/app reset -q --hard "$old_app"
git -C projects/machines reset -q --hard "$old_machines"
git submodule -q update
git submodule -q deinit -f projects/machines >/dev/null
git submodule -q init projects/machines
out=$($FS status 2>&1)
expect_contains "$out" "flake-sync pull" "blocked plan points at the pull verb"
out=$($FS pull)
expect_contains "$out" "Pulled" "pull reports success"
[ "$(head_rev .)" = "$(hub_rev workspace)" ] || fail "workspace should fast-forward to the hub"
for sub in lib app machines; do
  [ "$(git -C "projects/$sub" symbolic-ref --short HEAD)" = main ] \
    || fail "$sub should end on main, not a detached HEAD"
  [ "$(head_rev "projects/$sub")" = "$(git ls-tree HEAD -- "projects/$sub" | awk '{print $3}')" ] \
    || fail "$sub should sit at the recorded pointer"
  [ "$(head_rev "projects/$sub")" = "$(hub_rev "$sub")" ] || fail "$sub should be at the hub tip"
done
assert_converged "pulled checkout is converged"
echo "ok: pull re-attached every submodule at the new pointers"

echo "=== 18. pull holds what it must not touch"
git -C projects/lib checkout -qb topic
rc=0; out=$($FS pull) || rc=$?
[ "$rc" -ne 0 ] || fail "pull should exit nonzero while lib is parked on a topic branch"
expect_contains "$out" "parked on branch topic" "topic branch is held, not yanked"
[ "$(git -C projects/lib symbolic-ref --short HEAD)" = topic ] || fail "lib must stay on topic"
git -C projects/lib checkout -q main
echo local >>projects/lib/local.txt
git -C projects/lib add local.txt
git -C projects/lib commit -qm "feat: local-only lib work"
out=$($FS pull)
expect_contains "$out" "ahead of the recorded pointer" "unpushed work on main is a note, not a hold"
git -C projects/lib log -1 --format=%s | grep -q 'local-only lib work' \
  || fail "pull must not drop the local commit"
# Now the remote side converges past that local commit (a side workspace
# stands in for CI convergence), turning lib's main into a true divergence.
side=$(mktemp -d)/lib
git clone -q "$HUB/lib.git" "$side"
echo upstream >>"$side/README.md"
git -C "$side" commit -aqm "feat: upstream lib work"
git -C "$side" push -q
sidews=$(mktemp -d)/ws
git clone -q --recurse-submodules "file://$HUB/workspace.git" "$sidews"
git -C "$sidews" submodule -q foreach 'git checkout -q main' >/dev/null
(cd "$sidews" && "$FS" converge >/dev/null)
rc=0; out=$($FS pull) || rc=$?
[ "$rc" -ne 0 ] || fail "pull should exit nonzero while lib's main has diverged"
expect_contains "$out" "diverged" "divergence is held with a clear reason"
git -C projects/lib log -1 --format=%s | grep -q 'local-only lib work' \
  || fail "pull must not touch the diverged branch"
[ "$(head_rev projects/app)" = "$(git ls-tree HEAD -- projects/app | awk '{print $3}')" ] \
  || fail "app should sync even while lib is held"
git -C projects/lib reset -q --hard origin/main
$FS pull >/dev/null
echo dirt >>projects/app/README.md # no-move dirt must not hold anything
$FS pull >/dev/null || fail "pull should tolerate dirt when nothing needs to move"
git -C projects/app checkout -q -- README.md
assert_converged "converged after the pull scenarios"
echo "ok: pull held the diverged branch, synced siblings, and tolerated no-move dirt"

echo "=== 18b. pull --heads reaches the remote tips before convergence records them"
# A landing nobody has converged yet: lib's main moves on the hub, and no
# pin commit or pointer bump follows it.
side=$(mktemp -d)/lib
git clone -q "$HUB/lib.git" "$side"
echo heads >>"$side/README.md"
git -C "$side" commit -aqm "feat: lib change nobody has converged yet"
git -C "$side" push -q
out=$($FS pull)
expect_contains "$out" "CI convergence may be mid-flight" "plain pull notes the lagging pointer"
[ "$(head_rev projects/lib)" != "$(hub_rev lib)" ] || fail "plain pull must stay at the recorded pointer"
rc=0; out=$($FS converge --heads 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "--heads must be rejected outside pull"
out=$($FS pull --heads)
expect_contains "$out" "Pulled" "pull --heads reports success"
expect_contains "$out" "past the recorded pointer" "the lagging pointer is a note, not a hold"
[ "$(head_rev projects/lib)" = "$(hub_rev lib)" ] || fail "lib should sit at the hub tip"
[ "$(git -C projects/lib symbolic-ref --short HEAD)" = main ] || fail "lib should be on main, not detached"
[ "$(head_rev projects/app)" = "$(hub_rev app)" ] || fail "app should still sit at its tip"
# From the remotes' state, local convergence writes the lock the next
# convergence run will commit (exit 1 is expected: app's new lock is
# unpushed, so machines is held).
rc=0; $FS converge --local >/dev/null || rc=$?
[ "$(lock_rev projects/app lib)" = "$(hub_rev lib)" ] \
  || fail "converge --local should re-pin app to lib's tip after pull --heads"
$FS converge >/dev/null
assert_converged "converged after the pull --heads scenario"
echo "ok: pull --heads reached the remote tips and local convergence followed"

echo "=== 19. root discovery follows the cwd"
# A submodule cwd resolves to the enclosing workspace: status run from
# inside projects/lib still sees every repo, machines included.
scratch=$(mktemp -d)/ws
git clone -q --recurse-submodules "file://$HUB/workspace.git" "$scratch"
git -C "$scratch" submodule -q foreach 'git checkout -q main' >/dev/null
out=$(cd "$scratch/projects/lib" && "$FS" status)
expect_contains "$out" "machines" "a submodule cwd resolves to the enclosing workspace"
# A submodule of a submodule resolves to the parent-most enclosing repo.
git -C "$scratch/projects/lib" submodule -q add "file://$HUB/extdep.git" vendor/extdep
out=$(cd "$scratch/projects/lib/vendor/extdep" && "$FS" status)
expect_contains "$out" "machines" "a nested submodule cwd resolves to the parent-most workspace"
# A repo that is nobody's submodule is a root by itself (here a repo without
# submodules, so the .gitmodules requirement names that repo itself).
plain=$(mktemp -d)/plain
git clone -q "file://$HUB/lib.git" "$plain"
plain_root=$(git -C "$plain" rev-parse --show-toplevel)
rc=0; out=$(cd "$plain" && "$FS" status 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a repo without submodules should be rejected as a root"
expect_contains "$out" "$plain_root has no .gitmodules" "a repo that is nobody's submodule is a root by itself"
# Outside any git repo, flake-sync fails with a clear message. The
# ceiling keeps git from walking above the scratch dir, so the scenario
# holds even when TMPDIR itself sits inside some checkout.
nowhere=$(cd "$(mktemp -d)" && pwd -P)
rc=0; out=$(cd "$nowhere" && GIT_CEILING_DIRECTORIES=$nowhere "$FS" status 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "flake-sync should fail outside any git repository"
expect_contains "$out" "not inside a git repository" "non-repo cwd fails with a clear message"
echo "ok: root discovery follows the cwd"

echo "=== 20. --fetch refreshes the default and checked-out branches, and falls back to a full fetch"
elsewhere=$(mktemp -d)
git clone -q "file://$HUB/machines.git" "$elsewhere/machines"
git clone -q "file://$HUB/app.git" "$elsewhere/app"
# A commit pushed elsewhere to machines' default branch.
echo default >"$elsewhere/machines/default.txt"
git -C "$elsewhere/machines" add default.txt
git -C "$elsewhere/machines" commit -qm "feat: on main elsewhere"
git -C "$elsewhere/machines" push -q origin main
# app checked out on a topic branch, which then moves elsewhere.
git -C "$elsewhere/app" push -q origin main:topic
git -C projects/app fetch -q origin topic:refs/remotes/origin/topic
git -C projects/app checkout -q -b topic --track origin/topic
echo topic >"$elsewhere/app/topic.txt"
git -C "$elsewhere/app" add topic.txt
git -C "$elsewhere/app" commit -qm "feat: on topic elsewhere"
git -C "$elsewhere/app" push -q origin HEAD:topic
# A commit of the lib checkout that reaches the hub only on a branch the
# checkout does not track: git records the push as origin/side, so the
# ref is deleted again to stand for a branch pushed from elsewhere.
echo side >projects/lib/side.txt
git -C projects/lib add side.txt
git -C projects/lib commit -qm "feat: only on side"
git -C projects/lib push -q origin HEAD:refs/heads/side
git -C projects/lib update-ref -d refs/remotes/origin/side
[ -z "$(git -C projects/lib for-each-ref --contains HEAD refs/remotes)" ] || fail "the side commit should be on no remote-tracking ref yet"
$FS --fetch status >/dev/null 2>&1 || true
[ "$(git -C projects/machines rev-parse origin/main)" = "$(hub_rev machines)" ] \
  || fail "the default branch was not refreshed"
echo "ok: --fetch refreshes the default branch"
[ "$(git -C projects/app rev-parse origin/topic)" = "$(git --git-dir="$HUB/app.git" rev-parse topic)" ] \
  || fail "the checked-out topic branch's upstream was not refreshed"
echo "ok: --fetch refreshes the upstream of a checked-out topic branch"
[ "$(git -C projects/lib rev-parse origin/side 2>/dev/null)" = "$(head_rev projects/lib)" ] \
  || fail "a commit only on an untracked remote branch needs the full-fetch fallback"
echo "ok: a HEAD on no fetched ref falls back to a full fetch"
# Moving machines' remote makes its fetch fail.
git -C projects/machines remote set-url origin "file://$HUB/missing.git"
out=$($FS --fetch status 2>&1 || true)
git -C projects/machines remote set-url origin "file://$HUB/machines.git"
expect_contains "$out" "fetch failed for machines" "a failed fetch is still reported"
git -C projects/app checkout -q main

echo "=== 21. pull works in a checkout that holds only some submodules"
git -C projects/lib reset -q --hard origin/main
git submodule deinit -q -f projects/machines
[ ! -e projects/machines/.git ] || fail "test setup: machines should be out of the checkout"
rc=0; out=$($FS pull 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { printf 'output was:\n%s\n' "$out" >&2; fail "pull should succeed without the unregistered machines"; }
[ ! -e projects/machines/.git ] || fail "pull must not check out an unregistered submodule"
expect_contains "$out" "not checked out here, left alone: projects/machines" "pull names the submodule it left out"
[ "$(git -C projects/app symbolic-ref --short HEAD)" = main ] || fail "pull still syncs the submodules that are checked out"
echo "ok: pull leaves out an unregistered submodule and syncs the rest"
git submodule init -q projects/machines
$FS pull >/dev/null
[ -e projects/machines/.git ] || fail "pull should clone a submodule registered with git submodule init"
echo "ok: pull clones a submodule that is registered but not cloned"

echo "=== 22. the other commands treat a submodule that is not checked out as a workspace repo read from its remote"
# Scenario 20 moved machines on the hub, past the recorded pointer.
$FS --heads pull >/dev/null 2>&1 || fail "test setup: pull --heads should sync to the hub tips"
out=$($FS --fetch converge 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "test setup: the workspace should converge before scenario 22"; }
git submodule deinit -q -f projects/app
# app moves on the hub while its lib pin stays current: machines and the
# workspace pointer go stale, and app can stay out.
elsewhere=$(mktemp -d)
git clone -q "file://$HUB/app.git" "$elsewhere/app"
echo moved >"$elsewhere/app/moved.txt"
git -C "$elsewhere/app" add moved.txt
git -C "$elsewhere/app" commit -qm "feat: app moves elsewhere"
git -C "$elsewhere/app" push -q origin main
out=$($FS --fetch status 2>&1)
expect_contains "$out" "not checked out" "status lists app as not checked out"
expect_contains "$out" "app=stale" "status sees machines' pin onto the absent app"
out=$($FS graph 2>&1)
expect_contains "$out" "machines              <- app lib" "graph keeps the absent app in the DAG"
out=$($FS --fetch converge 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "converge should need no checkout of app to re-pin machines onto it"; }
[ ! -e projects/app/.git ] || fail "converge must not check out app without --checkout-missing"
[ "$(lock_rev projects/machines app)" = "$(hub_rev app)" ] || fail "machines should pin the hub's app"
[ "$(git ls-tree HEAD projects/app | awk '{print $3}')" = "$(hub_rev app)" ] || fail "the workspace pointer of the absent app should be bumped"
[ -z "$(git status --porcelain)" ] || { git status --porcelain >&2; fail "the bump should leave the index matching HEAD"; }
echo "ok: converge re-pins onto and bumps the pointer of a repo that stays out"
# lib moves, so app now holds a stale lib pin: advancing it needs a checkout.
echo again >projects/lib/again.txt
git -C projects/lib add again.txt
git -C projects/lib commit -qm "feat: lib moves again"
git -C projects/lib push -q origin main
rc=0; out=$($FS --fetch converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should fail while the absent app holds a stale pin"
expect_contains "$out" "stale pins (lib) but not checked out here; rerun with --checkout-missing" "the blocker names the flag"
[ ! -e projects/app/.git ] || fail "converge must not check out app without --checkout-missing"
[ "$(lock_rev projects/machines lib)" = "$(hub_rev lib)" ] || fail "machines should still advance its lib pin"
echo "ok: without --checkout-missing, converge advances the rest and fails on the absent app"
$FS --fetch --checkout-missing converge >/dev/null 2>&1 || fail "converge --checkout-missing should converge"
[ "$(git -C projects/app symbolic-ref --short HEAD)" = main ] || fail "the checkout of app should be on main"
[ "$(lock_rev projects/app lib)" = "$(hub_rev lib)" ] || fail "app should pin the hub's lib"
assert_converged "converge --checkout-missing checks out app and converges"
# A pin onto an unpushed target cannot advance, so it causes no clone.
git submodule deinit -q -f projects/app
echo unpushed >projects/lib/unpushed.txt
git -C projects/lib add unpushed.txt
git -C projects/lib commit -qm "feat: unpushed"
rc=0; out=$($FS --local --checkout-missing converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should report the unpushed lib"
expect_contains "$out" "update-pins app: stale pin(s) to unpushed target(s): lib" "the absent app is blocked on the unpushed lib"
[ ! -e projects/app/.git ] || fail "a pin that cannot advance must not cause a checkout"
echo "ok: --checkout-missing clones only a repo whose pins can advance"
git -C projects/lib reset -q --hard origin/main
out=$($FS check 2>&1)
expect_contains "$out" "not checked out here, so not checked: app" "check names the repo it could not check"
$FS checkout app >/dev/null
[ "$(git -C projects/app symbolic-ref --short HEAD)" = main ] || fail "checkout should attach app to main"
[ "$(head_rev projects/app)" = "$(git ls-tree HEAD projects/app | awk '{print $3}')" ] || fail "checkout should leave app at the recorded pointer"
git submodule deinit -q -f projects/app projects/machines
$FS checkout --all >/dev/null
[ -e projects/app/.git ] && [ -e projects/machines/.git ] || fail "checkout --all should check out every absent submodule"
assert_converged "checkout --all restores the full checkout"

echo "=== 23. converge commits the pins a --local run advanced, and blocks on other lock changes"
echo local-then-full >projects/lib/local-then-full.txt
git -C projects/lib add local-then-full.txt
git -C projects/lib commit -qm "feat: lib moves before a local run"
git -C projects/lib push -q origin main
$FS converge --local >/dev/null 2>&1 || fail "converge --local should advance the working-tree locks"
[ "$(lock_rev projects/app lib)" = "$(head_rev projects/lib)" ] || fail "test setup: --local should advance app's working-tree lock"
git -C projects/app diff --quiet HEAD -- flake.lock && fail "test setup: app's lock should be uncommitted after --local"
out=$($FS status)
expect_contains "$out" "lib=stale" "status counts a pin advanced only in the working tree as stale"
$FS converge >/dev/null 2>&1 || fail "converge should commit and push the advanced locks"
git -C projects/app diff --quiet HEAD -- flake.lock || fail "converge should commit app's advanced lock"
[ "$(git --git-dir="$HUB/app.git" show main:flake.lock | jq -r '.nodes[.nodes[.root].inputs.lib].locked.rev')" = "$(head_rev projects/lib)" ] \
  || fail "the hub's app should pin lib's head"
assert_converged "a full converge after --local publishes the locks"
# A lock change that is not a pin flake-sync manages blocks, rather than
# reading as converged.
stray=$(mktemp)
jq '.stray = true' projects/app/flake.lock >"$stray"
cp "$stray" projects/app/flake.lock
rc=0; out=$($FS converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "converge should not report convergence over an uncommitted lock change"
expect_contains "$out" "commit app: uncommitted changes in flake.lock that are not pin updates flake-sync manages" "the blocker names the lock"
git -C projects/app checkout -q -- flake.lock
assert_converged "discarding the change converges again"

echo "=== 24. in a linked worktree of the workspace, checkout shares the module repos and pins move only by explicit steps"
wt=$(mktemp -d)/wt
git worktree add -q -b agent-topic "$wt"
modules=$(git rev-parse --path-format=absolute --git-common-dir)/modules
out=$(cd "$wt" && "$FS" checkout lib app 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "checkout in a linked worktree"; }
for s in lib app; do
  [ "$(cat "$wt/projects/$s/.git")" = "gitdir: $modules/projects/$s/worktrees/$s" ] \
    || fail "$s should be a linked worktree of the shared module repo, not a clone: $(cat "$wt/projects/$s/.git")"
  [ "$(git -C "$wt/projects/$s" symbolic-ref --short HEAD)" = agent-topic ] || fail "$s should be on the branch of the workspace worktree"
  [ "$(head_rev "$wt/projects/$s")" = "$(hub_rev "$s")" ] || fail "$s should start at the hub's main"
done
[ ! -d "$(git -C "$wt" rev-parse --path-format=absolute --git-dir)/modules" ] || fail "the linked worktree should hold no private module repos"
[ "$(git -C projects/lib symbolic-ref --short HEAD)" = main ] || fail "the primary's lib should stay on main"
echo "ok: checkout in a linked worktree adds linked worktrees of the shared module repos on the worktree's branch"
echo topic >"$wt/projects/lib/topic.txt"
git -C "$wt/projects/lib" add topic.txt
git -C "$wt/projects/lib" commit -qm "feat: lib change on a topic branch"
rc=0; out=$(cd "$wt" && "$FS" --fetch converge 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a publishing converge should refuse in a linked worktree"
expect_contains "$out" "converge publishes from the primary checkout" "converge in a linked worktree points at the primary checkout"
rc=0; out=$(cd "$wt" && "$FS" step 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "step with no action should refuse in a linked worktree"
git --git-dir="$HUB/lib.git" rev-parse -q --verify agent-topic >/dev/null && fail "nothing should be pushed by the refused commands"
echo "ok: a linked worktree refuses converge and step with no action"
rc=0; out=$(cd "$wt" && "$FS" step update-pins app 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "update-pins should refuse in a linked worktree"
expect_contains "$out" "topic branches carry no pin moves" "update-pins in a linked worktree names the rule"
echo app-topic >"$wt/projects/app/topic.txt"
git -C "$wt/projects/app" add topic.txt
git -C "$wt/projects/app" commit -qm "feat: app change that needs the lib change"
rc=0; out=$(cd "$wt" && "$FS" --fetch step push app 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "app should not be pushed while lib has unpushed commits"
expect_contains "$out" "app depends on lib, which has unpushed commits" "the refusal names the dependency"
(cd "$wt" && "$FS" --fetch step push lib) >/dev/null 2>&1 || fail "step push lib should push lib's topic branch"
[ "$(git --git-dir="$HUB/lib.git" rev-parse agent-topic)" = "$(head_rev "$wt/projects/lib")" ] || fail "lib's topic branch should be on the hub"
[ "$(git --git-dir="$HUB/lib.git" rev-parse main)" != "$(head_rev "$wt/projects/lib")" ] || fail "lib's main must not move"
(cd "$wt" && "$FS" --fetch step push app) >/dev/null 2>&1 || fail "app should push once lib is pushed"
[ "$(git --git-dir="$HUB/app.git" rev-parse agent-topic)" = "$(head_rev "$wt/projects/app")" ] || fail "app's topic branch should be on the hub"
git -C "$wt/projects/app" diff --quiet "$(hub_rev app)" -- flake.lock || fail "app's topic branch must carry no lock move"
echo "ok: topic branches push in dependency order and carry no pin moves"
state_of() { jq -r --arg r "$1" '.[] | select(.repo == $r) | .state' <<<"$2"; }
out=$(cd "$wt" && "$FS" --fetch unmerged-commits --json 2>/dev/null) || fail "unmerged-commits --json"
[ "$(jq -r 'map(.repo) | join(" ")' <<<"$out")" = "lib app" ] || { echo "$out" >&2; fail "unmerged-commits should list lib, then app"; }
[ "$(state_of lib "$out")" = ready ] || fail "lib depends on no listed repo, so it is ready"
[ "$(state_of app "$out")" = "dependencies not ready" ] || fail "app waits on lib"
[ "$(jq -r '.[] | select(.repo == "app") | .dependsOn | join(" ")' <<<"$out")" = lib ] || fail "app should name lib as its dependency"
echo "ok: unmerged-commits lists the changes in dependency order with their readiness"
# lib's pull request merges: its topic branch becomes the hub's main.
git --git-dir="$HUB/lib.git" update-ref refs/heads/main "$(git --git-dir="$HUB/lib.git" rev-parse agent-topic)"
out=$(cd "$wt" && "$FS" --fetch unmerged-commits --json 2>/dev/null) || fail "unmerged-commits --json after the merge"
[ "$(jq -r 'map(.repo) | join(" ")' <<<"$out")" = app ] || { echo "$out" >&2; fail "only app should be left"; }
[ "$(state_of app "$out")" = "waiting for convergence" ] || fail "app's main still pins the old lib"
echo "ok: after the dependency merges, the consumer waits for convergence"
$FS --heads pull >/dev/null 2>&1 || fail "pull --heads in the primary"
$FS --fetch converge >/dev/null 2>&1 || fail "converge in the primary after the merge"
out=$(cd "$wt" && "$FS" --fetch unmerged-commits --json 2>/dev/null) || fail "unmerged-commits --json after convergence"
[ "$(state_of app "$out")" = ready ] || { echo "$out" >&2; fail "app should be ready once its main pins the merged lib"; }
echo "ok: once the default branch converges, the consumer is ready"
git worktree remove --force "$wt"
for s in lib app machines; do git -C "$modules/projects/$s" worktree prune; done

echo "=== 25. outside CI, pin commits reach a GitHub default branch through a pull request merged at once"
gh2=$(mktemp -d)
mkdir -p "$gh2/hub" "$gh2/fake"
git init -q --bare "$gh2/hub/one.git"
git init -q --bare "$gh2/hub/ws2.git"
git clone -q "$gh2/hub/one.git" "$gh2/one-src"
echo '{ outputs = _: { }; }' >"$gh2/one-src/flake.nix"
git -C "$gh2/one-src" add flake.nix
git -C "$gh2/one-src" commit -qm "init one"
git -C "$gh2/one-src" push -q origin main
# GitHub URLs, redirected to the local hub.
git config --global "url.file://$gh2/hub/.insteadOf" "git@github.com:test/"
git init -q "$gh2/ws2"
git -C "$gh2/ws2" remote add origin git@github.com:test/ws2.git
git -C "$gh2/ws2" submodule -q add git@github.com:test/one.git projects/one
git -C "$gh2/ws2" commit -qm "init ws2"
git -C "$gh2/ws2" push -q -u origin main
git -C "$gh2/ws2/projects/one" checkout -q main
# A stand-in for gh: it logs its arguments and merges on the local hub.
# FAKE_GH_BLOCK makes a merge fail as required checks would, unless it
# passes --admin.
cat >"$gh2/fake/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_DIR/log"
case "$1 $2" in
  "api repos/test/one") echo "$FAKE_GH_METHODS" ;;
  "pr create")
    while [ $# -gt 0 ]; do [ "$1" = --head ] && echo "$2" >"$FAKE_GH_DIR/head"; shift; done
    echo "https://github.com/test/one/pull/1" ;;
  "pr merge")
    case " $* " in *" --auto "*) exit 0 ;; esac
    case " $* " in *" --admin "*) ;; *) [ -z "${FAKE_GH_BLOCK:-}" ] || exit 1 ;; esac
    c=$(mktemp -d)
    git clone -q "$FAKE_GH_HUB/one.git" "$c"
    git -C "$c" fetch -q origin "$(cat "$FAKE_GH_DIR/head")"
    git -C "$c" merge -q --squash FETCH_HEAD
    git -C "$c" commit -qm "$(git -C "$c" log -1 --format=%s FETCH_HEAD) (#1)"
    git -C "$c" push -q origin main ;;
  "pr view") echo BLOCKED ;;
esac
FAKE
chmod +x "$gh2/fake/gh"
export FLAKE_SYNC_GH=$gh2/fake/gh FAKE_GH_DIR=$gh2/fake FAKE_GH_HUB=$gh2/hub FAKE_GH_METHODS=squash
pin_commit() { # commit a pin-update-shaped change $1 in one
  echo "$1" >"$gh2/ws2/projects/one/$1.txt"
  git -C "$gh2/ws2/projects/one" add "$1.txt"
  git -C "$gh2/ws2/projects/one" commit -qm "maint: update flake pins ($1)"
}
hub_one() { git --git-dir="$gh2/hub/one.git" rev-parse main; }
pin_commit lib
pinned=$(head_rev "$gh2/ws2/projects/one")
out=$(cd "$gh2/ws2" && "$FS" step push one 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "step push one through a pull request"; }
grep -q -- "pr merge -R test/one https://github.com/test/one/pull/1 --squash" "$gh2/fake/log" || { cat "$gh2/fake/log" >&2; fail "the merge should use the allowed method, squash"; }
[ "$(git --git-dir="$gh2/hub/one.git" log -1 --format=%s main)" = "maint: update flake pins (lib) (#1)" ] || fail "the pin commit should be merged on the hub"
[ "$(hub_one)" != "$pinned" ] || fail "test setup: a squash merge makes a new commit"
[ "$(head_rev "$gh2/ws2/projects/one")" = "$(hub_one)" ] || fail "the local main should move onto the merged commit"
[ -z "$(git --git-dir="$gh2/hub/one.git" for-each-ref refs/heads/flake-sync)" ] || fail "the pull request branch should be deleted"
echo "ok: a pin commit is merged through a pull request, and the local main follows the merge"
echo feature >"$gh2/ws2/projects/one/feature.txt"
git -C "$gh2/ws2/projects/one" add feature.txt
git -C "$gh2/ws2/projects/one" commit -qm "feat: not a pin update"
rc=0; out=$(cd "$gh2/ws2" && "$FS" step push one 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a main ahead with a non-pin commit should not be pushed through an immediate merge"
expect_contains "$out" "commits on main that are not flake-sync pin updates" "the refusal names the non-pin commit"
git -C "$gh2/ws2/projects/one" reset -q --hard origin/main
pin_commit app
rc=0; out=$(cd "$gh2/ws2" && FAKE_GH_BLOCK=1 "$FS" step push one 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a blocked merge should stop the push"
expect_contains "$out" "auto-merge is on" "a merge blocked by checks turns on auto-merge"
grep -q -- "--squash --auto" "$gh2/fake/log" || fail "auto-merge should be requested"
[ "$(head_rev "$gh2/ws2/projects/one")" = "$(hub_one)" ] || fail "the local main should be reset to the remote main"
echo "ok: a blocked merge waits on auto-merge and leaves no local pin commit"
pin_commit trusted
out=$(cd "$gh2/ws2" && FAKE_GH_BLOCK=1 "$FS" --trust-local-checks step push one 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "--trust-local-checks should merge past the blocked checks"; }
grep -q -- "--squash --admin" "$gh2/fake/log" || fail "--trust-local-checks should merge with --admin"
[ "$(git --git-dir="$gh2/hub/one.git" log -1 --format=%s main)" = "maint: update flake pins (trusted) (#1)" ] || fail "the trusted pin commit should be merged"
echo "ok: --trust-local-checks runs the checks here and merges without waiting for CI"
pin_commit machines
: >"$gh2/fake/log"
(cd "$gh2/ws2" && GITHUB_ACTIONS=true "$FS" step push one) >/dev/null 2>&1 || fail "CI should push directly"
[ "$(hub_one)" = "$(head_rev "$gh2/ws2/projects/one")" ] || fail "CI should push the pin commit to main as it is"
[ ! -s "$gh2/fake/log" ] || fail "CI should not call gh"
echo "ok: CI pushes pin commits directly"
git config --global --unset "url.file://$gh2/hub/.insteadOf"
unset FLAKE_SYNC_GH

echo "=== 26. pr opens a draft until the change can merge, then takes it out of draft"
g3=$(mktemp -d)
mkdir -p "$g3/hub" "$g3/fake"
git config --global "url.file://$g3/hub/.insteadOf" "git@github.com:t3/"
for r in one two ws3; do git init -q --bare "$g3/hub/$r.git"; done
git clone -q "$g3/hub/one.git" "$g3/one-src"
echo '{ outputs = _: { }; }' >"$g3/one-src/flake.nix"
git -C "$g3/one-src" add flake.nix
git -C "$g3/one-src" commit -qm "init one"
git -C "$g3/one-src" push -q origin main
lock_on() { # a flake.lock that pins one at rev $1
  jq -n --arg rev "$1" '{nodes: {one: {locked: {type: "github", owner: "t3", repo: "one", rev: $rev}}, root: {inputs: {one: "one"}}}, root: "root", version: 7}'
}
git clone -q "$g3/hub/two.git" "$g3/two-src"
echo '{ inputs.one.url = "github:t3/one"; outputs = _: { }; }' >"$g3/two-src/flake.nix"
lock_on "$(git --git-dir="$g3/hub/one.git" rev-parse main)" >"$g3/two-src/flake.lock"
git -C "$g3/two-src" add flake.nix flake.lock
git -C "$g3/two-src" commit -qm "init two"
git -C "$g3/two-src" push -q origin main
git init -q "$g3/ws3"
git -C "$g3/ws3" remote add origin git@github.com:t3/ws3.git
git -C "$g3/ws3" submodule -q add git@github.com:t3/one.git projects/one
git -C "$g3/ws3" submodule -q add git@github.com:t3/two.git projects/two
git -C "$g3/ws3" commit -qm "init ws3"
git -C "$g3/ws3" push -q -u origin main
for r in one two; do
  git -C "$g3/ws3/projects/$r" checkout -q -b change
  echo change >"$g3/ws3/projects/$r/change.txt"
  git -C "$g3/ws3/projects/$r" add change.txt
  git -C "$g3/ws3/projects/$r" commit -qm "feat: change $r"
done
# A stand-in for gh that keeps each pull request's state in a file.
cat >"$g3/fake/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_DIR/log"
repo="" head="" draft=no url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -R) repo=${args[i+1]#t3/} ;;
    --head) head=${args[i+1]} ;;
    --draft) draft=yes ;;
    https://*) url=${args[i]} ;;
  esac
done
state() { echo "$FAKE_GH_DIR/pr-${1##*/pull/}"; }
case "$1 $2" in
  "pr list") f=$FAKE_GH_DIR/by-head-$repo-$head; [ -f "$f" ] && cat "$(state "$(cat "$f")")" ;;
  "pr create")
    url=https://github.com/t3/$repo/pull/$repo
    echo "$url $([ $draft = yes ] && echo DRAFT || echo OPEN)" >"$(state "$url")"
    echo "$url" >"$FAKE_GH_DIR/by-head-$repo-$head"
    echo "$url" ;;
  "pr ready")
    case " $* " in *" --undo "*) s=DRAFT ;; *) s=OPEN ;; esac
    echo "$url $s" >"$(state "$url")" ;;
esac
FAKE
chmod +x "$g3/fake/gh"
export FLAKE_SYNC_GH=$g3/fake/gh FAKE_GH_DIR=$g3/fake
echo "the body" >"$g3/body"
pr_state() { cat "$g3/fake/pr-$1" | cut -d' ' -f2; }
out=$(cd "$g3/ws3" && "$FS" --fetch pr two --title="Change two" --body-file="$g3/body" 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "pr two"; }
[ "$(pr_state two)" = DRAFT ] || fail "two waits on one, so its pull request is a draft"
grep -q -- "status: dependencies not ready (waiting on one to merge)" "$g3/fake/log" || fail "the body should say why it is a draft"
out=$(cd "$g3/ws3" && "$FS" --fetch pr one --title="Change one" --body-file="$g3/body" 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "pr one"; }
[ "$(pr_state one)" = OPEN ] || fail "one depends on nothing listed, so its pull request is ready"
echo "ok: the dependency opens for review and the consumer as a draft"
# one merges.
git --git-dir="$g3/hub/one.git" update-ref refs/heads/main "$(git --git-dir="$g3/hub/one.git" rev-parse change)"
(cd "$g3/ws3" && "$FS" --fetch pr two --title="Change two" --body-file="$g3/body") >/dev/null 2>&1 || fail "pr two after one merged"
[ "$(pr_state two)" = DRAFT ] || fail "two stays a draft until its main pins the merged one"
grep -q -- "status: waiting for convergence" "$g3/fake/log" || fail "the status should say it waits for convergence"
# Convergence: two's main pins the merged one.
git -C "$g3/two-src" pull -q
lock_on "$(git --git-dir="$g3/hub/one.git" rev-parse main)" >"$g3/two-src/flake.lock"
git -C "$g3/two-src" commit -qam "maint: update flake pins (one)"
git -C "$g3/two-src" push -q origin main
(cd "$g3/ws3" && "$FS" --fetch pr two --title="Change two" --body-file="$g3/body") >/dev/null 2>&1 || fail "pr two after convergence"
[ "$(pr_state two)" = DRAFT ] || fail "two stays a draft until it is rebased onto the converged main"
grep -q -- "status: needs a rebase onto main" "$g3/fake/log" || fail "the status should ask for a rebase"
(cd "$g3/ws3" && "$FS" rebase two) >/dev/null 2>&1 || fail "flake-sync rebase two"
(cd "$g3/ws3" && "$FS" --fetch pr two --title="Change two" --body-file="$g3/body") >/dev/null 2>&1 || fail "pr two after the rebase"
[ "$(pr_state two)" = OPEN ] || fail "two should leave draft once rebased onto the converged main"
echo "ok: the consumer leaves draft once its dependency merged, its main converged, and it is rebased"
git config --global --unset "url.file://$g3/hub/.insteadOf"
unset FLAKE_SYNC_GH

echo "=== 27. rebase resolves a flake.lock conflict from the default branch, keeping the inputs the branch adds"
$FS --heads pull >/dev/null 2>&1 || fail "test setup: pull --heads"
$FS --fetch converge >/dev/null 2>&1 || fail "test setup: converge"
# The branch also locks lib at an intermediate pushed commit, so its lock
# and main's lock both change the lib node and the rebase conflicts.
echo intermediate >projects/lib/intermediate.txt
git -C projects/lib add intermediate.txt
git -C projects/lib commit -qm "feat: lib at an intermediate commit"
git -C projects/lib push -q origin main
git -C projects/app checkout -q -b add-input
sed -i "1a\\  inputs.extra.url = \"git+file://$HUB/extdep.git\";" projects/app/flake.nix
nix flake lock "$PWD/projects/app" >/dev/null 2>"$WORK/../extra-lock.err" || { cat "$WORK/../extra-lock.err" >&2; fail "test setup: locking the extra input"; }
nix flake update lib --flake "$PWD/projects/app" >/dev/null 2>"$WORK/../extra-lock.err" || { cat "$WORK/../extra-lock.err" >&2; fail "test setup: moving lib on the branch"; }
git -C projects/app commit -qam "feat: add the extra input"
git -C projects/app checkout -q main
# Meanwhile lib moves and convergence re-pins app's main.
echo rebase >projects/lib/rebase.txt
git -C projects/lib add rebase.txt
git -C projects/lib commit -qm "feat: lib moves before the rebase"
$FS --fetch converge >/dev/null 2>&1 || fail "converge should re-pin app's main"
git -C projects/app checkout -q add-input
out=$($FS --fetch rebase app 2>&1) || { printf 'output was:\n%s\n' "$out" >&2; fail "rebase app"; }
expect_contains "$out" "resolved flake.lock in app" "rebase resolves the lock conflict"
[ ! -d "$(git -C projects/app rev-parse --git-path rebase-merge)" ] || fail "the rebase should be finished"
git -C projects/app merge-base --is-ancestor origin/main HEAD || fail "the branch should sit on the converged main"
[ "$(lock_rev projects/app lib)" = "$(hub_rev lib)" ] || fail "the lock should keep main's lib pin"
[ "$(jq -r '.nodes.root.inputs.extra // empty' projects/app/flake.lock)" != "" ] || fail "the lock should keep the input the branch adds"
echo "ok: rebase keeps the default branch's pins and the branch's new input"
git -C projects/app checkout -q main
git -C projects/app branch -q -D add-input

echo "=== 28. a submodule that is not a flake, absent and pinned by an absent repo, counts as external"
git init -q --bare "$HUB/src.git"
src_clone=$(mktemp -d)/src
git clone -q "file://$HUB/src.git" "$src_clone"
echo source >"$src_clone/README"
git -C "$src_clone" add README
git -C "$src_clone" commit -qm "init src"
git -C "$src_clone" push -q origin main
git submodule -q add "file://$HUB/src.git" projects/src
git commit -qm "feat: add the src submodule"
sed -i "1a\\  inputs.src = { url = \"git+file://$HUB/src.git\"; flake = false; };" projects/app/flake.nix
nix flake lock "$PWD/projects/app" >/dev/null 2>"$WORK/../src-lock.err" || { cat "$WORK/../src-lock.err" >&2; fail "test setup: locking src"; }
git -C projects/app commit -qam "feat: use src"
out=$($FS converge 2>&1) || { printf "output was:\n%s\n" "$out" >&2; fail "test setup: converge with src"; }
git submodule -q deinit -f projects/src projects/app
rc=0; out=$($FS --fetch status 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { printf 'output was:\n%s\n' "$out" >&2; fail "status with the absent non-flake src pinned by the absent app"; }
case $out in *"src "*) fail "src is not a flake and should not be listed: $out" ;; esac
echo "ok: an absent non-flake pinned by an absent repo is dropped before any lock is read"
git submodule -q update --init projects/app projects/src

echo "ALL SCENARIOS PASSED"
