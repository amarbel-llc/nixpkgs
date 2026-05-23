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

`goSourceFilter` MUST be implemented in terms of
`lib.sources.sourceByRegex`, the existing nixpkgs stdlib primitive in
`lib/sources.nix`. The output MUST be a `cleanSourceWith`-filtered
view of `src`.

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
`builtins.match` and `lib.sources.sourceByRegex` semantics). They are
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

(filled in Task 7)

## Limitations

(filled in Task 8)

## Open questions

(filled in Task 8)

## References

(filled in Task 8)
