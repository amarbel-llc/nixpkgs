---
status: draft
date: 2026-05-23
promotion-criteria: |
  draft → proposed: at least one producer in this fork adopts `pkgs.goSourceFilter`
  for its `packages.${system}.go-pkgs` flake output; FDR-0003 and FDR-0004 are
  thinned to reference this RFC for normative spec.

  proposed → experimental: tommy (or another producer) publishes
  `packages.${system}.go-pkgs = pkgs.goSourceFilter { src = self; }` and a
  consumer (madder) builds successfully against the filtered output.

  experimental → testing: lazy-trees interaction and mkGoEnv parity for the
  filter are empirically verified.

  testing → accepted: at least two producers carry filtered `go-pkgs` for a
  release cycle without reverting to bare `self`.
---

# RFC 0001 — flake-input-go_mod protocol

## Conventions

The keywords MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD
NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be
interpreted as described in RFC 2119 and RFC 8174 when, and only when,
they appear in all capitals.

## Abstract

The flake-input-go_mod protocol specifies a Nix mechanism for
cross-flake Go module composition. It has two halves that compose
end-to-end: a consumer half (`goFlakeInputs`, an argument to
`buildGoApplication` and `mkGoEnv`) and a producer half
(`packages.${system}.go-pkgs`, a conventional flake output, optionally
constructed via `mkGoPkgs`). The protocol replaces the three-place
lockstep — `go.mod` pseudo-version, `gomod2nix.toml` NAR hash, and
`flake.lock` rev — with a single source of truth: the flake input's
rev as recorded in `flake.lock`. The consumer's merged `go.mod`
synthesizes the appropriate `replace` directive at eval time; the
producer publishes a stable, optionally-filtered source tree at the
conventional attribute.

## Terminology

For the purposes of this RFC:

- **Producer** — a flake whose output is a Go source tree intended for
  consumption by other flakes. A producer MUST expose its canonical Go
  source tree as `packages.${system}.go-pkgs`.
- **Consumer** — a flake that depends on one or more producers' Go
  source trees through Nix flake inputs. A consumer MUST declare those
  dependencies through `goFlakeInputs`.
- **Bridge** — the eval-time merge step that combines the consumer's
  organic `go.mod` with synthetic `replace` directives derived from
  `goFlakeInputs`. The bridge implementation lives in this fork's
  `buildGoApplication` and `mkGoEnv`.
- **Middleware** — a function `src -> src` (derivation to derivation)
  that transforms a Go source tree. Middlewares compose left-to-right
  in the `mkGoPkgs.middlewares` pipeline. Examples include source
  filters, codegen passes, and format normalizers.
- **`goFlakeInputs`** — the consumer-side bridge argument. An attrset
  mapping Go module paths to flake-input derivations (or `{ src;
  subPath; }` records). Specified normatively in §
  *Consumer interface: `goFlakeInputs`*.
- **`go-pkgs`** — the conventional flake output attribute name for a
  producer's Go source tree. Specified normatively in §
  *Producer interface: `packages.${system}.go-pkgs` and `mkGoPkgs`*.
- **`gomod.nix`** — the conventional colocation file on the consumer
  side that lifts the `goFlakeInputs` attrset out of the
  `buildGoApplication` call. Specified normatively in §
  *Consumer convention: `gomod.nix` colocation*.

## Protocol overview

The protocol has two complementary halves. On the producer side, a
flake exposes its Go source tree as `packages.${system}.go-pkgs` — a
derivation whose output is a directory containing a Go module
(`go.mod` at the root, importable packages in subdirectories). On the
consumer side, a flake declares which producers it depends on by
passing `goFlakeInputs` to `buildGoApplication` and `mkGoEnv`; the
bridge merges synthetic `replace` directives into the consumer's
`go.mod` at Nix eval time, pointing each declared Go module path at
the producer's `go-pkgs` store path.

The protocol exists to close the lockstep-drift class. Without the
bridge, cross-repo Go composition in this fork requires editing three
places in lockstep: `go.mod`'s pseudo-version, `gomod2nix.toml`'s NAR
hash, and `flake.lock`'s rev of the sibling-module input. When any of
these drifts, the build still succeeds — each layer is internally
consistent — but the binary runs against the wrong version of the
sibling. The bridge collapses the lockstep so that only the flake
input rev matters: the merged `go.mod`'s `replace` points at the new
store path automatically, and `gomod2nix.toml` only tracks the
*organic* (non-bridged) surface.

