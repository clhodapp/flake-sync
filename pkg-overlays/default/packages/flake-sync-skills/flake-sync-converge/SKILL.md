---
name: flake-sync-converge
description: Converge a flake-sync workspace, advancing cross-repo flake pins and workspace submodule pointers in dependency order. Use when asked to update, sync, or converge the workspace or its pins, after a change reaches a repo's default branch, or to check whether the workspace will converge.
---

`reference.md` beside this file is the flake-sync reference; § Full
convergence, § Local convergence, and § Gotchas hold the details. The
workspace's instructions (its CLAUDE.md or contributing docs) decide when
publication runs, from where, and which pins move; this skill covers
what the commands do.

- `flake-sync --fetch converge --local` advances working-tree locks
  through the `nix flake check` gate and commits and pushes nothing.
  Exit 0 means every pin can advance; exit 1 names what held and why. It
  runs in any checkout; `--checkout-missing` lets it check out absent
  repos whose pins it has to advance.
- `flake-sync converge` commits and pushes in dependency order. Outside
  CI, a repo's pin commits reach its GitHub default branch through a pull
  request that holds only them, merged at once; when branch protection
  makes that merge wait, it turns on auto-merge and stops, and a rerun
  after the merge continues. `--trust-local-checks` runs the checks
  locally and merges without waiting. A default branch ahead with
  commits other than pin commits is refused.
- Scope flags: `--with-partitions` adds tracked `flake.lock` files below
  each repo root; `--with-external` adds inputs that are not workspace
  repos, such as nixpkgs; `--all` adds both and `--with-tests`. The
  workspace's instructions say which of these routine runs use.
- `flake-sync check` runs `nix flake check` over every repo against its
  current locks, read-only.

`converge` exiting 1 is a blocker report, not a crash: resolve what it
lists (commit or discard changes, pull or rebase, fix a failing check)
and rerun.
