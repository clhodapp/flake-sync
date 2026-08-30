# flake-sync

Assesses and converges a *workspace* of flake repos in dependency (DAG)
order: a git repo whose submodules are flakes that pin each other via
`flake.lock` inputs, while the workspace tracks each of them as a
submodule. Convergence means every repo's pins point at the sibling's
current HEAD, every repo is pushed, and the workspace's submodule
pointers match submodule HEADs. Repos and cross-repo pins are discovered
from `.gitmodules` and the lock files; nothing is hardcoded.

```sh
flake-sync status      # git and pin state of every repo, pending actions
flake-sync converge    # run ready actions until converged or blocked
flake-sync check       # read-only nix flake check sweep over every repo
flake-sync pull        # down-sync a checkout the remotes moved past
flake-sync graph       # the dependency DAG in topological order
```

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
