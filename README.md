# flake-sync

Assesses and converges a *workspace* of flake repos in dependency (DAG)
order: a git repo whose submodules are flakes that pin each other via
`flake.lock` inputs, while the workspace tracks each of them as a
submodule. The workspace is converged when the repos pin each other at
their current heads, they are pushed, and the workspace's submodule
pointers match the submodule heads. Repos and cross-repo pins are discovered
from `.gitmodules` and the lock files; nothing is hardcoded.

The problem it solves: once a set of flakes pins each other by revision,
landing one change means pushing the dependency, re-locking each
consumer against the new revision, pushing those, and repeating down the
graph. Doing that by hand means sequencing pushes correctly and editing
lock files, and getting it wrong leaves consumers pinned to revisions
that no longer build. flake-sync works out the order from the repos
themselves and runs it.

```sh
flake-sync status            # git and pin state of the repos, pending actions
flake-sync converge          # run ready actions until converged or blocked
flake-sync converge --local  # advance working-tree locks only; publish nothing
flake-sync check             # nix flake check over the repos, read-only
flake-sync pull              # down-sync a checkout the remotes moved past
flake-sync pull --heads      # ...to the remotes' tips, ahead of the recorded pointers
flake-sync graph             # the dependency DAG in topological order
flake-sync checkout <repo>   # add a submodule to a checkout that holds only some
flake-sync override-inputs <ref>  # a flake ref plus overrides to the remote heads
flake-sync unmerged-commits  # changes not on the default branches, in pull request order
flake-sync pr <repo> …       # open or update a pull request, a draft until it can merge
flake-sync rebase <repo>     # rebase a topic branch onto the converged default branch
```

A change in one repo that another repo needs goes through pull requests
in dependency order: `unmerged-commits` gives the order and says which
pull requests can leave draft, and `pr` keeps a pull request a draft
until its default branch pins the merged dependencies. Lock changes are
not part of those pull requests; convergence makes them on the default
branches. A converge run outside CI merges them through separate pull
requests that hold only lock changes and are merged at once; CI
convergence pushes them directly.

## Install

Run it without installing anything:

```sh
nix run github:clhodapp/flake-sync -- status
```

Or add it to the workspace's dev shell:

```nix
{
  inputs.flake-sync.url = "github:clhodapp/flake-sync";

  # in your devShell:
  #   packages = [ inputs.flake-sync.packages.${system}.flake-sync ];
}
```

The workspace's `flake.lock` then decides the version everyone in the
workspace runs, and updating the input moves it forward, with
`nix flake update flake-sync` or whatever routine updates the
workspace's other inputs. `flake-sync --latest-flake-sync <command>`
runs the head of `main` without changing the lock.

The `flake-sync-skills` package holds agent skills for setting up and
working in a flake-sync workspace (`flake-sync-new-workspace`,
`flake-sync-workspaces`, `flake-sync-pull-requests`,
`flake-sync-converge`, `flake-sync-worktrees`), one directory per skill
with a `SKILL.md` and
the reference beside it, in the Agent Skills format, for any agent that
reads skills from a directory. The skills explain how the workspace and
the commands work; a workspace's instructions for agents and
contributors say when to use them, and `flake-sync-new-workspace` walks
through settling those instructions with the workspace's owner.

`nix profile install github:clhodapp/flake-sync` puts it on `PATH`
permanently. The package carries the programs it runs, `git`, `nix`
and `gh` included.

The workspace is found from the current directory: the enclosing git
repo, walked up to the parent-most repo that tracks it as a submodule. A
repo that is not a submodule of another repo is a workspace by itself; running outside
any git repo is an error.

Pins only advance to pushed revs (which is what forces the DAG
ordering), and a proposed pin state is first validated with an
evaluation-only `nix flake check` before a lock is written. A pin that
cannot advance holds back only itself. `converge --local` advances
working-tree locks through the same gate and publishes nothing, as a
pre-flight check and accelerator for CI-owned publication.

Full reference, including all flags, gotchas, and the test harness:
[`docs/development/flake-sync.md`](docs/development/flake-sync.md).

## Development

The tool is `pkg-overlays/default/packages/flake-sync/flake-sync` (bash + jq),
packaged with `writeShellApplication`, which shellchecks it at build
time. `nix flake check` builds the package and an offline NixOS VM test
(`tests/vm/`) that drives the packaged executable through a full
convergence lifecycle against a fake GitHub of local bare repos;
`nix fmt` formats.

In CI the same `nix flake check` runs with the Nix store cached between
runs. A pull request that leaves `.github/` alone is checked by `main`'s
copy of the workflow, in `main`'s context once the request's check-pr
run completes, and adds its build to the shared cache; a pull request
that changes the pipeline is checked by the copy of the workflow it
carries, under a cache only that request can see. The comments at
the top of the two workflow files say why that split is what makes the
cache safe to write from a pull request.

## Binary cache

What `main` builds is pushed to the `clhodapp` cachix cache, signed with
its key, so `nix run github:clhodapp/flake-sync` at the same pins
downloads the packaged tool instead of building it. That cache skips
paths its upstreams already hold, so using it means using them too:

| Substituter | Public key |
|---|---|
| `https://clhodapp.cachix.org` | `clhodapp.cachix.org-1:EW/0conxH0OQyo0o4ub/grdkFspholmQMSnQyj0vrZI=` |
| `https://nix-community.cachix.org` | `nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=` |
| `https://numtide.cachix.org` | `numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE=` |

Add all three to `extra-substituters` and `extra-trusted-public-keys`.
The flake also declares them in `nixConfig`, which applies when it is
evaluated directly and the prompt (or `--accept-flake-config`) accepts
them.

## Stability

flake-sync is a rolling release: the head of `main` is the current
version, and updating a workspace's flake-sync input moves it to that
head. Commands and flags can change between versions; `flake-sync
--help` and the reference describe the version in use.

## License

MIT, see [`LICENSE`](LICENSE).
