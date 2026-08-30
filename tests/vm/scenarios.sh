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

echo "=== 5. dirty consumer blocks its own re-pin; the rest proceeds"
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
  || fail "local mode should advance the workspace's own lock"
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
# the flake's own source path makes the inner derivation unique per
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
# not even initialized.
git reset -q --hard "$old_ws"
git -C projects/lib reset -q --hard "$old_lib"
git -C projects/app reset -q --hard "$old_app"
git -C projects/machines reset -q --hard "$old_machines"
git submodule -q update
git submodule -q deinit -f projects/machines >/dev/null
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
# A repo that is nobody's submodule is its own root (here one without
# submodules, so the .gitmodules requirement names that repo itself).
plain=$(mktemp -d)/plain
git clone -q "file://$HUB/lib.git" "$plain"
plain_root=$(git -C "$plain" rev-parse --show-toplevel)
rc=0; out=$(cd "$plain" && "$FS" status 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a repo without submodules should be rejected as its own root"
expect_contains "$out" "$plain_root has no .gitmodules" "a repo that is nobody's submodule is its own root"
# Outside any git repo, flake-sync fails with a clear message. The
# ceiling keeps git from walking above the scratch dir, so the scenario
# holds even when TMPDIR itself sits inside some checkout.
nowhere=$(cd "$(mktemp -d)" && pwd -P)
rc=0; out=$(cd "$nowhere" && GIT_CEILING_DIRECTORIES=$nowhere "$FS" status 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "flake-sync should fail outside any git repository"
expect_contains "$out" "not inside a git repository" "non-repo cwd fails with a clear message"
echo "ok: root discovery follows the cwd"

echo "ALL SCENARIOS PASSED"
