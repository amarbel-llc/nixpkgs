---
status: exploring
date: 2026-05-23
promotion-criteria: |
  exploring → proposed: `mkGoPkgs` helper lands in this fork's overlay
  (alongside `buildGoApplication` / `mkGoEnv`), AND at least one
  producer repo in the fork — most likely `amarbel-llc/purse-first`,
  since `dagnabit` lives there — commits to exposing
  `packages.${system}.go-pkgs` per this convention.

  proposed → experimental: a consumer (most likely `amarbel-llc/madder`)
  wires `goFlakeInputs` to a producer's `go-pkgs` flake output and
  builds end-to-end successfully via `buildGoApplication`.

  experimental → testing: empirical comparison against the current
  dev-time-checked-in pattern is captured — does eliminating
  checked-in facade source trees (e.g. madder's
  `go/pkgs/<facade>/main.go` files) reduce contributor friction
  without measurably slowing builds? Numbers recorded in this FDR.

  testing → accepted: at least two producers and one downstream
  consumer carry this convention for one release cycle without
  reverting, and the dev-time-checked-in pattern can be retired in
  those repos.
---

# go-pkgs producer convention + middleware

## Problem Statement

Cross-flake Go-module composition needs two halves: a consumer mechanism
(how does a downstream Go module *receive* a flake input as a Go
dependency?) and a producer mechanism (how does an upstream flake
*expose* its Go source — possibly including codegen output — as a flake
output the consumer can reach for?).

[FDR-0003](./0003-bridge-go-flake-inputs.md) covered the consumer
half via the `goFlakeInputs` argument to `buildGoApplication` and
`mkGoEnv`. This FDR covers the producer half. Without a convention,
each producer invents an ad-hoc flake output name and shape, and
consumers can't wire `goFlakeInputs` without per-producer knowledge —
the lockstep-drift class would just relocate from `go.mod` /
`gomod2nix.toml` / `flake.lock` to "where does `inputs.foo`'s Go source
live?"

The convention also needs to accommodate codegen middleware. The fork's
`amarbel-llc/purse-first:cmd/dagnabit/` tool currently generates Go
facade source trees at dev time, with output checked into git. The
direction this fork is heading is moving that work into the Nix build
path — at which point the producer's flake output is no longer "the
source tree on disk" but "the source tree after running dagnabit (and
possibly other passes)". The convention must support that future
without requiring it; producers that ship hand-written Go directly
should not have to opt into machinery they don't need.

## Interface

### Flake output naming

A Go-source-producing flake SHOULD expose its canonical Go source tree at:

```
packages.${system}.go-pkgs
```

The value MUST be a derivation (or path) whose output is a directory
containing a Go module — typically with `go.mod` at the root, importable
packages in subdirectories.

Consumers default to referencing this attribute by name when wiring
`goFlakeInputs`:

```nix
goFlakeInputs = {
  "github.com/amarbel-llc/purse-first" = inputs.purse-first.packages.${system}.go-pkgs;
};
```

Override is supported by passing any other derivation through
`goFlakeInputs.<key> = { src = inputs.foo.packages.${system}.<other-name>; }`.
The bridge has no opinion about which derivation is referenced; the
convention only standardizes the default attribute name for discovery.

### `mkGoPkgs` helper

The fork's overlay exposes `pkgs.mkGoPkgs` for producers who want a
middleware-aware wrapper:

```nix
mkGoPkgs = { src, middlewares ? [ ], goFlakeInputs ? { }, subPath ? "" }: ...
```

Arguments:

- `src` — a derivation or path containing the Go source tree.
- `middlewares` — a list of source transformations. Each middleware is a
  function `src -> src` (derivation → derivation). The pipeline is
  applied left-to-right: `foldl' (acc: mw: mw acc) src middlewares`. When
  the list is empty (default), `mkGoPkgs` returns `src` unchanged.
