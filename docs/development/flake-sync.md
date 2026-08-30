# flake-sync: DAG-ordered flake pin updates and pushes

flake-sync operates on a *workspace*: a git repo whose submodules are
flakes that pin each other via `github:` (or `git+file:`/`git+ssh:`)
inputs in their `flake.lock`s, while the workspace repo tracks each of
them as a submodule. It discovers every submodule that is a flake, plus
the workspace repo itself, and detects cross-repo pins by matching each
`flake.lock`'s root-level inputs against submodule remote URLs — nothing
is hardcoded, new submodules are picked up automatically. Root-level
inputs that resolve to a real locked node (not a `follows` alias) but
don't match any sibling are "external" inputs, manageable with
`--with-external` (below).

Convergence means: every repo's pins point at the sibling's current local
HEAD, every repo is pushed, and the workspace's submodule pointers match
submodule HEADs. Pins only advance to *pushed* revs, which is what forces
the dependency ordering: dep push → consumer re-pin + push → … → workspace
pointer bumps + push. By default every pin advance is also validated first
with an evaluation-only `nix flake check` of the proposed state
(`--check=eval`); `--check=full` additionally builds the flake's checks,
`--check=none` skips validation.

## Workspace discovery

The workspace root is found from the current directory, never from the
location of the executable: flake-sync takes the enclosing git repo and
walks up as long as the current repo is registered as a submodule of an
enclosing one, ending at the parent-most superproject. A repo that is
nobody's submodule is its own workspace root (it still needs a
`.gitmodules`, or there is nothing to converge). Running outside any git
repo is an error. In particular, running from inside any submodule (a
submodule of a submodule included) operates on the whole enclosing
workspace, and running inside a secondary checkout or worktree operates
on that checkout, not on some other copy.

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
`git fetch` every repo first (slower, needs network).

Add `--with-partitions` (or `--all`) to any command to also manage
partition/dev input flakes — every *tracked* `flake.lock` below a repo's
root (e.g. `tests/dependencies/`). Their pins show up labeled
(`tests/dependencies:lib=stale`), join the DAG, and are advanced by the
same `update-pins` step in one commit with the root lock. Dev pins can
create edges the root DAG doesn't have; a true cycle is rejected with an
explanation since it has no convergent fixpoint.

`--with-tests` (also in `--all`) covers always-unlocked test flakes (a
tracked `flake.nix` with a gitignored lock): they get their inputs via nix
wiring at eval time, so `--with-partitions` already keeps them current —
the only mechanical hazard is a stray untracked `flake.lock` appearing
there (it silently pins standalone runs to stale revs). Those are
reported as informational notes; nothing is deleted and they don't block
convergence.

`--with-external` (also in `--all`) additionally manages root-level inputs
that aren't sibling repos — `nixpkgs`, `home-manager`, and the like. These
show up in `status` labeled `ext:` (`ext:nixpkgs=stale`) and join
`update-pins`' plan and commit alongside sibling pins. An external input
is stale if `nix flake update <input>` would move its locked rev — this is
checked by trial-locking into a scratch file, so it costs one `nix`
invocation (network-bound) per external input per repo every time state is
loaded. External pins have no sibling HEAD to pin to; the staleness trial
lock resolves the rev an update would land on, and advancing re-locks with
a fixed `--override-input` to exactly that rev, same as sibling pins — so
the check gate and the written lock see one and the same rev. They have no
unpushed-target concept — they're simply stale or not.

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
the remaining ready actions are tried until one succeeds — exit 0 means a
state change was made, so a loop calling `step` per iteration can never
wedge on one persistent failure. The explicit `step <action> <repo>` form
runs exactly that action with no fallback.

Every mutating command accepts `-n` / `--dry-run` to print the underlying
`nix flake check` / `nix flake lock` / `git` commands instead of running
them.

## Full convergence

```sh
flake-sync converge --dry-run   # preview first step + remaining plan
flake-sync converge             # loop until converged or blocked
```

