# Contributing

## The shape of the thing

The tool is one bash script,
`pkgs/flake-sync/flake-sync/flake-sync`, using `jq` for JSON. It is
packaged with `writeShellApplication`, which shellchecks it as part of
the build and pins its runtime dependencies, so the package cannot
build if the script has a shellcheck error or calls a program that is
not declared in `runtimeInputs`.

Everything else in the repo is scaffolding: `pkgs/` packages the script,
`configs/flake-parts/` wires the flake outputs, and `tests/vm/` is the
lifecycle test.

## Working on it

While editing, `bash -n pkgs/flake-sync/flake-sync/flake-sync` is the
quick syntax pass. Then:

```sh
nix flake check
```

That builds the package (shellcheck included), checks formatting, and
runs the VM lifecycle test. The VM test takes a while; to iterate faster,
build the pieces separately:

```sh
nix build '.#checks.x86_64-linux.package'      # build + shellcheck
nix build '.#checks.x86_64-linux.treefmt'      # formatting
nix build '.#checks.x86_64-linux.vm-lifecycle' # the lifecycle test
```

`nix fmt` formats the Nix files.

If you add a file, `git add` it before running a check. Nix evaluates the
flake from the git tree, so an untracked file is invisible and the build
will fail confusingly.

## The lifecycle test

`tests/vm/` builds a "fake GitHub": a set of local bare repos wired
together as a workspace with cross-repo flake pins, all inside a NixOS
VM with no network. The test then drives the *packaged* executable
through the scenarios in `tests/vm/scenarios.sh`, so it exercises what
users actually run rather than the script in the working tree.

To run the scenarios on the host instead of in the VM, which is faster
while developing a scenario:

```sh
T=$(mktemp -d)
HUB=$T/hub WORK=$T/workspace bash tests/vm/fixture.sh
HUB=$T/hub WORK=$T/workspace FLAKE_SYNC=$PWD/pkgs/flake-sync/flake-sync/flake-sync \
  bash tests/vm/scenarios.sh
```

The fixture uses `git+file://` remotes rather than `github:` ones, which
works because the tool advances pins for non-GitHub submodule remotes
with `git+file://…?rev=…&ref=…` overrides.

New behavior wants a scenario. The scenarios are plain bash assertions
against the tool's output and the resulting repo state, so adding one
means adding a case to `scenarios.sh` rather than learning a framework.

## Two invariants worth knowing before you change behavior

**Pins only ever advance to pushed revisions.** This is what forces the
dependency ordering, and it is why a pin whose target is unpushed is
held rather than written. Writing an unpushed revision into a lock
produces a lock nobody else can resolve.

**A pin that cannot advance holds back only itself.** Failures are
per-pin, not per-run: the rest of that repo's pins still advance and get
committed, and the action reports what it held. Preserve that when
touching the update path, or one bad dependency will stall everything
downstream of it.

## Commits and pull requests

Commit messages use a `type: summary` first line (`feat`, `fix`,
`maint`, `docs`), present tense, with a body explaining why when the
change is not self-evident. History is linear; rebase rather than merge.

Please make sure `nix flake check` passes before opening a pull request.