- `goFlakeInputs` — optional declaration of flake-input-driven Go
  dependencies that the producer itself uses. When non-empty, `mkGoPkgs`
  attaches the value to the result derivation as
  `passthru.goFlakeInputs`. Consumers of this `go-pkgs` derivation
  inherit those entries at depth-1 through the bridge's transitive
  inheritance (see [FDR-0003 § *Multi-producer closures*](./0003-bridge-go-flake-inputs.md)).
  Producers that don't themselves consume flake-input-driven deps leave
  this empty.
- `subPath` — optional subdirectory hint for tooling. The convention
  itself does not slice the tree by `subPath`; consumers control that at
  consume time via the `subPath` attribute on `goFlakeInputs` entries.

The `passthru.goFlakeInputs` attachment is the producer-side half of
the bridge's depth-1 transitive inheritance convention. A producer
that itself sources Go deps from flake inputs declares those deps once
via `mkGoPkgs`'s `goFlakeInputs` arg; downstream consumers inherit
those declarations without redeclaring them, and align shared deps
across the closure with `inputs.<producer>.inputs.<dep>.follows`
(again, see FDR-0003).

### Producers without middleware

A producer that ships hand-written Go with no codegen has two equivalent
options:

```nix
# Explicit, via helper:
packages.${system}.go-pkgs = pkgs.mkGoPkgs { src = self; };

# Direct, bypassing the helper:
packages.${system}.go-pkgs = self;
```

Both are valid. `mkGoPkgs { src = self; middlewares = [ ]; }` is the
identity transformation; calling it adds no work but signals intent.

### Producers with dagnabit codegen

The fork ships `pkgs.dagnabitExportMiddleware` as an example middleware
that runs `dagnabit export` over the source tree:

```nix
# Sketch of the middleware (lives in the fork's overlay)
dagnabitExportMiddleware = src:
  pkgs.runCommand "dagnabit-export" {
    nativeBuildInputs = [ pkgs.dagnabit ];
  } ''
    cp -r ${src} $out
    chmod -R +w $out
    cd $out
    dagnabit export
  '';
```

A producer composes:

```nix
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  middlewares = [ pkgs.dagnabitExportMiddleware ];
};
```

Dagnabit is one example. Other middlewares (other codegen tools, lint
passes, format normalizers) plug in the same way. The middleware
contract is intentionally narrow — `src -> src` — so the set of allowed
transformations stays composable.

## Examples

### Hand-written-only producer (no codegen)

```nix
# producer flake.nix
outputs = { self, nixpkgs, ... }:
  let pkgs = nixpkgs.legacyPackages.${system}; in {
    packages.${system}.go-pkgs = self;
  };
```

### Producer with dagnabit middleware (e.g. purse-first, future state)

```nix
# producer flake.nix
outputs = { self, nixpkgs, ... }:
  let pkgs = nixpkgs.legacyPackages.${system}; in {
    packages.${system}.go-pkgs = pkgs.mkGoPkgs {
      src = self;
      middlewares = [ pkgs.dagnabitExportMiddleware ];
    };
  };
```

### Producer with subPath (polyglot repo, e.g. tap)

A flake whose Go module lives at a non-root subdirectory ships the same
attribute; consumers use `subPath` to scope at the consumer side:

```nix
# producer flake.nix (e.g. amarbel-llc/tap)
packages.${system}.go-pkgs = self;   # entire repo tree

# consumer flake.nix (e.g. madder)
goFlakeInputs = {
  "github.com/amarbel-llc/tap/go" = {
    src = inputs.tap.packages.${system}.go-pkgs;
    subPath = "go";
  };
};
```

### Consumer overriding the default name

If a producer exposes multiple Go output flavors, the consumer
references the variant explicitly:

```nix
goFlakeInputs = {
  "github.com/example/lib" = {
    src = inputs.example.packages.${system}.go-pkgs-minimal;
  };
};
```

### Producer that itself sources Go deps from flake inputs

A producer whose own Go module depends on another fork's flake-input
declares that dep through `mkGoPkgs`'s `goFlakeInputs` arg.
`mkGoPkgs` attaches it to the result derivation as
`passthru.goFlakeInputs` so downstream consumers inherit it without
redeclaring:

