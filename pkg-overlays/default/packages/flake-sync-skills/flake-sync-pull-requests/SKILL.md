---
name: flake-sync-pull-requests
description: Publish changes in a flake-sync workspace as pull requests, especially a change in one repo that needs a change in another. Use when opening or updating a pull request for a workspace repo, when working out which pull requests can be reviewed now and which must wait, or when a topic branch must move onto a default branch that changed after a dependency merged.
---

# Pull requests across workspace repos

The workspace's instructions say whether a change may be published and
who merges it. This skill explains how pull requests and pins interact
in a flake-sync workspace. `reference.md` beside this file has the
details (§ Changes that span repos: pull requests).

## Why order matters

A pull request in a consumer repo is checked against what its target
branch pins. If the consumer's change needs a dependency's change that
is not merged yet, the consumer's pull request cannot pass as it stands,
and pinning the dependency's topic branch inside it would publish a lock
onto an unmerged commit. So a dependent change waits:

1. The dependency's change merges into the dependency's default branch.
2. Convergence moves the consumer repo's default branch onto it, with a
   separate pin commit.
3. The consumer's topic branch is rebased onto that default branch, and
   only then can its pull request be reviewed.

Until then the consumer's pull request is a draft. Its branch carries no
lock change; the lock moves through convergence on the default branch.

## Reading unmerged-commits

`flake-sync --fetch unmerged-commits` lists the repos whose branch has
commits that are not on the remote default branch, other than pin
updates, in dependency order. That order is the order to open the pull
requests and to merge them. Each repo gets a state:

| State | Meaning | Next |
|---|---|---|
| `ready` | Its default branch pins every workspace dependency at that dependency's remote head. | Open or update the pull request; it can be reviewed once the branch contains the default branch. |
| `dependencies not ready` | A repo it depends on is also listed: that change is not merged. | Open it as a draft, or wait; work on the dependency's pull request first. |
| `waiting for convergence` | The dependency merged, but the default branch of this repo does not pin the merged commit yet. | Wait for convergence (or run it, if the workspace's instructions allow), then rerun `--fetch unmerged-commits`. |

`--json` prints the same data, with the commits of each repo, which is
what a pull request's title and body are written from.

## Opening and updating

`flake-sync pr <repo> --title=<title> --body-file=<file>` pushes the
branch and opens or updates the pull request. It decides draft or not
from the state above: a repo that is not `ready`, or whose branch does
not contain the remote default branch, gets a draft whose body starts
with a `status:` line saying why. Running `pr` again after the state
changes updates the body and takes the pull request out of draft, or
back into it.

It refuses in these cases:

- **A dependency has unpushed commits** (`depends on <repo>, which has
  unpushed commits`). Push that repo's branch first, which the same
  rule allows once the repos it depends on are pushed.
- **The branch's pull request is already merged.** A merged pull request
  takes no new commits; start a new branch from the default branch.
- **The repo is on its default branch, not a topic branch.**

## After a dependency merges

When the state turns `ready` but `pr` still keeps a draft with
`needs a rebase`, run `flake-sync rebase <repo>`. It rebases the topic
branch onto the remote default branch. A `flake.lock` conflict there
means the branch changed inputs too; flake-sync takes the default
branch's lock, which holds the converged pins, and runs `nix flake lock`
to add the inputs the branch's `flake.nix` adds. A conflict in any other
file stops for resolution by hand (`git rebase --continue`, then rerun).
The rebased branch is pushed with a lease, so it only replaces the
remote branch when the old remote tip is part of the local history.

`pr` needs a GitHub remote and an authenticated `gh`.
