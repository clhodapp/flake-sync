# flake-sync: DAG-ordered flake pin updates and pushes

flake-sync operates on a *workspace*: a git repo whose submodules are
flakes that pin each other via `github:` (or `git+file:`/`git+ssh:`)
inputs in their `flake.lock`s, while the workspace repo tracks each of
them as a submodule. It discovers the submodules that are flakes, plus
the workspace repo itself, and detects cross-repo pins by matching each
`flake.lock`'s root-level inputs against submodule remote URLs. Nothing
is hardcoded, and new submodules are picked up automatically. Root-level
inputs that resolve to a real locked node (not a `follows` alias) but
don't match any sibling are "external" inputs, manageable with
`--with-external` (below).

The workspace is converged when the repos pin each other at their
current local heads, they are pushed, and the workspace's submodule
pointers match the submodule heads. Pins only advance to *pushed* revs, which is what forces
the dependency ordering: a dependency is pushed, then each consumer is
re-pinned and pushed, and so on down the graph, until the workspace
pointers are bumped and pushed. By default a pin advance is first validated
with an evaluation-only `nix flake check` of the proposed state
(`--check=eval`); `--check=full` additionally builds the flake's checks,
`--check=none` skips validation.

## Workspace discovery

The workspace root is found from the current directory, not from the
location of the executable: flake-sync takes the enclosing git repo and
walks up as long as the current repo is registered as a submodule of an
enclosing one, ending at the parent-most superproject. A repo that is
not a submodule of another repo is a workspace root by itself (it still needs a
`.gitmodules`, or there is nothing to converge). Running outside any git
repo is an error. In particular, running from inside any submodule (a
submodule of a submodule included) operates on the whole enclosing
workspace, and running inside a secondary checkout or worktree operates
on that checkout.

## Assess current state

```sh
flake-sync status
```

The table shows per repo: branch, git state (`clean+pushed` / `dirty` /
`ahead N` / `behind N`), and per-input pin freshness (`lib=ok`,
`app=stale`). Below it, **Pending** lists `ready` actions (safe
to run now) and `blocked` ones with the reason. Exit 0 either way.

```sh
flake-sync graph    # dependency DAG in topological order
```

`status` compares against local remote-tracking refs; add `--fetch` to
fetch the repos first (slower, needs network). `pull` always fetches.
The fetches run 8 at a time. Each repo fetches its default branch, named
by its local `refs/remotes/<remote>/HEAD`, and the upstream of the branch
it has checked out, without tags. When its `HEAD` is then on no
remote-tracking ref, or the default branch is not known, the repo fetches
all its refs instead, because `HEAD` may have been pushed to a branch that
is not checked out, and pushed-ness counts any remote ref.

Add `--with-partitions` (or `--all`) to any command to also manage
partition/dev input flakes, that is the *tracked* `flake.lock` files below a
repo's root (e.g. `tests/dependencies/`). Their pins show up labeled
(`tests/dependencies:lib=stale`), join the DAG, and are advanced by the
same `update-pins` step in one commit with the root lock. Dev pins can
create edges the root DAG doesn't have; a true cycle is rejected with an
explanation since it has no convergent fixpoint.

`--with-tests` (also in `--all`) covers always-unlocked test flakes (a
tracked `flake.nix` with a gitignored lock): they get their inputs via nix
wiring at eval time, so `--with-partitions` already keeps them current.
The only mechanical hazard is a stray untracked `flake.lock` appearing
there (it silently pins standalone runs to stale revs). Those are
reported as informational notes; nothing is deleted and they don't block
convergence.

`--with-external` (also in `--all`) additionally manages root-level inputs
that aren't sibling repos, such as `nixpkgs` and `home-manager`. These
show up in `status` labeled `ext:` (`ext:nixpkgs=stale`) and join
`update-pins`' plan and commit alongside sibling pins. An external input
is stale if `nix flake update <input>` would move its locked rev. This is
checked by trial-locking into a scratch file, so it costs one `nix`
invocation (network-bound) per external input per repo each time state is
loaded. External pins have no sibling HEAD to pin to; the staleness trial
lock resolves the rev an update would land on, and advancing re-locks with
a fixed `--override-input` to exactly that rev, as for sibling pins, so
the check gate and the written lock see one and the same rev. They have no
unpushed-target concept; they are stale or current.

