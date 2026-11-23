---
name: flake-sync-pull-requests
description: Publish changes in a flake-sync workspace as pull requests in dependency order, for changes where one repo needs another repo's change. Use when opening or updating a pull request for a workspace repo, when finding which pull requests can leave draft, or when a topic branch must move onto a default branch that changed after a dependency merged.
---

`reference.md` beside this file is the flake-sync reference;
§ Changes that span repos: pull requests holds the details. The
workspace's instructions (its CLAUDE.md or contributing docs) decide
whether a change may be published and who merges it; this skill covers
what the commands do.

What flake-sync enforces:

- `step push <repo>` and `pr <repo>` refuse while a repo the branch
  depends on has unpushed commits, so branches reach the remote in
  dependency order.
- `pr` keeps a pull request a draft until the repo's default branch pins
  each workspace dependency at that dependency's remote head and the
  branch contains the default branch.
- Topic branches in a linked worktree get no pin commits; locks move by
  convergence on the default branches.

The commands:

- `flake-sync --fetch unmerged-commits` (`--json` for scripts) lists the
  repos whose branch has commits not on the remote default branch, in
  dependency order, with their commits, the listed repos each depends on,
  its pull request, and a state: `ready`, `dependencies not ready` (a
  repo it depends on is listed), or `waiting for convergence` (its
  default branch does not pin the merged dependency yet).
- `flake-sync pr <repo> --title=<title> --body-file=<file>` pushes the
  branch and opens or updates its pull request, a draft with a
  `status:` line until it is ready. It refuses a pull request that is
  already merged.
- `flake-sync rebase <repo>` rebases the topic branch onto the remote
  default branch, resolving `flake.lock` conflicts from the default
  branch and locking the inputs the branch adds.

For a change A that a change B in another repo needs, the listed order
opens A first and B as a draft; after A merges and B's repo converges,
`rebase` and a second `pr` take B out of draft. `pr` needs a GitHub
remote and `gh` authenticated.