`converge` exits 1 when blockers remain or some pins were held back
(failing check, unpushed target) — that is a report, not a script failure.
Resolve the listed blockers (commit dirty files, check out a branch, pull,
fix the failing check) and rerun.

## Down-sync: pull

```sh
flake-sync pull
```

The converse of `converge`: instead of publishing local state, bring this
checkout to the published state. Remote convergence (e.g. a CI runner)
routinely moves the remotes past a checkout (pin commits, pointer bumps),
and plain git can only follow with `git pull` + `git submodule update` —
which strands every submodule on a detached HEAD, because to git a gitlink
is only a pin. A converged workspace guarantees more: every recorded
pointer is the pushed tip of its submodule's default branch, so `pull` can
re-attach each submodule to that branch, fast-forwarded to the pointer.

Concretely: fetch everything, fast-forward the workspace to its upstream,
`git submodule update --init` anything uninitialized, then per submodule
check out the default branch and fast-forward it to the recorded pointer.
Everything moves by fast-forward only, and the hold-backs mirror
`converge`'s per-repo style: a submodule that is dirty (when files would
have to move), whose default branch has diverged from the pointer, or
that is parked on a topic branch is held and reported, never touched —
exit 1 lists the holds while the rest still syncs. A default branch
*ahead* of the pointer (unpushed local work) is attached and left alone,
with a note. A pointer that doesn't match the submodule's
`origin/<default>` also gets a note: remote convergence is likely
mid-flight, rerun `pull` once it lands. The workspace itself must be on a
branch with an upstream and is only ever fast-forwarded; if it has
diverged, `pull` refuses and points at `git pull --rebase`.

## Local convergence: check and accelerate, publish nothing

```sh
flake-sync converge --local --with-partitions
```

`--local` advances stale pins in the working trees through the same check
gate, and stops there: no commits, no pushes, no pointer bumps — those
are publication. Two uses:

- **A check.** Exit 0 ("Locally converged") proves every pin can advance
  to the pushed sibling tips past the gate — the pre-flight answer to
  "will the ecosystem converge once this is pushed?". Exit 1 names what
  held and why.
- **An accelerator.** The working trees are in the converged state
  immediately, so consumers build against a just-pushed dep without
  waiting for publication's pin commits to land and be pulled.

Because nothing can strand without commits, `--local` runs where the
publishing commands refuse: dirty trees, detached HEADs, secondary
checkouts and worktrees (it covers whatever submodules are initialized
there). Pins still advance only to *pushed* sibling revs, so the locks it
writes are byte-for-byte what publication will commit. Those dirty locks
are previews: discard with `git checkout -- flake.lock` — do that before
pulling once the matching pin commit lands remotely, since even an
identical uncommitted lock blocks a pull — or keep building on them until
then. To build against *unpushed* sibling changes, stay with transient
overrides (`--override-input <dep> path:../<dep>`); `--local` never
writes an unpushed rev into a lock.

`--local` composes with the rest of the surface: `status --local` reports
local convergence, `--fetch` refreshes remote refs first so pushed-ness
is judged against the true remote state, and the explicit publication
steps (`step push …`, `step bump-submodules`) are refused.

## Check everything without moving anything

```sh
flake-sync check                     # eval-only sweep of every repo
flake-sync check <repo>              # just one repo
flake-sync --check=full check        # also build every flake's checks
flake-sync --with-partitions check   # include partition/dev flakes
```

`check` runs the same `nix flake check --no-write-lock-file` gate that
`update-pins` applies to proposed pin states, but against every repo's
*current* locks, with no overrides and nothing written — fully read-only
(no re-pins, commits, or pushes). Depth follows `--check` exactly as for
the gate: `eval` (the default) adds `--no-build`, `full` builds the checks,
and `none` is rejected since it would check nothing. A failing repo doesn't
stop the sweep; each flake reports `check passed`/`check FAILED`, the
summary names the failures, and the exit status is nonzero if any failed.
Use it to find out where the system stands before a converge, or after
landing changes that didn't go through the gate.