## Advance one step

```sh
flake-sync next                        # show what would run
flake-sync step                        # run it
flake-sync step <repo>                 # next action for one repo
flake-sync step update-pins <repo>     # explicit action
flake-sync step push <repo>
flake-sync step bump-submodules        # workspace pointer commit
```

In the auto forms (`step`, `step <repo>`), a failing action is skipped and
the remaining ready actions are tried until one succeeds. Exit 0 means a
state change was made, so a loop calling `step` per iteration does not
wedge on one persistent failure. The explicit `step <action> <repo>` form
runs exactly that action with no fallback.

The mutating commands accept `-n` / `--dry-run` to print the underlying
`nix flake check` / `nix flake lock` / `git` commands instead of running
them.

## Full convergence

```sh
flake-sync converge --dry-run   # preview first step + remaining plan
flake-sync converge             # loop until converged or blocked
```

`converge` exits 1 when blockers remain or some pins were held back
(failing check, unpushed target); the exit status reports blockers.
Resolve the listed blockers (commit dirty files, check out a branch, pull,
fix the failing check) and rerun.

### How pin commits are published

Outside CI, pin commits reach the default branch of a GitHub repo
through a pull request that holds only them and is merged at once:
`converge` (and `step push`) pushes them to a pin-move branch, opens
the pull request with `gh`, merges it with the first
method the repo allows (rebase, squash, merge commit), deletes the
branch, and moves the local default branch onto the merged result, so
the next level of the DAG pins the commit that is actually on the
remote. A default branch ahead with commits other than flake-sync's
pin and pointer commits is refused, since an immediate merge would skip
their review, and so is a pin commit that changes anything but
`flake.lock` files (and, in the workspace repo, submodule pointers).
Each pin commit carries a `Checked-by: flake-sync --check=<mode>`
trailer naming the check it passed. When the merge cannot happen now:

- the default branch moved on the remote: the pull request is closed
  and the run stops; a rerun recomputes the pins on the new tip;
- branch protection waits for required checks or reviews: auto-merge is
  turned on and the run stops; a rerun after the merge continues.

Either way the local default branch is reset to the remote one, so no
pin commit is stranded locally. `--trust-local-checks` skips the wait:
it runs `nix flake check` here at the `--check` depth, then merges with
`gh pr merge --admin`, which needs admin rights on the repo. CI
convergence (`GITHUB_ACTIONS=true`) and repos without a GitHub remote
push pin commits directly. `gh` is `FLAKE_SYNC_GH` when set, else the
first `gh` on the caller's PATH, which a credential wrapper may
provide, else the packaged one.

The prefix `flake-sync/pins/` is reserved for pin-move branches. A
pin-move branch holds pin commits on the remote default branch and
nothing else, so it is not a topic branch. It is named
`flake-sync/pins/<hash>`, after the paths and contents of the files the
move writes, so two runs that make the same move meet at one branch:
the second finds it open, names its pull request, and stops.

## Verifying lock changes

`flake-sync-verify-locks [--pin-move] <base> <head>`
([`src/flake-sync-verify-locks`](../../src/flake-sync-verify-locks),
the package `flake-sync-verify-locks`) checks the `flake.lock` files
and submodule pointers that `<head>` changes since its merge base with
`<base>`, in the repository of the current directory. It exits 0 when
the changes pass and 1 with the reasons when they do not; `--help`
lists the checks.

It rebuilds each changed lock. Starting from the lock at the merge
base, with the `flake.nix` of the head, it holds each input that the
head adds or moves at the commit the head locks, runs `nix flake lock`,
and compares the result with the head's lock byte for byte. Before it
holds an input there, it clones the history of the branch or tag that
the input's `original` names, or of the default branch when `original`
names none, and requires the commit to be on it. A moved input must
also descend from the commit it moves from. The clone holds only that
history, so a commit that GitHub serves under the upstream's name but
that only a fork holds is not found in it. `locked` must name the same
repository as `original`, because `--override-input` keeps `original`
from `flake.nix` whatever repository it locks. A submodule pointer gets
the same history check, against the branch that `.gitmodules` names.

