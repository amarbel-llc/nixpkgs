# rolldown-poc

Proof-of-concept demonstrating that the fork's `bun2nix` build-support library
can package an npm-style project whose dependency graph includes native Rust
binaries distributed as optional platform-specific packages.

## What it proves

- `rolldown` (`1.0.0-rc.9`) installs and runs inside a Nix sandbox via Bun.
- The full set of `@rolldown/binding-*` native bindings is captured
  deterministically in the FOD (fixed-output derivation) via `fetchBunDeps`.
- At build time, Bun populates `node_modules/` with the host-matching binding
  and `bun run build` invokes rolldown to produce `dist/bundle.js`.
- No custom `rolldown2nix` / `buildNpmPackage` wrapper is required.

See GitHub issue #8 for the motivating context.

## Layout

- `src/index.ts` — trivial one-line TS source
- `rolldown.config.mjs` — minimal rolldown config
- `package.json` — depends only on `rolldown`
- `bun.lock` / `bun.nix` — generated lockfile and its Nix-consumable form
- `flake.nix` / `default.nix` — Nix entry points
- `justfile` — `explore`-group recipes for rerunning each step

## Running the PoC

```sh
just nix-build
# → result/dist/bundle.js
```

To re-run the host-side sanity check (regenerate `bun.lock` and bundle locally):

```sh
just bootstrap  # bun install
just host-build # bun run build
```

To regenerate `bun.nix` after dependency changes:

```sh
just regen-bun-nix
```

## Known caveats

1. **Per-machine absolute path.** `flake.nix` pins `inputs.nixpkgs.url` to an
   absolute path of this fork's worktree
   (`/home/sasha/eng/repos/nixpkgs/.worktrees/plain-linden`).
   - Why: relative `path:../..` gets re-rooted to the `/nix/store` copy of the
     flake at eval time (resolves to `/nix/`, which is forbidden in pure mode).
   - Consequence: running the PoC on another machine or a different worktree
     requires editing that URL.
   - Future cleanup: once the parent flake exposes a `legacyPackages.*`
     attribute for the PoC, the standalone flake can go away.

2. **`cacheEntryCreator` passed directly, not via the overlay.** The fork's
   overlay at `overlays/amarbel-packages.nix` currently calls
   `callPackage pkgs/build-support/bun2nix {}` with an empty attrs. That makes
   `pkgs.fetchBunDeps` throw unless the caller re-invokes `callPackage` with
   `cacheEntryCreator` explicitly — which is what `flake.nix` here does.
   - Future cleanup: wire `cacheEntryCreator` through the overlay so the PoC
     can simply consume `pkgs.mkBunDerivation` / `pkgs.fetchBunDeps`.
