---
name: flake-sync-worktrees
description: Diagnose and fix problems with git worktrees in a workspace whose submodules are flake repos, as agent sessions use them. Use when a worktree is missing its submodules, has a submodule on a detached HEAD or a separate clone, refuses a branch, shows submodules as modified, will not be removed, when a flake built in a worktree ignores new or changed files, when flake-sync refuses a command in a worktree, or when git, nix or a push fails in a worktree under a sandbox because a path is read-only, a connection is refused, or a tool is missing.
---

# Troubleshooting worktrees in a flake-sync workspace

A workspace worktree is a linked worktree of the workspace repo, made
with `git worktree add` from the workspace's primary checkout. Its
submodules are separate repos, and most trouble comes from that. Find the
symptom below. `reference.md` beside this file is the flake-sync
reference (§ Agent worktrees, § A checkout with only some submodules).

## How the pieces relate

- The workspace's primary checkout keeps one repo per submodule in its
  common git dir, `.git/modules/<submodule name>`. A worktree shares
  that git dir.
- `flake-sync checkout <repo>` makes the submodule in a worktree a linked
  worktree of that shared repo: its `.git` file points into
  `.git/modules/<name>/worktrees/<id>`, and it shares objects, refs and
  fetches with the primary checkout.
- A plain `git submodule update --init` in a worktree does something
  else: it clones a separate copy into the worktree's private git dir and
  checks out the recorded commit on a detached HEAD.
- Git checks a branch out in at most one worktree at a time, the
  workspace repo's and each submodule repo's branches alike.

## Symptoms

**The worktree has the workspace files but empty submodule directories.**
A new worktree checks out no submodules. Run `flake-sync checkout
<repo>...` for the ones the task needs. The rest stay out, and flake-sync
reads them from their remotes.

**The worktree is a worktree of a submodule, not of the workspace.**
`git worktree add` ran with a submodule as the current directory, so it
made a worktree of that submodule repo: no workspace around it, no
siblings, and flake-sync finds no workspace there. Make the worktree
from the workspace's primary checkout instead, and remove the wrong one
with `git -C <submodule> worktree remove <path>`.

**A submodule in the worktree is on a detached HEAD.**
It was set up with `git submodule update`. Commits made there belong to
no branch: before anything else, run `git -C <submodule> branch <topic>`
to keep them. To get the shared setup, move the work onto a branch, push
or note it, remove the submodule's directory contents, and run
`flake-sync checkout <repo>`, which attaches the branch named after the
workspace worktree's branch.

**`fatal: '<branch>' is already used by worktree at '<path>'`.**
That branch is checked out in another worktree, usually the default
branch in the primary checkout. Work on a topic branch. `flake-sync
checkout` creates one named after the workspace worktree's branch; if the
workspace worktree is on a detached HEAD, flake-sync refuses until it is
on a branch.

**`git status` in the worktree lists submodules as modified (`M
projects/<name>`).**
The submodule's HEAD differs from the commit the workspace records, which
is normal while working, or after `flake-sync checkout` starts a topic
branch at the remote tip. It is no change to commit by hand: flake-sync
bumps workspace pointers when it converges. Stage only the files you
changed.

**`git worktree remove` refuses: `working trees containing submodules
cannot be moved or removed`.**
Check that nothing in the worktree is unpushed first:
`flake-sync --fetch status` shows `ahead N` per repo, and
`flake-sync --fetch unmerged-commits` lists branches with unmerged work.
Then `git worktree remove --force <path>` from the primary checkout, and
`git -C .git/modules/<name> worktree prune` for each shared submodule
repo, so their stale registrations go too (`flake-sync checkout` prunes
them as well).

**A worktree directory was moved or deleted by hand, and git still lists
it, or a submodule there says `not a git repository`.**
`git worktree prune` drops registrations whose directory is gone;
`git worktree repair <new path>` fixes the links of a moved worktree,
in the workspace repo and in each shared submodule repo.

**A flake built in the worktree ignores a new file or a change.**
Nix reads a flake in a git repo from git: untracked files are invisible
until `git add`, and a `git+file` input sees only committed changes. To
build a consumer against a sibling's work, commit it and use
`nix build $(flake-sync --local override-inputs ./<consumer>#<attr>)`.

**flake-sync refuses `converge`, `step update-pins` or a bare `step` in
the worktree.**
A worktree holds topic branches, and flake-sync makes no pin commits on
them; pins move by convergence on the default branches.
`converge --local` checks convergence without publishing, and
`step push <repo>` pushes a topic branch once the repos it depends on
are pushed.

**`flake-sync status` or `converge --local` lists repos as `not checked
out`, or blocks on one.**
The worktree holds only some submodules; flake-sync reads the others
from their remotes. A blocker on such a repo means the pins in its lock
need moving: `--checkout-missing` lets `converge --local` add it.

## Worktrees inside a sandbox

Agent sessions often run commands in a sandbox that allows writes only
to the session's directories and network access only to listed hosts.
A worktree sits badly with that, because its git data is not inside it:
a linked worktree's `.git` is a file pointing at `.git/worktrees/<name>`
in the primary checkout, and a submodule checked out by `flake-sync
checkout` points into `.git/modules/<name>`. Git writes there for
ordinary operations (the index, refs, objects, `index.lock`).

When an operation fails under a sandbox, find the path or host it needed
and report it: the sandbox's grants are its owner's decision, and a
workaround that skips a check or a hook needs that owner's approval too.

| Symptom | Cause | Grant that fixes it |
|---|---|---|
| `Unable to create '<…>/index.lock': Read-only file system`, or a ref update failing the same way | The worktree's git dir, `.git/worktrees/<name>`, is outside the writable paths. | Write access to that worktree's git dir. |
| Commits, fetches or `flake-sync checkout` in a submodule fail with `Read-only file system` under `.git/modules/<name>` | The shared submodule repo is not writable. | Write access to `.git/modules/<name>`. |
| Git refuses to touch a worktree of another session | Its entry under `.git/worktrees/` is read-only to this session. | Usually intended; work in the worktree of this session. |
| A worktree made with the submodule as current directory fails on every write | Its git dir is `.git/modules/<name>/worktrees/<id>`, which the sandbox treats as belonging to another session. | Make the worktree from the workspace's primary checkout instead. |
| `fetch` or `push` fails to connect, or an SSH remote reports `No user exists for uid` | The forge host is not allowed, or the sandbox gives SSH no user identity. | Network access to the forge; an identity for SSH inside the sandbox, or an HTTPS remote with a credential helper. |
| A push fails in a hook, such as `git-lfs` not found by a `pre-push` hook | The hook needs a tool the sandbox does not provide. | That tool on the sandbox's PATH. |
| A script fails with `command not found` for a basic tool | The sandbox provides only the tools it declares. | That tool among the sandbox's declared tools. |
| `nix build` cannot reach the daemon, or a `path:` flake input fails to read a worktree | The Nix daemon socket, or the `.git` of the primary checkout that the worktree points to, is outside the readable paths. | Access to the daemon socket; read access to the `.git` of the primary checkout. |