## Consumer interface: `goFlakeInputs`

Implementations MUST accept a `goFlakeInputs` argument on
`buildGoApplication` and `mkGoEnv`. The argument is an attrset mapping
Go module paths to source derivations.

### Schema

```nix
goFlakeInputs :: AttrSet (Derivation | { src :: Derivation; subPath :: String })
```

Each entry's key MUST be a fully qualified Go module path (e.g.
`github.com/amarbel-llc/dodder`). Each entry's value MUST be either:

- a derivation whose output is a Go module source tree rooted at the
  derivation's top level; or
- a record `{ src = <derivation>; subPath = <string>; }`, where `src`
  is such a derivation and `subPath` is a directory within `src` that
  contains the Go module's `go.mod`.

Implementations MUST NOT accept other value shapes (e.g. raw store
paths, URLs, or fetcher specifications); callers wanting non-flake
sources MUST wrap them in a derivation first.

### Merge primitive

Implementations MUST merge `goFlakeInputs` into the consumer's `go.mod`
by injecting a `replace` directive per entry, semantically equivalent
to `go mod edit -replace=<module>=<store-path>`. The merge MUST happen
at Nix eval time, in parallel to the organic `goMod.replace` entries
that `mkVendorEnv` already processes. Synthetic entries MUST take
priority over any organic `require` pseudo-version for the same module
path: the organic `require` line becomes vestigial and only needs to
remain syntactically present so Go's parser is satisfied.

Implementations MUST NOT require that the consumer's source filesystem
contain a placeholder directory matching the replace target. Synthetic
entries are derivation references at eval time; the value of an entry
is passed through to the merged `go.mod` as the relevant store path
directly, not reconstructed via `pwd + "/${value.path}"`. (This is the
concrete blocker the FDR-0003 POC identified at
`pkgs/build-support/gomod2nix/default.nix:198-205`; the protocol
forbids that shape.)

### Inline declaration

`goFlakeInputs` MUST be passed inline as a builder argument. The
protocol does not define any out-of-band declaration mechanism (no
separate `flake-go-inputs.toml` manifest, no environment-variable
escape hatch). The single source of truth for synthetic versions is
the flake input's rev as recorded in `flake.lock`.

### `mkGoEnv` parity

Implementations MUST apply identical merge semantics in `mkGoEnv` as
in `buildGoApplication`. A consumer's `nix develop` shell MUST see the
same module graph as `nix build`. Implementing only the build-side
silently reintroduces lockstep drift through the back door: editors
and language servers in the devshell see one set of replace targets
while the build sees another.

### Out-of-Nix builds

The protocol does NOT support `go build` invocations outside Nix. A
consumer MUST run Go work through `nix develop` or `nix build`. The
merged `go.mod` is materialized into the build sandbox at
`buildGoApplication` time and is not written back to the consumer's
working tree. Editor and language-server workflows that parse `go.mod`
directly may need the merged form materialized into the workspace;
that materialization step is a non-normative follow-up.

### Example

```nix
{ pkgs, inputs, ... }:
let
  madder = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    subPackages = [ "cmd/madder" ];
    modules = ./gomod2nix.toml;
    goFlakeInputs = {
      "github.com/amarbel-llc/dodder" = inputs.dodder;
      "github.com/amarbel-llc/tap/go" = {
        src = inputs.tap.packages.${pkgs.system}.go-pkgs;
        subPath = "go";
      };
    };
  };
in {
  packages.default = madder;
}
```

