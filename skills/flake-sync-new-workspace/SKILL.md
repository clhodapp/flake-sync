---
name: flake-sync-new-workspace
description: Set up a new flake-sync workspace, or bring an existing set of flake repos under flake-sync, and settle its policy with the workspace's owner. Use when creating a workspace repo whose submodules are flakes that pin each other, when adding flake-sync to such a repo for the first time, or when the workspace's rules for convergence, pull requests and pin scope are not written down yet.
---

# Establishing a flake-sync workspace

Setting up a workspace means getting the structure flake-sync reads
right, which is mechanical, and settling the policy for how changes and
pins move, which belongs to the workspace's owner. Settle the policy with the owner
rather than choosing it, and write the answers into the workspace's
instructions for agents and contributors, where the other flake-sync
skills look for them. `reference.md` beside this file is the full
flake-sync reference.

## The structure flake-sync reads

- **A workspace repo with a `.gitmodules`.** Each submodule whose
  checkout holds a `flake.nix` is a workspace repo; others are ignored,
  and pins onto them count as external inputs. flake-sync finds the
  workspace from the current directory, walking up to the outermost repo
  that tracks the current one as a submodule (§ Workspace discovery).
- **Inputs that name sibling repos by their remote.** A pin is recognized
  by matching an input's locked source against the submodule URLs in
  `.gitmodules`: `github:owner/repo` matches a GitHub URL of that repo in
  SSH or HTTPS form, and `git+…` inputs match by URL. An input that
  reaches a sibling through another URL, a fork, or a `path:` reference
  is not seen as a pin. `follows` aliases are not pins either.
- **No dependency cycles.** flake-sync orders repos topologically and
  rejects a cycle, which has no order to converge in. Partition locks
  (`--with-partitions`) can add edges, and so cycles, that the root
  locks do not have.
- **A known default branch for each remote.** flake-sync reads it from
  `refs/remotes/origin/HEAD`, which a clone sets; for a repo added some
  other way, `git remote set-head origin --auto` sets it.
- **The workspace repo can be a flake too.** If it is, the pins in its
  lock are converged like those of any other repo, and its submodule
  pointers are bumped last.

flake-sync may already be available: `command -v flake-sync` shows
whether it is on the PATH, and the workspace's development shell or the
machine's configuration may supply it. Only if nothing does, ask the
owner how the workspace should provide it,
for example as an input of its development shell, so contributors and
CI run the same version. Until then,
`nix run github:clhodapp/flake-sync -- <command>` runs it without
installing anything.

## Policy questions to settle with the owner

Ask these, explain the consequences below, and record the answers.

1. **Who publishes convergence?** CI, by running `flake-sync --fetch
   converge` after pushes to default branches (it needs credentials that
   can push to the workspace's repos), or people and agents running `converge` from
   a primary checkout, or both, with CI as the routine path. Where CI
   publishes, local runs usually stop at `converge --local`.
2. **How do pin commits reach default branches outside CI?** flake-sync
   merges them through an immediate pull request on GitHub remotes.
   Branch protection decides whether that works: required checks or
   reviews make it wait (flake-sync then turns on auto-merge, which the
   repo must allow), and `--trust-local-checks` merges with an admin
   override after running the checks locally. Decide whether that
   override is acceptable, and with which `--check` depth.
3. **How do changes land?** Pull requests reviewed and merged on the
   forge, direct pushes to default branches by people allowed to, or a
   mix. This decides whether agents ever push a default branch, and
   which merge methods the repos allow.
4. **Which pins does routine convergence move?** Root locks only, or
   partition locks too (`--with-partitions`). External inputs such as
   nixpkgs (`--with-external`) change what the workspace builds against;
   decide whether they move on a schedule, only on request, or never
   through flake-sync.
5. **How deep is the check gate?** `--check=eval` (the default) catches
   evaluation errors; `--check=full` also builds each flake's checks,
   which is slower and needs the builders; `--check=none` skips it.
6. **Where do agents work?** In the primary checkout, or in linked
   worktrees with `flake-sync checkout` (§ Agent worktrees). In
   worktrees, flake-sync makes pin moves on the default branches, not on
   topic branches; the instructions should say whether agents open pull requests, push
   topic branches only, or stop at local commits.
7. **Who may change a lock, and how?** With pin requests (§ Pin
   requests), anyone asks for a move in an issue and CI makes it,
   skipping the check for requests signed by a key in the
   allowed-signers file; pull requests then change no lock. The
   verify-locks workflow (§ Verifying lock changes) instead checks the
   lock changes that pull requests carry. Either needs a caller
   workflow in each repo and a GitHub App.

## Checking the result

- `flake-sync --fetch status` lists the repos with their pins; a sibling
  that shows no pins where one is expected usually has an input that
  names it by another URL.
- `flake-sync graph` prints the dependency order.
- `flake-sync check` runs the check gate over the repos as they stand.
- `flake-sync --fetch converge --local` shows whether the workspace
  converges from here, without publishing anything.
