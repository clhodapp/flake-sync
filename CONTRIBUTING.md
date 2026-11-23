# Contributing

## Layout

- `src/flake-sync`: the tool, a bash script that uses `jq` for JSON.
- `skills/`: agent skills for using flake-sync in a workspace, one
  directory each.
- `pkg-overlays/`: the packages, `flake-sync` (built with
  `writeShellApplication`, which shellchecks the script) and
  `flake-sync-skills`.
- `configs/flake-parts/`: the flake outputs.
- `tests/vm/`: the lifecycle test.

## Rules

- Declare every program the script runs in `runtimeInputs` of
  `pkg-overlays/default/packages/flake-sync/default.nix`.
- Add a scenario to `tests/vm/scenarios.sh` for each change in behavior.
- Update the reference (`docs/development/flake-sync.md`), the README,
  and the help text in `src/flake-sync` along with the behavior.
- Keep the skills to what the commands do. Leave when to use them to
  the workspace's instructions; put no workspace policy in them.
- Advance pins only to pushed revisions. Lock an unpushed revision and
  nobody else can resolve the lock.
- Hold back only the pin that cannot advance. Let the other pins of the
  repo advance and be committed, and report what was held.
- `git add` new files before running a check; the flake reads the git
  tree, so an untracked file is invisible to the build.
- Write commit messages with a `type: summary` first line (`feat`, `fix`,
  `maint`, `docs`, `refactor`), in the present tense, with a body saying
  why when the change is not self-evident.

## Issues

File bugs and requests at
[github.com/clhodapp/flake-sync/issues](https://github.com/clhodapp/flake-sync/issues).
For a bug, include the output of `flake-sync --version`, the command you
ran, its output, and what you expected instead. For a request, describe
the workspace situation it is for.

## Pull requests

- Branch from `main`, in a fork if you cannot push to the repo; keep a
  pull request to one change.
- Run `nix flake check` before opening it. CI runs it again on the pull
  request.
- In the description, say what changes and why, and name the scenario
  that covers a change in behavior.
- When `main` moves, rebase the branch onto it; do not merge `main` into
  the branch.

## Checks

```sh
bash -n src/flake-sync                                  # syntax, while editing
nix build '.#checks.x86_64-linux.flake-sync-package'    # build + shellcheck
nix build '.#checks.x86_64-linux.treefmt'               # formatting
nix build '.#checks.x86_64-linux.vm-lifecycle' -L       # the lifecycle test
nix build '.#checks.x86_64-linux.vm-verify-locks' -L    # the verifier scenarios
nix build '.#checks.x86_64-linux.vm-pin-request' -L     # the pin request scenarios
nix fmt                                                 # format the Nix files
```

`nix flake check` runs these checks.

## The lifecycle test

`tests/vm/fixture.sh` builds a workspace of local bare repos with
cross-repo flake pins, using `git+file://` remotes, inside a NixOS VM
with no network. `tests/vm/scenarios.sh` then drives the packaged
executable through plain bash assertions on its output and on the
resulting repo state.

To run the scenarios on the host, faster while writing one:

```sh
T=$(mktemp -d)
HUB=$T/hub WORK=$T/workspace bash tests/vm/fixture.sh
HUB=$T/hub WORK=$T/workspace FLAKE_SYNC=$PWD/src/flake-sync \
  bash tests/vm/scenarios.sh
```
