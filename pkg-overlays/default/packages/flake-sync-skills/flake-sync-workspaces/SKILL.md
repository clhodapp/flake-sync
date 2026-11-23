---
name: flake-sync-workspaces
description: Understand and work in a git workspace whose submodules are flakes that pin each other, managed with the flake-sync tool. Use when starting work in such a workspace, in its primary checkout or a linked worktree; when a submodule is missing or on a detached HEAD; when a change has to build against another repo's change that is not pushed or not pinned yet; or when reading flake-sync status output.
---

# Working in a flake-sync workspace

The workspace's instructions (its CLAUDE.md or contributing docs) say
when to push, land, and converge. This skill explains how the workspace
fits together, so the commands make sense. `reference.md` beside this
file is the full flake-sync reference.

## How the workspace fits together

A flake-sync workspace is a git repo whose submodules are flake repos.
Two kinds of reference tie them together, and keeping both current is
called convergence:

- **Pins.** Each repo's `flake.lock` locks its sibling repos at exact
  commits. A change to a repo reaches its consumers only once each
  consumer's lock is updated to a commit that contains it.
- **Pointers.** The workspace repo records a commit for each submodule
  (a gitlink). `git submodule update` checks those commits out, on a
  detached HEAD.

flake-sync only pins commits that are **pushed** (reachable from a
remote ref), because a lock that names an unpushed commit cannot be
fetched by anyone else. That rule is what forces the order: push the
dependency, re-pin and push each consumer, and bump the workspace
pointers last. Consumers of consumers follow the same way, down the
dependency graph (`flake-sync graph` prints it).

A change in one repo therefore moves through three stages before every
consumer uses it: on a branch, on the repo's default branch, and pinned
by each consumer's default branch. The pull-request and convergence
skills cover the last two.

## Orienting

`flake-sync --fetch status` prints one row per repo: the branch, the git
state (`clean+pushed`, `dirty`, `lock-dirty`, `ahead N`, `behind N`,
`not checked out`), and each pin onto a sibling as `name=ok` or
`name=stale`. Under it, **Pending** lists the actions flake-sync would
take, each `ready` or `blocked` with the reason; the flake-sync-converge
skill explains the blockers. Without `--fetch` it compares against the
remote-tracking refs as last fetched.

A checkout can hold only some submodules. flake-sync reads the others
from their remotes, so `status` and `graph` still cover the whole
workspace, and lists them as `not checked out`.

## Getting the repos a task needs

`flake-sync checkout <repo>...` adds submodules to the checkout. In a
linked worktree of the workspace (`git worktree add`, as agent sessions
use), each submodule becomes a linked worktree of the repo the primary
checkout already keeps for it, so nothing is cloned again and fetches
are shared. Each lands on a topic branch named after the worktree's
branch, started from the remote default branch. A plain `git submodule
update --init` in a worktree instead clones a separate copy and leaves
it on a detached HEAD, where commits are easy to strand.

In the primary checkout, `flake-sync pull` brings everything to the
published state: it fast-forwards the workspace and puts each submodule
on its default branch at the recorded pointer. `pull --heads` goes to
the remote tips, which are ahead of the pointers until convergence
catches up.

## Building against a change that is not pinned yet

A consumer's lock pins what its default branch pins, so building it
against a sibling's new commit needs an override for that build, not an
edit to the lock. `flake-sync --local override-inputs <flake-ref>`
prints the flake reference followed by `--override-input` flags that
move each workspace input to the HEAD of the submodule checked out
here, unpushed commits included:

    nix build $(flake-sync --local override-inputs ./<consumer>#<attr>)

Without `--local`, the inputs move to the remote heads instead, which
builds what convergence will pin. The command writes nothing. Nix locks
inputs by commit, so uncommitted changes are left out, with a warning:
commit them first.

## What not to do by hand

- Do not edit `flake.lock` or a submodule pointer to move a pin;
  convergence does it, through the check gate.
- Do not commit a lock that points at another repo's unpushed or unmerged
  commit. In a linked worktree flake-sync refuses to make pin commits on
  topic branches at all.