## Gotchas

- **Detached HEADs block everything mutating.** Submodules checked out by
  `git submodule update` are detached, and `update-pins`/`push` refuse to
  run there — otherwise the commits would strand. Check out the real
  branch first: `git -C projects/<name> checkout main` (verify main
  matches the recorded pointer before doing this in a checkout you don't
  own).
- **Pins advance only to pushed revs, and only past the check gate — but a
  pin that can't advance holds back only itself.** Stale targets are tried
  cumulatively in dependency order; one that fails the check (or whose rev
  is unpushed) is held individually while sibling pins still advance in a
  partial commit that gets pushed, so progress flows around the failure.
  The action then exits nonzero and reports what was held — rerunning after
  the cause is fixed picks the rest up. `holding pins to unpushed` entries
  resolve themselves during `converge` (the dep gets pushed first). Pins
  move to the target's HEAD or not at all: the objective is fewer stale
  pins, not smaller staleness, so the script never hunts a target's history
  for an intermediate safe rev.
- **The default check gate is one evaluation per attempted pin
  advance**: `nix flake check --no-build` on the consumer with the
  proposed overrides. `--check=full` also builds the checks (CI-grade;
  builds offload to nix remote builders transparently); `--check=none`
  skips validation entirely.
- **Flakes must evaluate against a read-only store.** `--no-build` sets
  Nix's read-only mode: store objects the evaluation itself would create
  (a `.drv`, a copied source tree) are computed but never written, so an
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
- **The script never pulls or rebases.** `behind upstream by N` means you
  rebase/pull manually; only then will pushes for that repo become ready.
  If a remote moves mid-run (another checkout pushed), the rejected push
  gets a clear message with the manual fix, that repo's remote refs are
  refreshed, and `converge` continues with whatever independent work
  remains before exiting 1.
- **Pinning uses `nix flake lock --override-input <name>
  github:owner/repo/<exact-rev>`**, never `nix flake update` — so it needs
  network access to the forge, but is immune to GitHub tarball-TTL cache
  staleness right after a push, and works when a dep sits on a non-default
  branch. Re-pinning one input also refreshes its transitive subtree in the
  lock (expected; that's nix re-locking the dep's own inputs).
- Auto-commits use a `maint:` message convention and commit via
  pathspec, so anything else you have staged is left alone.
- **External pins (`--with-external`) are tried as one unit, before any
  sibling target.** All of a repo's stale external inputs are checked
  together as a single step; if that step fails `nix flake check`, only the
  external pins are held back (reported as `external pins` in the held-back
  message) and every sibling pin still gets its own trial on a clean base.
  There is no per-external-input isolation — one bad external input holds
  back all of that repo's external inputs together.

## Test harness

`tests/vm/` exercises the full lifecycle against a "fake GitHub" of
local bare repos (no network, nothing real is touched). Host run takes a
minute or two (the default check gate evaluates consumer flakes); from
the repo root:

```sh
T=$(mktemp -d)
HUB=$T/hub WORK=$T/workspace bash tests/vm/fixture.sh
HUB=$T/hub WORK=$T/workspace FLAKE_SYNC=$PWD/pkgs/flake-sync/flake-sync/flake-sync \
  bash tests/vm/scenarios.sh
```

Hermetic NixOS VM run (the flake check, driving the built package; new
files must be `git add`ed first or the flake source won't include them):

```sh
nix build '.#checks.x86_64-linux.vm-lifecycle' -L --no-link
```

The fixture only works because the script supports git/file remotes in
addition to `github:` ones — pins for non-github submodule remotes are
advanced with `git+file://…?rev=…&ref=…` overrides.

Building the package itself (`nix build`, or the `package` check) also
shellchecks the script; `bash -n pkgs/flake-sync/flake-sync/flake-sync`
is the quick syntax pass while editing.
