# flake-sync

Assesses and converges a *workspace* of flake repos in dependency (DAG)
order: a git repo whose submodules are flakes that pin each other via
`flake.lock` inputs, while the workspace tracks each of them as a
submodule. Convergence means every repo's pins point at the sibling's
current HEAD, every repo is pushed, and the workspace's submodule
pointers match submodule HEADs. Repos and cross-repo pins are discovered
from `.gitmodules` and the lock files; nothing is hardcoded.

The problem it solves: once a set of flakes pins each other by revision,
landing one change means pushing the dependency, re-locking each
consumer against the new revision, pushing those, and repeating down the
graph. Doing that by hand means sequencing pushes correctly and editing
lock files, and getting it wrong leaves consumers pinned to revisions
that no longer build. flake-sync works out the order from the repos
themselves and runs it.

```sh
flake-sync status      # git and pin state of every repo, pending actions
flake-sync converge    # run ready actions until converged or blocked
flake-sync check       # read-only nix flake check sweep over every repo
flake-sync pull        # down-sync a checkout the remotes moved past
flake-sync pull --heads  # ...to the remotes' tips, ahead of the recorded pointers
flake-sync graph       # the dependency DAG in topological order
```

## Install

Run it without installing anything:

```sh
nix run github:clhodapp/flake-sync -- status
```

Add it to a dev shell, so everyone working in the workspace has the same
version:

```nix
{
  inputs.flake-sync.url = "github:clhodapp/flake-sync";

  # in your devShell:
  #   packages = [ inputs.flake-sync.packages.${system}.flake-sync ];
}
```

`nix profile install github:clhodapp/flake-sync` puts it on `PATH`
permanently. It needs `git` and `nix` at runtime, both of which the
package carries in its own closure.

The workspace is found from the current directory: the enclosing git
repo, walked up to the parent-most repo that tracks it as a submodule. A
repo that is nobody's submodule is its own workspace; running outside
any git repo is an error.

Pins only advance to pushed revs (which is what forces the DAG
ordering), and every proposed pin state is validated with an
evaluation-only `nix flake check` before a lock is written. A pin that
cannot advance holds back only itself. `converge --local` advances
working-tree locks through the same gate and publishes nothing, as a
pre-flight check and accelerator for CI-owned publication.

Full reference, including all flags, gotchas, and the test harness:
[`docs/development/flake-sync.md`](docs/development/flake-sync.md).

## Development

The tool is `pkgs/flake-sync/flake-sync/flake-sync` (bash + jq),
packaged with `writeShellApplication`, which shellchecks it at build
time. `nix flake check` builds the package and an offline NixOS VM test
(`tests/vm/`) that drives the packaged executable through a full
convergence lifecycle against a fake GitHub of local bare repos;
`nix fmt` formats.

In CI the same `nix flake check` runs with the Nix store cached between
runs. A pull request that leaves `.github/` alone is checked by `main`'s
copy of the workflow, in `main`'s context once its own check completes,
and adds its build to the shared cache; one that changes the pipeline is
checked by its own copy, under a cache only it can see. The comments at
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

`main` rolls. There are no tagged releases, and the command surface may
change; pin a revision if you need one that stays put. The command names
and their exit-status conventions (`converge` exiting 1 to report
blockers rather than to signal a crash) are the parts least likely to
move.

## License

MIT, see [`LICENSE`](LICENSE).