The consumer's `gomod2nix.toml` MUST NOT carry entries for modules
declared in `goFlakeInputs`; `go.mod` retains the `require` line
(Go's parser needs *some* version) with a sentinel pseudo-version such
as `v0.0.0-00010101000000-000000000000`.

## Producer interface: `packages.${system}.go-pkgs` and `mkGoPkgs`

### Flake output naming

A Go-source-producing flake SHOULD expose its canonical Go source tree
as the flake output:

```
packages.${system}.go-pkgs
```

The value MUST be a derivation (or path coercible to one) whose output
is a directory containing a Go module: a `go.mod` at the root (or at
a subdirectory addressable via the consumer's `subPath`) and the
importable packages of that module.

Consumers reference this attribute by name when wiring `goFlakeInputs`:

```nix
goFlakeInputs = {
  "github.com/amarbel-llc/purse-first" =
    inputs.purse-first.packages.${system}.go-pkgs;
};
```

A producer MAY expose additional Go output variants under other
attribute names (e.g. `go-pkgs-minimal`, `go-pkgs-server`). Consumers
that need a non-default variant MUST reference it explicitly via the
`{ src = ...; }` record form on the `goFlakeInputs` entry; the
protocol places no constraint on those variant names and standardizes
only the default attribute for discovery.

### `mkGoPkgs` helper

The fork's overlay SHOULD expose `pkgs.mkGoPkgs` as a
middleware-aware producer-side wrapper:

```nix
mkGoPkgs = {
  src,
  middlewares ? [ ],
  goFlakeInputs ? { },
  subPath ? "",
}: ...
```

> **Implementation status:** this RFC specifies the `mkGoPkgs`
> interface; the implementation is deferred to a future change. Until
> the helper lands in the overlay, producers MAY use
> `pkgs.goSourceFilter` standalone (see § *Source filtering:
> `goSourceFilter`*) as the value of `packages.${system}.go-pkgs`, or
> set `go-pkgs = self` directly when no filtering or codegen is
> needed.

Arguments:

- `src` — a derivation or path containing the Go source tree.
  REQUIRED.
- `middlewares` — a list of source transformations. Each middleware
  MUST be a function `src -> src` (derivation to derivation). The
  pipeline MUST be applied left-to-right as
  `foldl' (acc: mw: mw acc) src middlewares`. When the list is empty
  (the default), `mkGoPkgs` MUST return `src` unchanged.
- `goFlakeInputs` — optional declaration of flake-input-driven Go
  dependencies that the producer itself uses. When non-empty,
  `mkGoPkgs` MUST attach the value to the result derivation as
  `passthru.goFlakeInputs`. Downstream consumers of the resulting
  `go-pkgs` derivation inherit those entries at depth-1 through the
  bridge's transitive inheritance (see § *Multi-producer closures:
  `follows` + passthru inheritance*).
- `subPath` — optional subdirectory hint for tooling. The convention
  itself MUST NOT slice the tree by `subPath`; consumers control
  per-consumer slicing through the `subPath` attribute on
  `goFlakeInputs` entries.

### Producers without middleware

A producer that ships hand-written Go with no codegen and no source
filtering needs MAY use either of:

```nix
# Explicit, via helper (signals intent):
packages.${system}.go-pkgs = pkgs.mkGoPkgs { src = self; };

# Direct, bypassing the helper:
packages.${system}.go-pkgs = self;
```

Both are valid; `mkGoPkgs { src = self; middlewares = [ ]; }` is the
identity transformation. The bare-`self` form is RECOMMENDED only for
trivially small repos where the build closure tax of non-Go file edits
is negligible; otherwise, producers SHOULD use
`pkgs.goSourceFilter { src = self; }` to scope the closure to
Go-relevant files (see § *Source filtering: `goSourceFilter`*).

### Producers with middleware

A producer that runs codegen (e.g. via the future
`pkgs.dagnabitExportMiddleware`) or otherwise transforms its source
composes the pipeline via `mkGoPkgs`:

```nix
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  middlewares = [
    pkgs.goSourceFilterMiddleware
    pkgs.dagnabitExportMiddleware  # example future middleware
  ];
};
```

The middleware contract is intentionally narrow — `src -> src` — so
the set of allowed transformations stays composable. Producers MUST
order middlewares according to data-flow dependencies; the convention
does not provide automatic dependency resolution.

## Source filtering: `goSourceFilter`

### Rationale

A producer that uses bare `self` as its `packages.${system}.go-pkgs`
value cache-couples every downstream consumer's build closure to
every file in the producer's repository — including README edits,
scdoc man-page changes, justfile recipes, `.github/` workflow tweaks,
and any other non-Go file. Each such edit changes the producer's
store path, invalidates the consumer's vendor FOD, and forces a
rebuild that has no semantic relationship to the change.

A producer SHOULD scope its `go-pkgs` output to Go-relevant files.
Producers that already maintain a `cleanSourceWith`-style filter (for
their own builds) SHOULD reuse that filter for `go-pkgs`. Producers
without a pre-existing filter MAY use `pkgs.goSourceFilter` for the
common case.

### `goSourceFilter` interface

```nix
goSourceFilter :: { src :: Path; extras ? [ String ]; } -> Source
```

Arguments:

- `src` — REQUIRED. A path or derivation containing the Go source
  tree.
- `extras` — OPTIONAL. A list of POSIX extended-regex strings (default:
  empty) that augment the default keep-set.

`goSourceFilter` MUST be implemented as a `lib.cleanSourceWith` filter
(the underlying primitive `lib.sources.sourceByRegex` builds on top of)
where directories are always traversed and regex patterns are matched
against the source-tree-relative path of each regular file. The output
MUST be a `cleanSourceWith`-filtered view of `src`.

### Default keep-set

`goSourceFilter` MUST keep, at minimum, the following files (matched
against the source-tree-relative path of each file):

- `.*\.go$` — any Go source file.
- `^go\.mod$` — the module manifest.
- `^go\.sum$` — the module checksum file.
- `^gomod2nix\.toml$` — the `gomod2nix` lockfile.

All other files MUST be dropped unless matched by an entry in
`extras`.

### `extras` semantics

`extras` entries MUST be POSIX extended-regex strings, matched against
the source-tree-relative path of each file (consistent with
`builtins.match` semantics). They are
NOT glob patterns; the nixpkgs stdlib does not ship glob matching, and
`goSourceFilter` does not introduce a new syntax on top.

Examples:

```nix
# Keep the doc/ subtree
extras = [ "^doc/.*" ];

# Keep a single root file
extras = [ "^VERSION$" ];

# Keep all *.tmpl files
extras = [ ".*\\.tmpl$" ];

# Combine
extras = [ "^doc/.*" "^VERSION$" ".*\\.tmpl$" ];
```

### Store-path naming

`goSourceFilter` MUST preserve `src.name`. The resulting store path is
named identically to the input `src` (this is `cleanSourceWith`'s
default behavior). Producers that want a more diagnostic name (e.g.
`${src.name}-go-source`) MAY wrap the output:

```nix
lib.cleanSourceWith {
  name = "${src.name}-go-source";
  src = pkgs.goSourceFilter { inherit src; };
}
```

### `goSourceFilterMiddleware`

The fork's overlay SHOULD also expose `pkgs.goSourceFilterMiddleware`,
a 1-line `src -> src` wrapper around `goSourceFilter`:

```nix
goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
```

It exists so the filter composes naturally into the
`mkGoPkgs.middlewares` pipeline without forcing producers to write the
closure themselves:

```nix
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  middlewares = [
    pkgs.goSourceFilterMiddleware
    # ... other middlewares ...
  ];
};
```

## Consumer convention: `gomod.nix` colocation

### Recommended shape

When a consumer bridges two or more Go module deps through
`goFlakeInputs`, the attrset SHOULD be lifted into a sibling file
named `gomod.nix` (or, for polyglot repos that keep their Go module
under a subdirectory, `go/gomod.nix`). Single-dep bridges MAY remain
inline in the `buildGoApplication` call; the colocation convention
exists to reduce duplication and surface drift, both of which only
matter at multi-dep scale.

`gomod.nix` MUST be a function from flake inputs (plus `system`) to an
attrset that matches the `goFlakeInputs` schema defined in §
*Consumer interface: `goFlakeInputs`*. The file MUST NOT depend on
state outside its arguments; it MUST be importable from any
`buildGoApplication` or `mkGoEnv` call in the same flake.

### Example

```nix
# go/gomod.nix
{ tap, tommy, system }: {
  "github.com/amarbel-llc/tap/go" = {
    src = tap;
    subPath = "go";
  };
  "github.com/amarbel-llc/tommy" = {
    src = tommy.packages.${system}.go-pkgs;
  };
}
```

Call sites then thread the imported attrset through every Go builder
call:

```nix
# flake.nix
let
  goFlakeInputs = import ./go/gomod.nix {
    inherit (inputs) tap tommy;
    inherit system;
  };
in {
  packages.${system}.default = pkgs.buildGoApplication {
    pname = "madder";
    src = ./.;
    pwd = ./.;
    modules = ./gomod2nix.toml;
    inherit goFlakeInputs;
  };

  devShells.${system}.default = pkgs.mkShell {
    inputsFrom = [
      (pkgs.mkGoEnv {
        pwd = ./.;
        inherit goFlakeInputs;
      })
    ];
  };
}
```

### Threading

Every `buildGoApplication` and `mkGoEnv` call that consumes the
consumer's `gomod2nix.toml` MUST receive the same `goFlakeInputs`
value. The recommended idiom is `inherit goFlakeInputs;` at each call
site, with the single `goFlakeInputs` binding shared from the
top-level `let`. Missing call sites silently resurrect lockstep drift:
the build sees one set of replace targets, the devshell sees another.
See issue
[amarbel-llc/nixpkgs#41](https://github.com/amarbel-llc/nixpkgs/issues/41)
for proposed lint coverage of this failure mode.

### Why this convention exists

Three reasons motivate the colocation pattern:

1. **Discoverability.** `cat go/gomod.nix` answers "which sibling Go
   modules does this consumer bridge?" without scanning the flake
   outputs.
2. **Drift surface.** With every `buildGoApplication` and `mkGoEnv`
   call importing the same `gomod.nix`, divergence between call sites
   becomes a single `grep` target: any call lacking
   `inherit goFlakeInputs;` is the bug.
3. **Symmetry with the producer side.** Producers publish one
   `packages.${system}.go-pkgs` attribute; consumers publish one
   `gomod.nix` file. The protocol's two halves each have a single
   conventional location, which makes adoption mechanical: producers
   know where to point inputs, consumers know where to declare them.

## Multi-producer closures: `follows` + passthru inheritance

When a consumer depends on multiple flake inputs that themselves share
a transitive Go dependency, two mechanisms keep the resulting closure
coherent: Nix flake `follows` for input alignment, and depth-1
`passthru.goFlakeInputs` inheritance for declaration reuse.

### Shared transitive deps: align with `follows`

A consumer that pulls both `tap` and `dewey` as flake inputs — and
where `tap` itself depends on `dewey` — SHOULD anchor `tap`'s view of
dewey to the consumer's own input via `follows`:

```nix
inputs = {
  dewey.url = "github:amarbel-llc/purse-first/libs/dewey";
  tap = {
    url = "github:amarbel-llc/tap";
    inputs.dewey.follows = "dewey";   # tap's dewey is now madder's dewey
  };
};
```

`follows` is Nix's existing flake-level alignment mechanism; the
bridge MUST NOT replicate or enforce version policy on top of it.
Go's module-path encoding (`X` vs `X/v2`) already makes cross-major
substitution structurally impossible, and within-cohort version
mismatches surface as ordinary compile errors via `-mod=vendor`. The
build is the authoritative check; `follows` ensures the inputs align
before the build even runs.

### Producer-side passthru inheritance

A producer flake that itself uses `goFlakeInputs` to source its Go
modules MAY expose those declarations to consumers via
`passthru.goFlakeInputs` on its `go-pkgs` derivation. The producer
SHOULD attach this passthru via `mkGoPkgs`'s `goFlakeInputs` argument
(see § *Producer interface: `packages.${system}.go-pkgs` and
`mkGoPkgs`*); the helper performs the attachment automatically.

Implementations of the bridge MUST read each direct flake-input's
`passthru.goFlakeInputs` and union the entries into the consumer's
merged map at depth-1. Consumer-declared entries MUST win on conflict:
when a Go module path appears both in the consumer's own
`goFlakeInputs` and in an inherited passthru, the consumer's entry
takes priority.

When combined with `follows` alignment above, inherited entries
naturally resolve to the same flake inputs the consumer already has,
with no extra declaration required:

```nix
# producer (e.g. tap)
packages.${system}.go-pkgs = pkgs.mkGoPkgs {
  src = self;
  goFlakeInputs = {
    "github.com/amarbel-llc/purse-first/libs/dewey" = inputs.dewey;
  };
};
# mkGoPkgs attaches passthru.goFlakeInputs automatically.

# consumer (e.g. madder)
goFlakeInputs = {
  "github.com/amarbel-llc/tap/go" = {
    src = inputs.tap.packages.${system}.go-pkgs;
    subPath = "go";
  };
  # The dewey entry is INHERITED from tap's passthru — no need to
  # redeclare here. With inputs.tap.inputs.dewey.follows = "dewey",
  # the inherited entry points at the consumer's dewey input.
};
```

### Depth-1 is the normative limit

The protocol fixes depth-1 as the normative inheritance limit.
Implementations MUST NOT chase `passthru.goFlakeInputs` recursively
through inherited entries. Deeper-than-one transitive resolution is
deferred to the FOD-regen path tracked at
[amarbel-llc/nixpkgs#36](https://github.com/amarbel-llc/nixpkgs/issues/36);
until that path lands, deeply nested closures resolve by the consumer
declaring each direct producer's flake input and aligning shared deps
via `follows`. The depth-1 floor is sufficient for every closure shape
the fork has surfaced so far.

## Limitations

The following limitations are known at protocol-design time. Each is
marked **open** (active gap, may be addressed by future revisions) or
**deferred** (out of scope, tracked elsewhere) with a pointer to the
relevant issue.

### Consumer side

- **Caller manages the `require` line in `go.mod`.** *(open.)* The
  consumer MUST keep a syntactically valid
  `require <module> v0.0.0-<sentinel>` entry in `go.mod` alongside
  declaring `goFlakeInputs`. Auto-injecting the `require` via
  `go mod edit -require` at eval time is a follow-up ergonomics fix;
  the bridge mechanic itself does not depend on it.

- **Transitive deps of the flake input.** *(deferred to
  [nixpkgs#36](https://github.com/amarbel-llc/nixpkgs/issues/36).)*
  Organic transitive deps come in through the producer's
  `gomod2nix.toml`, which the bridge unions with the consumer's
  (consumer wins on conflict). Flake-input-driven transitive deps are
  inherited from `passthru.goFlakeInputs` at depth-1 only (see §
  *Multi-producer closures: `follows` + passthru inheritance*).
  Deeper-than-one-level inheritance — full FOD-regen of the merged
  module set — is the dedicated tracking issue.

- **Source-only inputs assumed.** *(open.)* `goFlakeInputs` entries
  MUST be derivations whose output is a Go module source tree (own
  `go.mod`, importable packages). Pre-built binaries or non-Go outputs
  are out of scope; the bridge has no opinion about how to consume
  them.

- **No `go build` outside Nix.** *(open, by design.)* This fork's Go
  projects already require `nix develop` for the toolchain; the bridge
  preserves that constraint. Editor and language-server workflows that
  parse `go.mod` directly may need the merged form materialized into
  the workspace; the materialization step is a follow-up.

- **No interaction defined with `buildGoRace` / `buildGoCover`.**
  *(open.)* These wrappers `overrideAttrs` on a
  `buildGoApplication`-produced derivation. They SHOULD be unaffected
  by `goFlakeInputs` (the merge happens before they wrap), but this
  needs concrete verification.

- **Missing-call-site lint.** *(deferred to
  [nixpkgs#41](https://github.com/amarbel-llc/nixpkgs/issues/41).)*
  Every `buildGoApplication` and `mkGoEnv` call in a consumer that
  consumes the same `gomod2nix.toml` MUST receive the same
  `goFlakeInputs` value. There is no enforcement today; missing
  call sites silently resurrect lockstep drift.

### Producer side

- **Multi-module repos.** *(open.)* A flake exposing several distinct
  Go modules cannot consolidate them under a single
  `packages.${system}.go-pkgs`. Naming for additional modules is left
  unspecified; a plausible future convention is
  `go-pkgs-<module-name>` (e.g. `go-pkgs-server`, `go-pkgs-client`),
  to be settled in this RFC or a successor when the first multi-module
  producer arrives.

- **Middleware ordering.** *(open.)* Composition is left-to-right via
  `foldl'`. Producers MUST order middlewares according to data-flow
  dependencies (e.g. codegen before formatters, formatters before
  linters). Out-of-order pipelines may succeed but produce
  inconsistent outputs; there is no built-in dependency resolution.

- **`subPath` does not slice middleware input.** *(open.)* Middlewares
  operate on the full `src` derivation. If a middleware should only
  run against a subtree of the producer's repo, that is the
  middleware's responsibility to handle internally (e.g.
  `cd $out/go && dagnabit export`). The convention does not push
  `subPath` semantics into the middleware contract because that would
  couple producer and consumer slicing decisions.

- **Per-package caching is not addressed.** *(deferred to
  [FDR-0001](../features/0001-numtide-go2nix-overlay-builder.md).)*
  This RFC defines the *shape* of producer output; cache reuse at
  Go-package granularity (e.g. when one facade rotates, other facades
  stay cached in downstream builds) is the concern of the numtide
  go2nix evaluation. The two compose: this RFC delivers generated
  source trees, FDR-0001's eventual work caches the resulting package
  compilations.

### Source-filter side

- **Regex, not globs.** *(open, by upstream constraint.)* `extras` are
  POSIX extended-regex strings (`builtins.match` semantics) because
  nixpkgs stdlib does not ship glob matching and `goSourceFilter`
  declines to invent new syntax.

- **Store-path naming preserves `src.name`.** *(open.)* The default
  naming is documented in § *Source filtering: `goSourceFilter`* §
  *Store-path naming*. Whether `${src.name}-go-source` would be more
  diagnostic is left to the first real adoption (tommy) to surface.

- **Single-tree assumption.** *(open.)* `goSourceFilter` operates on
  `src` as a single tree. Multi-module repos with separate Go modules
  in different subdirectories need per-module filter invocations.

- **Empty directories preserved.** Because the filter unconditionally
  allows directory traversal, empty directories that have no
  matching descendants are kept in the output store path. This is
  harmless for `go build` but may slightly increase the output NAR
  size compared to a strict "drop everything unmatched" interpretation.
  *(deferred: tracked as an open question for the first downstream
  adopter to surface as load-bearing or not.)*

## Open questions

The following items are unresolved at RFC-publication time. Each will
be revisited as the protocol promotes through `proposed → experimental
→ testing`.

1. **Lazy-trees interaction.** Theory: `lib.sources.cleanSourceWith`
   only imports matching files into the store, so the filter benefit
   composes with Nix's existing source-import laziness. The interaction
   with Nix's experimental `lazy-trees` feature (Git-input lazy
   materialization) is unverified. This RFC does not assert behavior;
   verification is required before `experimental → testing` promotion.

2. **`mkGoEnv` parity for `goSourceFilter`.** The filter must apply
   identically to `mkGoEnv` calls so devshell module-graph matches
   build-time module-graph. Empirical verification is deferred until
   `mkGoPkgs` lands and the first producer adopts the filter.

3. **Store-path name preservation.** Documented behavior is "preserve
   `src.name`". Whether downstream adopters would prefer
   `${src.name}-go-source` is left to the first real adoption to
   surface; the answer changes the default but not the protocol shape.

## References

### Companion FDRs

- [FDR-0003 — Bridge Go module deps from flake inputs](../features/0003-bridge-go-flake-inputs.md).
  Source of the consumer-side problem statement, POC findings (commit
  `f99a3ff43278`, `zz-pocs/goflake-poc/`), and multi-producer-closures
  shape. Thinned to journey-only when this RFC supersedes its
  interface sections.

- [FDR-0004 — go-pkgs producer convention + middleware](../features/0004-go-pkgs-producer-convention.md).
  Source of the producer-side problem statement, the codegen-middleware
  motivation, and the `mkGoPkgs` shape exploration. Thinned to
  journey-only when this RFC supersedes its interface sections.

### Proof-of-concept

- POC commit `f99a3ff43278` — the three-phase probe of the
  `require <module> v0.0.0-<sentinel> + replace => ./.flake-inputs/<name>`
  shape at `zz-pocs/goflake-poc/`. Identified the concrete blocker
  (`pwd + "/${value.path}"` eval-time path import) that the bridge
  must avoid.

### Originating issues

- [nixpkgs#39 — `gomod.nix` convention for consumer-side goFlakeInputs](https://github.com/amarbel-llc/nixpkgs/issues/39)
  surfaced the consumer convention from madder#211 adoption.
- [nixpkgs#40 — filtered-source `go-pkgs` over bare `self`](https://github.com/amarbel-llc/nixpkgs/issues/40)
  surfaced the `goSourceFilter` need.
- [nixpkgs#41 — linter for missing `goFlakeInputs` threading](https://github.com/amarbel-llc/nixpkgs/issues/41)
  follow-up enforcement gap referenced from § *Consumer convention*.

### Tracking issues

- [nixpkgs#32 — consumer-side `goFlakeInputs` implementation](https://github.com/amarbel-llc/nixpkgs/issues/32).
- [nixpkgs#35 — `mkGoPkgs` helper and middleware contract](https://github.com/amarbel-llc/nixpkgs/issues/35).
- [nixpkgs#36 — deeper-than-one transitive resolution (FOD-regen path)](https://github.com/amarbel-llc/nixpkgs/issues/36).

### Downstream consumers

Downstream Go projects expected to evaluate against this RFC:
`dagnabit`, `madder`, `maneater`, `dodder`, `chrest`, `nebulous`, and
`tommy`.