Without `--pin-move`, the inputs locked at the merge base and the
submodule pointers stay where they are, and a pull request may add
inputs and submodules. With `--pin-move`, each commit has one parent
and changes `flake.lock` files and submodule pointers only, and nothing
is added. A pin move of an input other than a `github` or `git` one,
such as a tarball, is refused, since its commits cannot be traced; an
added one passes when `nix flake lock` fetches the same content from
the URL in `flake.nix`.

`tests/vm/verify-locks.sh` holds a scenario for each change the
verifier refuses, and for the pin moves and added inputs it accepts.

### The verify-locks workflow

[`.github/workflows/verify-locks.yml`](../../.github/workflows/verify-locks.yml)
runs the verifier on a pull request. A repository calls it from a
workflow triggered by `pull_request_target`, which runs the copy of the
caller on the base branch:

```yaml
name: verify-locks
on:
  pull_request_target:
    types: [opened, synchronize, reopened, edited]
permissions: {}
jobs:
  verify-locks:
    uses: clhodapp/flake-sync/.github/workflows/verify-locks.yml@<commit>
    permissions:
      contents: write
      pull-requests: write
      statuses: write
    with:
      flake-sync: <commit>
      app-id: ${{ vars.VERIFY_LOCKS_APP_ID }}
      act-on-pin-moves: true
    secrets:
      app-private-key: ${{ secrets.VERIFY_LOCKS_APP_PRIVATE_KEY }}
```

`<commit>` is the full hash of a flake-sync commit, the same in both
places. A pull request from a `flake-sync/pins/` branch of the same
repository is checked as a pin move; any other pull request gets the
checks without `--pin-move`.

The verify job evaluates the `flake.nix` files of the pull request, so
it runs with a read-only token and no secrets. The report job posts the
result as the commit status `flake-sync/verify-locks` on the head
commit, and runs no code from the pull request. With `app-id`, the
status comes from that GitHub App, which needs write access to commit
statuses, and to contents and pull requests for `act-on-pin-moves`. A
ruleset on the default branch then requires `flake-sync/verify-locks`
from that App. A ruleset that requires it from GitHub Actions is
weaker, since a workflow that a pull request adds can report a check
of the same name from GitHub Actions.

With `act-on-pin-moves`, a pin move that passes gets auto-merge, bound
to the checked head commit, so it merges once the other required
checks pass; the repository must allow auto-merge. A pin move that
fails is closed and its branch deleted. When flake-sync's immediate
merge of a pin move waits on the status, it turns on auto-merge too
(§ How pin commits are published).

## Pin requests

A pin request is a GitHub issue that asks CI to move inputs of the root
`flake.lock` of a repository to the tips of their branches. CI makes
the move, so every byte of the lock comes from CI and the upstream
branches. Its title is `flake-sync update <input> ...`.

`flake-sync-pin-request`
([`src/flake-sync-pin-request`](../../src/flake-sync-pin-request), the
package of the same name) has three commands:

- `sign --repo=<owner/name> <input> ...` prints the title and body of a
  signed request. The body holds the request text (the repository, the
  inputs, and an expiry, by default an hour ahead and at most a week)
  and its signature by an SSH key, made with `ssh-keygen -Y sign` in
  the namespace `flake-sync-pin-request`. The key is `--key` or the git
  setting `user.signingkey`; a public key is signed through ssh-agent.
- `file` signs the request and opens the issue with `gh`.
- `serve` carries a request out, in a checkout of the default branch.

`serve` takes the input names from the title and refuses a title with
anything else in it, or an input that the root lock does not lock. It
runs `nix flake update` on those inputs and, unless the request is
trusted, `nix flake check` with builds. Then it commits `flake.lock`
with `Requested-in:` and `Checked-by:` trailers and pushes to the
default branch. When the push is refused because the branch moved, it
starts again from the new tip, checking again. A request is trusted
when its body carries a valid signature over a request for this
repository and exactly these inputs, not expired, by a key that the
allowed-signers file of the default branch
(`.github/flake-sync-allowed-signers`, in the format of
`ssh-keygen -Y verify`) accepts for the namespace
`flake-sync-pin-request`. Any other request runs the check. Adding or
rotating a key is a commit to that file:

```text
alice namespaces="flake-sync-pin-request" ssh-ed25519 AAAA...
```

[`.github/workflows/pin-request.yml`](../../.github/workflows/pin-request.yml)
runs `serve` for a repository that calls it on `issues`:

```yaml
name: pin-request
on:
  issues:
    types: [opened, reopened]
permissions: {}
jobs:
  pin-request:
    uses: clhodapp/flake-sync/.github/workflows/pin-request.yml@<commit>
    permissions:
      contents: read
      issues: write
    with:
      flake-sync: <commit>
```

A deploy key fetches and pushes the move: an SSH key with write
access to this repository alone. Its private half is the secret
`PIN_REQUEST_DEPLOY_KEY` of the environment `pin-request` (the input
`environment` names another), and the rulesets of the default branch
must list deploy keys as a bypass actor. The environment's deployment
branch policy should allow the default branch only: a repository
secret is readable by a workflow on any branch, and the key pushes
past the rulesets. Make one with
`ssh-keygen -t ed25519 -N '' -C 'flake-sync pin-request' -f key`, add
`key.pub` as a deploy key with write access, store `key` as the secret,
and delete both files. A push
with the key starts the workflows that the push triggers, as a push
by the workflow's `GITHUB_TOKEN` does not. The workflow answers on the issue
with the commit and closes it, or comments why the request was refused
or the check failed and leaves it open; reopening it runs the request
again. `tests/vm/pin-request.sh` holds a scenario for each kind of
signature that is not accepted, the failing check, malformed titles,
and a push that loses a race.

## Down-sync: pull

```sh
flake-sync pull
```

The converse of `converge`: instead of publishing local state, bring this
checkout to the published state. Remote convergence (e.g. a CI runner)
routinely moves the remotes past a checkout (pin commits, pointer bumps),
and plain git can only follow with `git pull` + `git submodule update`,
which leaves the submodules on detached HEADs, because to git a gitlink
is only a pin. A converged workspace guarantees more: each recorded
pointer is the pushed tip of its submodule's default branch, so `pull` can
re-attach each submodule to that branch, fast-forwarded to the pointer.

Concretely: fetch the repos, fast-forward the workspace to its upstream,
clone each submodule that is registered (`git submodule init`) but not
cloned, then per submodule check out the default branch and fast-forward
it to the recorded pointer. A checkout may hold only some submodules: one
that is not registered in the workspace's `.git/config`, such as after
`git submodule deinit`, is left out, not counted as held, and named in a
closing note. A submodule newly added to `.gitmodules` is not registered
yet either, so it too stays out until `flake-sync checkout <repo>`.
Branches move by fast-forward only, and the hold-backs mirror
`converge`'s per-repo style: a submodule that is dirty (when files would
have to move), whose default branch has diverged from the pointer, or
that is parked on a topic branch is held, reported, and left as it is.
Exit 1 lists the holds while the rest still syncs. A default branch
*ahead* of the pointer (unpushed local work) is attached and left alone,
with a note. A pointer that doesn't match the submodule's
`origin/<default>` also gets a note: remote convergence is likely
mid-flight, rerun `pull` once it lands. The workspace itself must be on a
branch with an upstream and is only ever fast-forwarded; if it has
diverged, `pull` refuses and points at `git pull --rebase`.

### pull --heads: the remotes' state, ahead of the pointers

```sh
flake-sync pull --heads
flake-sync converge --local --with-partitions
```

The recorded pointers describe the last *converged* state, so between a
landing and the convergence run that follows it they lag the remotes:
a subproject's `main` has moved, no pin commit or pointer bump exists
yet. `pull --heads` syncs each submodule to `origin/<default>` instead of
to the pointer, with the same fast-forward-only moves and the same holds,
so the checkout reaches the remotes' state directly. That is the state
convergence starts from, which makes the pair above a local convergence
run: the locks `converge --local` then writes are the ones the next
convergence commits. A convergence runner does the same before it
converges, so `pull --heads` is that step as well. The pointers a
`--heads` sync leaves behind are noted, not held; convergence records
them when it lands.

## A checkout with only some submodules

```sh
flake-sync checkout <repo>...
flake-sync checkout --all
flake-sync --fetch --checkout-missing converge
```