```nix
# producer flake.nix (e.g. amarbel-llc/tap, future state)
outputs = { self, nixpkgs, dewey, ... }:
  let pkgs = nixpkgs.legacyPackages.${system}; in {
    packages.${system}.go-pkgs = pkgs.mkGoPkgs {
      src = self;
      goFlakeInputs = {
        "github.com/amarbel-llc/purse-first/libs/dewey" = dewey;
      };
    };
  };

# consumer flake.nix (e.g. amarbel-llc/madder)
inputs = {
  dewey.url = "github:amarbel-llc/purse-first/libs/dewey";
  tap = {
    url = "github:amarbel-llc/tap";
    inputs.dewey.follows = "dewey";  # align tap's dewey with madder's
  };
};

# in the buildGoApplication call:
goFlakeInputs = {
  "github.com/amarbel-llc/tap/go" = {
    src = inputs.tap.packages.${system}.go-pkgs;
    subPath = "go";
  };
  # No explicit dewey entry — inherited from tap's passthru.goFlakeInputs.
  # With the follows above, the inherited entry resolves to the same
  # dewey input madder already has.
};
```

This is the depth-1 transitive inheritance the bridge supports. See
[FDR-0003 § *Multi-producer closures*](./0003-bridge-go-flake-inputs.md)
for the consumer-side mechanics and the `follows` alignment pattern.

## Limitations

- **Multi-module repos.** A flake exposing several distinct Go modules
  cannot consolidate them under a single `packages.${system}.go-pkgs`.
  Naming for additional modules is left open; a plausible future
  convention is `go-pkgs-<module-name>` (e.g. `go-pkgs-server`,
  `go-pkgs-client`). When the first multi-module producer arrives, that
  naming will be settled in this FDR or a successor.

- **Middleware ordering.** Composition is left-to-right via `foldl'`.
  Producers MUST order middleware according to data-flow dependencies
  (e.g. codegen before formatters, formatters before linters).
  Out-of-order pipelines may succeed but produce inconsistent outputs;
  there is no built-in dependency resolution.

- **`subPath` does not slice middleware input.** Middlewares operate on
  the full `src` derivation. If a middleware should only run against a
  subtree of the producer's repo, that's the middleware's responsibility
  to handle internally (e.g. `cd $out/go && dagnabit export`). The
  convention does not push `subPath` semantics into the middleware
  contract because that would couple the producer and consumer slicing
  decisions.

- **Per-package caching is not addressed.** This FDR defines the *shape*
  of producer output; cache reuse at Go-package granularity (e.g. when
  one facade rotates, other facades stay cached in downstream builds) is
  the concern of [FDR-0001](./0001-numtide-go2nix-overlay-builder.md)'s
  numtide go2nix evaluation. The two FDRs compose: this one delivers
  generated source trees, FDR-0001's eventual work caches the resulting
  package compilations.

- **No producer has adopted yet.** Status is `exploring`. The
  promotion-criteria above name purse-first as the likely first
  adopter (since dagnabit lives there) and madder as the likely first
  consumer. Until a producer actually commits to the convention,
  refinements to the helper signature or middleware contract remain on
  the table.

## More Information

- [FDR-0001](./0001-numtide-go2nix-overlay-builder.md) — the
  cross-flake codegen motivation that triggered the need for a producer
  convention. FDR-0001 frames *why* generated Go source should live in a
  Nix derivation; this FDR is the *shape* that derivation takes.
- [FDR-0003](./0003-bridge-go-flake-inputs.md) — the consumer-side
  mechanism (`goFlakeInputs`). This FDR is the producer-side
  counterpart. Together they form the end-to-end story for sourcing Go
  modules from flake inputs.
- Current dagnabit invocation in `amarbel-llc/madder`: dev-time only,
  output checked into git (`go/pkgs/<facade>/main.go` files tagged
  `// Code generated by dagnabit; DO NOT EDIT`). Adoption of this
  convention shifts that to build-time and removes the checked-in
  artifacts.
- `amarbel-llc/purse-first:cmd/dagnabit/` — the dagnabit CLI itself.
  Its `export` subcommand is the codegen pass that
  `dagnabitExportMiddleware` wraps.
