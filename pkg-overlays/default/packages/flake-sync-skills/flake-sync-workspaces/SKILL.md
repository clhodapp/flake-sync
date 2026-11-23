---
name: flake-sync-workspaces
description: Work in a git workspace whose submodules are flakes that pin each other, using the flake-sync tool. Use when starting work in such a workspace, in its primary checkout or a linked worktree; when a submodule is not checked out or sits on a detached HEAD; when a change must build against another repo's unpushed change; or when a checkout is behind its remotes.
---

`reference.md` beside this file is the flake-sync reference; the
sections named below hold the details. The workspace's instructions (its
CLAUDE.md or contributing docs) decide when to push, land, or converge;
this skill covers what the commands do.

flake-sync finds the workspace from the current directory, so it acts on
the checkout it runs in: the primary checkout, or a linked worktree of
the workspace repo.

- `flake-sync --fetch status` shows each repo's git and pin state and the
  pending actions; `flake-sync graph` shows the dependency order
  (§ Assess current state).
- `flake-sync checkout <repo>...` adds submodules to a checkout that
  holds only some; the others are read from their remotes. In a linked
  worktree it adds each as a linked worktree of the repo the primary
  checkout keeps for that submodule, on a topic branch named after the
  worktree's branch, so nothing is cloned twice and nothing is left on a
  detached HEAD (§ A checkout with only some submodules, § Agent
  worktrees). A plain `git submodule update --init` in a worktree clones
  a separate copy on a detached HEAD instead.
- `flake-sync --local override-inputs <flake-ref>` prints the reference
  plus `--override-input` flags that move workspace inputs to the HEADs
  of the submodules checked out here, unpushed commits included, for use
  as `nix build $(flake-sync --local override-inputs <flake-ref>)`. It
  writes no lock (§ Use pushed changes before they are re-pinned).
- `flake-sync pull` fast-forwards the workspace and re-attaches each
  submodule to its default branch at the recorded pointer;
  `pull --heads` goes to the remote tips instead (§ Down-sync: pull).

In a linked worktree, flake-sync makes no pin moves on topic branches: a
publishing `converge`, `step update-pins`, and `step` with no action
refuse there. The flake-sync-pull-requests skill covers publishing
changes; the flake-sync-converge skill covers converging pins.
