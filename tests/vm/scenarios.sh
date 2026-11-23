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

echo "ALL SCENARIOS PASSED"
