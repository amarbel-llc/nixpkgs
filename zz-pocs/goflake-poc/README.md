# goflake-poc

Proof-of-concept: source a Go module dependency from a nix flake input.

## Hypothesis

A consumer Go module whose `go.mod` declares

```
require github.com/poc/lib v0.0.0-00010101000000-000000000000

replace github.com/poc/lib => ./.flake-inputs/poc-lib
```

can be built end-to-end inside the nix sandbox, with no network access and no
`go.sum` entry for the replaced module, as long as the nix builder symlinks
the flake input's source into `./.flake-inputs/poc-lib` before invoking
`go build`.

The pseudo-version `v0.0.0-00010101000000-000000000000` is the minimum
syntactically-valid sentinel that `module.CanonicalVersion` (and thus
`modfile.Parse` with a nil fixer) accepts. Its actual content is irrelevant —
the `replace` directive overrides resolution.

## Layout

- `main.go` + `go.mod` — consumer; imports `github.com/poc/lib` and prints
  its `Sentinel` constant.
- `upstream/` — toy "upstream Go library" (own `go.mod`, exports
  `Sentinel = "FLAKE_INPUT_OK_v1"`). Wired into `flake.nix` as a non-flake
  `path:` input.
- `flake.nix` — declares `poc-lib` input pointing at `./upstream`, exposes
  `packages.default` (buildGoModule) + `packages.via-gomod2nix`
  (buildGoApplication) and a devShell with `go`.
- `default.nix` — buildGoModule variant; `preBuild` symlinks
  `${pocLibSrc}` into `.flake-inputs/poc-lib`.
- `default-via-gomod2nix.nix` — buildGoApplication variant; documents the
  structural mismatch with the bridge pattern (see Findings).
- `gomod2nix.toml` — minimal (just `schema = 3`) for the
  buildGoApplication variant.
- `justfile` — `explore`-group recipes for each phase.
- `.flake-inputs/` — gitignored; populated by the builder (or by
  `just host-build` for the phase-1 sanity check).

## Phases

1. **Host sanity** (`just host-build`): inside the devShell, symlink
   `.flake-inputs/poc-lib -> ../upstream`, then `go build && ./result-host`.
2. **Nix build via buildGoModule** (`just nix-build`): build via stock
   nixpkgs `buildGoModule`. The derivation's `preBuild` does the symlink
   to `${pocLibSrc}` (the flake input's /nix/store path).
3. **Nix build via buildGoApplication** (`just nix-build-via-gomod2nix`):
   the same pattern via the fork's `buildGoApplication`. Surfaces a
   structural mismatch — see Findings.

## Findings

### Phase 1: PASS

Bare `go build` accepts the sentinel pseudo-version
`v0.0.0-00010101000000-000000000000` and resolves `replace =>
./.flake-inputs/poc-lib` through the symlink to `../upstream` without
complaint. No network, no `go.sum` entry needed for the replaced module.

### Phase 2: PASS with two non-default knobs

`buildGoModule` works *if and only if*:

1. `vendorHash = null` **and** `proxyVendor = true`. The `proxyVendor`
   flag suppresses buildGoModule's auto-appending of `-mod=vendor` to
   `GOFLAGS` (see
   `nixpkgs/pkgs/build-support/go/module.nix` line ~232). Without it, Go
   demands a `vendor/modules.txt` that doesn't exist.
2. `subPackages = ["."]`. Without it, buildGoModule's subPackage
   auto-discovery walks into `./upstream/` (a different Go module) and
   `./.flake-inputs/poc-lib/` (the symlinked replace target, also a
   different module) and fails with "main module does not contain
   package …".

With both, the binary builds and prints `FLAKE_INPUT_OK_v1`. The
preBuild-driven symlink `ln -sfn ${pocLibSrc} .flake-inputs/poc-lib`
fully works.

### Phase 3: FAIL — structural mismatch with `buildGoApplication`

The fork's `buildGoApplication` (in
`pkgs/build-support/gomod2nix/default.nix`) already handles local-path
replaces by symlinking them into `vendor/<module>` (lines 198-205):

```nix
mkdir -p $(dirname vendor/${name})
ln -s ${pwd + "/${value.path}"} vendor/${name}
```

The expression `pwd + "/${value.path}"` is evaluated at **nix-eval
time**: it constructs a nix path that must exist in the source tree
because nix attempts to import it into the store. For our pattern,
`value.path = "./.flake-inputs/poc-lib"`, which is gitignored and
created at *build time* by `preBuild`. Result:

```
error: Path 'zz-pocs/goflake-poc/.flake-inputs/poc-lib' in the
repository "…" is not tracked by Git.
```

There is no `proxyVendor`-equivalent escape hatch on `buildGoApplication`
and no way to defer the symlink to a build phase. To support the bridge
pattern, `buildGoApplication` would need a new arg that accepts flake
input store paths directly instead of relying on relative paths — this is
exactly the `goFlakeInputs` proposal in
`docs/features/0001-numtide-go2nix-overlay-builder.md` (Bridge to Flake
Inputs section).

## What this proves

- **The flake-input-bridge pattern is structurally sound**: Go itself
  has no problem with a sentinel `require` + local-path `replace` + a
  build-time-populated symlink. Phase 1 confirms this in isolation;
  phase 2 confirms it inside a nix sandbox via `buildGoModule`.
- **The pattern works with stock nixpkgs today** via `buildGoModule` +
  `proxyVendor = true` + `subPackages = ["."]` + a `preBuild` symlink.
- **The fork's `buildGoApplication` needs a new arg** to participate.
  The shape is sketched in the FDR (`goFlakeInputs`); this POC supplies
  the concrete failure mode that motivates it.
