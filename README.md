# flake-sync

Packages [`ch-nix-workspace`](https://github.com/clhodapp/ch-nix-workspace)'s
`scripts/flake-sync` as `pkgs.<system>.flake-sync`, so it can be added as a
plain package dependency anywhere a real Nix closure is required — for
example, a [claude-code-sandbox](https://github.com/clhodapp/claude-code-sandbox)
profile's `toolset`, which needs everything it makes available to be a
real package, not a filesystem script.

## What it does

The package is a thin `writeShellApplication` wrapper that locates a
checked-out `ch-nix-workspace` from the invoking `cwd` (via
`git rev-parse --show-superproject-working-tree`, falling back to
`show-toplevel`) and `exec`s its `scripts/flake-sync`. It never vendors a
copy of the script into the store — a store copy would go stale, and
`scripts/flake-sync` itself re-derives the true workspace root from its
own on-disk location once exec'd, so nothing about the wrapper's search
needs to be authoritative, only successful.

Running `flake-sync` outside any `ch-nix-workspace` checkout fails loudly
with a clear message rather than a bash `exec: not found`.

## Development

`nix flake check` builds the package (proving its declared closure —
`git`, `gh`, `nix`, `jq` — is complete); `nix fmt` formats. The package
build cannot exercise `scripts/flake-sync`'s own logic, since no workspace
checkout exists inside the Nix build sandbox; that's covered by
`ch-nix-workspace`'s own VM test.