A submodule in `.gitmodules` is a workspace repo whether or not this
checkout holds it. A submodule that is not checked out is read from its
remote: its head is the remote's default-branch head with `--fetch`, and
the recorded pointer otherwise, and its locks (partition locks too, with
`--with-partitions`) come from that commit, fetched by
`nix flake prefetch`, 8 at a time. `status` lists it as `not checked
out`, and `graph` keeps it in the DAG.

Pins onto such a repo are managed as usual: its head is pushed by
definition, so `converge` re-pins the checked-out consumers onto it, and
bumps its workspace pointer without a checkout. A stale pin *of* the repo
needs a checkout to advance. Without `--checkout-missing`, `converge`
advances the other repos and then fails, naming the repo and the flag.
With it, `converge` clones the repo, attaches it to its default branch at
the remote's tip, and advances it. Only a repo with a pin that can
advance now is cloned; one whose stale pins wait on unpushed targets
stays out, since a checkout would not let it move. flake-sync tells the
two apart from the lock it read from the remote.

`checkout` clones the named submodules, or with `--all` all those that are
not checked out here, and attaches each to its default branch at the
recorded pointer (`--heads`: at `origin`'s tip), the state `pull` leaves a
submodule in. `check` skips a repo that is not checked out and names it.
`pull` is the exception to all of this: it reads only git's registration,
as described under `pull`.

## Agent worktrees

```sh
git worktree add -b <topic> <path>     # from the workspace's primary checkout
cd <path>
flake-sync checkout <repo>...          # materialize the submodules the task needs
```

In a linked worktree of the workspace (`git worktree add`, as agent
sessions use), `checkout` shares the repo git keeps for each submodule in
the workspace's common git dir (`.git/modules/<submodule name>`), so a
submodule is cloned at most once per workspace, and a fetch in any
worktree serves all of them. It fetches that repo, cloning it there first
if no checkout has needed it before, and adds the submodule as a linked
worktree of it. The checkout is on a branch named after the workspace
worktree's branch, created from `origin`'s default branch tip with no
upstream, so a push sends it to a topic branch of the same name.

Topic branches carry no pin moves; locks move only by convergence on the
default branches. In a linked worktree, a publishing `converge`, and
`step` other than `step push`, read each submodule from its remote
default branch, as for one that is not checked out, and make each pin
move in a temporary worktree of the shared module repo at
`origin/<default>`, published as a pin move (above); the topic branches
checked out there stay as they are. The workspace repo's pins and
pointers are left to convergence of its default branch. To build
against local, unpushed changes of other repos, use
`override-inputs --local`. `step push <repo>` pushes a topic branch, and
refuses while a repo it depends on has commits that are not pushed yet,
so branches reach the remote in dependency order.

## Changes that span repos: pull requests

```sh
flake-sync --fetch unmerged-commits            # what is unmerged, in pull request order
flake-sync pr <repo> --title=<title> --body-file=<file>
flake-sync rebase <repo>                       # onto the converged default branch
```

The commands rest on these rules. Work freely locally: build against
committed, unpushed changes of other repos with `override-inputs
--local`, which writes no lock. Push a topic branch only once what it
builds against is on the remote. Keep a pull request a draft until its
target branch holds what it needs. Carry no lock moves in a pull request
of a change: locks move only by convergence on the default branches.
The commands work in the primary checkout and in agent worktrees alike.

`unmerged-commits` (`--json` for scripts) lists, in DAG order, the
checked-out repos whose branch has commits besides pin updates that are
not on the remote default branch, with the branch, whether it is pushed,
the commits, the listed repos it depends on, its pull request on a
GitHub remote, and its state:

- **dependencies not ready**: a repo it depends on is listed, so the
  change it needs is not merged yet. Its pull request stays a draft.
- **waiting for convergence**: nothing it depends on is listed, but its
  default branch pins a workspace dependency at a commit other than that
  dependency's remote default head. Convergence moves the pin; run
  `--fetch unmerged-commits` again afterwards.
- **ready**: its default branch pins each workspace dependency at the
  remote head, so the pull request can leave draft once the branch is
  rebased onto the default branch.

The listed order is the order to open and merge the pull requests in.

`pr <repo> --title=<title> --body-file=<file>` pushes the repo's topic
branch (`step push`'s rules apply) and opens or updates its pull request,
assigned to the `gh` user. Until `unmerged-commits` calls the repo ready
and the branch contains the remote default branch, the pull request is a
draft whose body starts with a `status:` line naming the reason; a later
`pr` run takes it out of draft once both hold, and returns an open one
to draft if they stop holding. A merged pull request is refused, since
it takes no new commits.

`rebase <repo>` brings a topic branch onto the converged default branch
after its dependencies merge. A `flake.lock` conflict, which only a
branch that adds or changes inputs has, takes the default branch's lock
and runs `nix flake lock`, which locks just the inputs the branch's
`flake.nix` adds; a conflict in any other file stops the rebase for
resolution by hand. The rebased branch is pushed with
`--force-with-lease --force-if-includes`: it replaces the remote tip
only when that tip is part of the local branch's history.

For a change A in repo 1 that change B in repo 2 needs:

1. Develop both on topic branches; build B against A with
   `nix build $(flake-sync --local override-inputs ./<path-to-repo-2>#<attr>)`.
2. `pr repo-1 …` opens A for review; `pr repo-2 …` opens B as a draft
   (dependencies not ready).
3. A merges; convergence re-pins repo 2's default branch (B shows
   waiting for convergence until then).
4. `rebase repo-2`, then `pr repo-2 …` takes B out of draft.

## Local convergence: check and accelerate, publish nothing

```sh
flake-sync converge --local --with-partitions
```

`--local` advances stale pins in the working trees through the same check
gate, and stops there: it does not commit, push, or bump pointers,
because those are publication. It serves as:

- **A check.** Exit 0 ("Locally converged") proves that each stale pin can advance
  to the pushed sibling tips past the gate, the pre-flight answer to
  "will the ecosystem converge once this is pushed?". Exit 1 names what
  held and why.
- **An accelerator.** The working trees are in the converged state
  immediately, so consumers build against a just-pushed dep without
  waiting for publication's pin commits to land and be pulled.

Because nothing can strand without commits, `--local` runs where the
publishing commands refuse: dirty trees, detached HEADs, and linked
worktrees of the workspace (it covers whatever submodules are checked
out there, and reads the others from their remotes). Pins still advance only to *pushed* sibling revs, so the locks it
writes are byte-for-byte what publication will commit. Those dirty locks
are previews. Discard them with `git checkout -- flake.lock` before
pulling once the matching pin commit lands remotely, since even an
identical uncommitted lock blocks a pull; until then, building on them
is fine. A publishing command (`status`, `converge` without `--local`)
reads pins from the committed locks, so it counts a pin that `--local`
advanced as stale, and `converge` commits and pushes it. A managed lock
that still differs from `HEAD` with no pin update planned blocks
convergence: it holds changes flake-sync does not make, which need a
commit or a `git checkout` by hand. To build against *unpushed* sibling
changes, use `override-inputs --local` (below); it writes no lock.

`--local` composes with the rest of the surface: `status --local` reports
local convergence, `--fetch` refreshes remote refs first so pushed-ness
is judged against the true remote state, and the explicit publication
steps (`step push …`, `step bump-submodules`) are refused.

## Check the repos without moving pins

```sh
flake-sync check                     # eval-only check of each repo
flake-sync check <repo>              # just one repo
flake-sync --check=full check        # also build the flakes' checks
flake-sync --with-partitions check   # include partition/dev flakes
```

`check` runs the same `nix flake check --no-write-lock-file` gate that
`update-pins` applies to proposed pin states, but against each repo's
*current* locks, without overrides, and it writes, commits and pushes
nothing. Depth follows `--check` exactly as for
the gate: `eval` (the default) adds `--no-build`, `full` builds the checks,
and `none` is rejected since it would check nothing. A failing repo doesn't
stop the sweep; each flake reports `check passed`/`check FAILED`, the
summary names the failures, and the exit status is nonzero if any failed.
Use it to find out where the system stands before a converge, or after
landing changes that didn't go through the gate.

## Use pushed changes before they are re-pinned: override-inputs

```sh
nixos-rebuild switch --sudo --flake $(flake-sync override-inputs .)
home-manager switch --flake $(flake-sync override-inputs '.#<user>@<host>')
nix build $(flake-sync override-inputs '.#pkg')
```

`override-inputs <flake-ref>` prints `<flake-ref>` and then one
`--override-input <path> <ref>` pair for each input in its lock that
pins a workspace repo at a commit other than the head of that repo's
remote. `<ref>` names that head. The output takes the place of a flake
reference in any command that accepts `--override-input`, unquoted so the
shell splits it into words. A `#attr` on `<flake-ref>` stays on the
printed reference and is ignored for the lookup. A local reference with a
space in it is printed as the URL Nix resolves it to, with the space
percent-encoded, so no word of the output holds whitespace.

With `--local`, an input whose repo is an initialized submodule of the
checkout you run it in moves to that submodule's `HEAD` instead, as
`git+file://<path>?rev=<HEAD>`, so a build can use commits that are not
pushed yet. Uncommitted changes are not part of `HEAD`, so they are left
out, and a submodule that has any gets a warning on stderr, which a
substitution does not capture. An input whose repo has no initialized
submodule here moves to the head of the repo's remote.

```sh
nixos-rebuild build --flake $(flake-sync --local override-inputs ./<path-to-a-submodule>)
```

The walk covers inputs at any depth that are not `follows`, so a repo that
reaches the flake only through another input gets a nested path such as
`app/lib`. External inputs, such as nixpkgs, are left out, as with
`converge` without `--with-external`.

The flake's lock comes from `nix flake metadata --refresh <flake-ref>`,
the workspace repos from `.gitmodules` (an uninitialized submodule
counts), and each head from `git ls-remote` against the repo's remote. No
checkout is read beyond `.gitmodules`, and nothing is written, so it runs
in any checkout of the workspace. The result is close to what CI
convergence pins once it finishes, without its checks: nothing evaluates
the overridden inputs together before they are printed.

`nixos-rebuild`, `darwin-rebuild`, `home-manager` and the nix CLI accept
the output. `system-manager` and `colmena` do not accept input overrides, so
`override-inputs` cannot help them.

When `override-inputs` fails, the shell substitutes nothing and still runs
the command, so `--flake $(flake-sync override-inputs <ref>)` becomes a
bare `--flake`. `nixos-rebuild` then evaluates the flake of the current
directory. Its error names that flake, as in `flake
'git+file:///path/to/workspace' does not provide attribute
'nixosConfigurations."<host>"'`. To stop on a failure, run the
substitution first and split its result into words when using it: in
bash, `args=$(flake-sync override-inputs <ref>) && nixos-rebuild switch --flake $args`;
zsh does not split an unquoted variable, so there it is `${=args}`.

## Run the newest flake-sync: --latest-flake-sync

```sh
flake-sync --latest-flake-sync override-inputs .
```

The flake-sync on `PATH` is whatever version a lock pinned, such as the
workspace development shell's `flake-sync` input. `--latest-flake-sync`
makes that copy run `nix run --refresh github:clhodapp/flake-sync` with
the same arguments, less the flag, so the command uses the head of
flake-sync's default branch. It changes which flake-sync runs, not what
the command operates on. `FLAKE_SYNC_UPSTREAM` names another flake to run
instead. The started copy runs with `FLAKE_SYNC_LATEST_ACTIVE=1`, so it
ignores the flag rather than starting another.

`flake-sync --version`, and the first line of `--help`, print the store
hash and path of the running build. A copy run from a checkout instead
of the store prints its path.

## Gotchas

- **A detached HEAD blocks the mutating actions.** Submodules checked out by
  `git submodule update` are detached, and `update-pins`/`push` refuse to
  run there, because the commits would strand. Check out the real
  branch first: `git -C <submodule-path> checkout main` (verify main
  matches the recorded pointer before doing this in a checkout you don't
  own).
- **Pins advance only to pushed revs, and only past the check gate, but a
  pin that can't advance holds back only itself.** Stale targets are tried
  cumulatively in dependency order; one that fails the check (or whose rev
  is unpushed) is held individually while sibling pins still advance in a
  partial commit that gets pushed, so progress flows around the failure.
  The action then exits nonzero and reports what was held; rerunning after
  the cause is fixed picks the rest up. `holding pins to unpushed` entries
  resolve themselves during `converge` (the dep gets pushed first). Pins
  move to the target's HEAD or stay where they are; flake-sync does not
  search a target's history for an intermediate rev that would pass.
- **The default check gate is one evaluation per attempted pin
  advance**: `nix flake check --no-build` on the consumer with the
  proposed overrides. `--check=full` also builds the checks (CI-grade;
  builds offload to nix remote builders transparently); `--check=none`
  skips validation entirely.
- **Flakes must evaluate against a read-only store.** `--no-build` sets
  Nix's read-only mode: store objects the evaluation itself would create
  (a `.drv`, a copied source tree) are computed but not written, so an
  evaluation that reads one back fails with `path '…' is not valid`.
  A fresh store has nothing pre-materialized, so it reproduces such a
  failure deterministically; verify a flake or pattern with
  `nix flake check --no-build --store "local?root=$(mktemp -d)"`
  (a real directory: Nix refuses a store root under a symlink).
- **IFD breaks `--check=eval`.** A flake whose *evaluation* reads derivation
  outputs (`builtins.pathExists`/`readDir` on `${drv}/…`) needs builds
  during eval; once a GC removes those outputs, eval-only checks fail with
  `path '…drv' is not valid` until something builds them again. Keep flakes
  IFD-free (do such scans inside the build script instead) and verify with
  `nix flake check --no-build --option allow-import-from-derivation false`.
- **Uncommitted changes other than `flake.lock` block that repo's
  automation** (`need manual commit`). Commit them yourself, then rerun.
  Untracked files don't block.
- **`converge` does not pull or rebase.** `behind upstream by N` means
  the repo needs `flake-sync pull`, or `flake-sync rebase <repo>` for a
  topic branch; only then will pushes for that repo become ready.
  If a remote moves mid-run (another checkout pushed), the rejected push
  gets a clear message with the manual fix, that repo's remote refs are
  refreshed, and `converge` continues with whatever independent work
  remains before exiting 1.
- **Pinning uses `nix flake lock --override-input <name>
  github:owner/repo/<exact-rev>`**, not `nix flake update`, so it needs
  network access to the forge, but is immune to GitHub tarball-TTL cache
  staleness right after a push, and works when a dep sits on a non-default
  branch. Re-pinning one input also refreshes its transitive subtree in the
  lock (expected; that's nix re-locking the inputs of the dep).
- Auto-commits use a `maint:` message convention: `maint: update flake
  pins (…)` for lock changes, committed by pathspec, and `maint: bump …`
  for workspace pointers, built from a scratch index of `HEAD` plus the
  new pointers. Either way anything else you have staged is left alone.
- **External pins (`--with-external`) are tried as one unit, before any
  sibling target.** All of a repo's stale external inputs are checked
  together as a single step; if that step fails `nix flake check`, only the
  external pins are held back (reported as `external pins` in the held-back
  message) and the sibling pins still get separate trials on a clean base.
  There is no per-external-input isolation: one bad external input holds
  back all of that repo's external inputs together.

## Test harness

`tests/vm/` exercises the full lifecycle against a "fake GitHub" of
local bare repos, offline. Host run takes a
minute or two (the default check gate evaluates consumer flakes); from
the repo root:

```sh
T=$(mktemp -d)
HUB=$T/hub WORK=$T/workspace bash tests/vm/fixture.sh
HUB=$T/hub WORK=$T/workspace FLAKE_SYNC=$PWD/src/flake-sync \
  bash tests/vm/scenarios.sh
```

Hermetic NixOS VM run (the flake check, driving the built package; new
files must be `git add`ed first or the flake source won't include them):

```sh
nix build '.#checks.x86_64-linux.vm-lifecycle' -L --no-link
nix build '.#checks.x86_64-linux.vm-verify-locks' -L --no-link
nix build '.#checks.x86_64-linux.vm-pin-request' -L --no-link
```

The fixture only works because the script supports git/file remotes in
addition to `github:` ones; pins for non-github submodule remotes are
advanced with `git+file://…?rev=…&ref=…` overrides.

Building the package itself (`nix build`, or the `package` check) also
shellchecks the script; `bash -n src/flake-sync`
is the quick syntax pass while editing.
