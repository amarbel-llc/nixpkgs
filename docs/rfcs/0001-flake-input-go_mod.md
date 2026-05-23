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

(filled in Task 4)

## Source filtering: `goSourceFilter`

(filled in Task 5)

## Consumer convention: `gomod.nix` colocation

(filled in Task 6)

## Multi-producer closures: `follows` + passthru inheritance

(filled in Task 7)

## Limitations

(filled in Task 8)

## Open questions

(filled in Task 8)

## References

(filled in Task 8)
