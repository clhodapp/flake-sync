---
name: flake-sync-converge
description: Converge a flake-sync workspace, moving cross-repo flake pins and workspace submodule pointers onto the current default branches in dependency order, and resolve what blocks it. Use when asked to update, sync, or converge the workspace or its pins, after a change reaches a repo's default branch, to check whether the workspace will converge, or when flake-sync reports blockers or held pins.
---

# Converging a flake-sync workspace

The workspace's instructions say when convergence runs, from where, and
which pins it moves; many workspaces leave publication to CI. This skill
explains what convergence does and how to read and resolve its blockers.
`reference.md` beside this file has the details (§ Full convergence,
§ Local convergence, § Gotchas).

## What a converge does

For each repo in dependency order, flake-sync finds pins onto siblings
whose pushed head moved, and tries the new state through `nix flake
check` (evaluation only by default; `--check=full` also builds the
checks). The pins that pass are written to `flake.lock` and committed as
`maint: update flake pins (...)`; the repo is pushed so the repos that
depend on it can pin it; finally the workspace's submodule pointers are
committed as `maint: bump ...` and pushed. A pin that fails the check is
held back alone, and the rest still advance.

Two modes:

- **`converge --local`** writes the new locks into the working trees and
  stops: no commits, no pushes. Exit 0 means every pin can advance, which
  is the check that a real converge will succeed. It runs anywhere,
  including linked worktrees and dirty trees.
- **`converge`** commits and pushes. Outside CI, a repo's pin commits go
  to its GitHub default branch through a pull request holding only them,
  merged at once; if branch protection makes the merge wait, it turns on
  auto-merge and stops, and a rerun after the merge continues.
  `--trust-local-checks` runs the checks locally and merges without
  waiting for CI. In CI (`GITHUB_ACTIONS=true`) the commits are pushed
  directly.

Scope flags widen what counts as a pin: `--with-partitions` adds tracked
`flake.lock` files below each repo root, `--with-external` adds inputs
that are not workspace repos (nixpkgs, for one), and `--all` adds both
plus `--with-tests`. External pins change what everything builds
against, so the workspace's instructions usually reserve them.

## Reading blockers

`converge` exits 1 with a list of blockers; that is a report, not a
crash. `status` and `next` show the same list before anything runs.

| Blocker | Cause | Resolution |
|---|---|---|
| `stale pin(s) to unpushed target(s): X` | X has commits that are not pushed, so nothing may pin them. | Push X's branch; the pin can follow. |
| `holding X (fails nix flake check)`, `held back: fail nix flake check` | The consumer does not evaluate (or build) against X's new head. | Fix the consumer or X; the check output above the message names the error. |
| `stale pins (...) but repo has N uncommitted change(s)` | Pins cannot be committed over unrelated work. | Commit or discard that work. |
| `uncommitted changes in flake.lock that are not pin updates` | A lock differs from `HEAD` in ways flake-sync does not make, such as a hand-run `nix flake update`. | Commit or discard the lock change. |
| `HEAD is detached; check out a branch` | Commits there would belong to no branch. | Check out the default branch (`flake-sync pull` does it for every submodule). |
| `behind upstream by N; run 'flake-sync pull'` | The remote moved. | `flake-sync pull`, or `flake-sync rebase <repo>` for a topic branch. |
| `stale pins (...) but not checked out here` | The repo is absent from this checkout, and the pins in its lock need moving. | `--checkout-missing`, or `flake-sync checkout <repo>`, then rerun. |
| `commits on <branch> that are not flake-sync pin updates` | The default branch holds other work, which an immediate merge would publish unreviewed. | Move that work to a topic branch and publish it as a pull request. |
| `could not be merged now ... auto-merge is on` | Branch protection waits for checks or reviews. | Rerun after it merges, or use `--trust-local-checks` where allowed. |
| `moved on the remote while converging` | Someone pushed mid-run. | Rerun; the pins are recomputed on the new tip. |

## Related commands

- `flake-sync check` runs `nix flake check` over every repo against its
  current locks, without moving anything: where the workspace stands.
- `flake-sync step` runs one ready action; `step <action> <repo>` runs
  one specific action (`update-pins`, `push`, `bump-submodules`).
