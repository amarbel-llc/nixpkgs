mkGoPkgs(7) ["amarbel-llc/nixpkgs"]

# NAME

mkGoPkgs - canonical producer-side helper for the flake-input-go_mod protocol

# SYNOPSIS

```
inherit (pkgs.mkGoPkgs { src = self; }) go-pkgs go-pkgs-test;

packages.${system} = {
  inherit go-pkgs go-pkgs-test;
};
```

# DESCRIPTION

*pkgs.mkGoPkgs* is the canonical entry point for the producer side of
the flake-input-go_mod protocol (RFC 0001). It returns the two flake
outputs the protocol mandates from a single call: a prod-shape
*go-pkgs* (excludes test files and testdata fixtures) and a
test-superset *go-pkgs-test*.

Both outputs are real derivations (*lib.isDerivation* true) and
therefore pass *nix flake check*'s schema gate (see amarbel-llc/nixpkgs#44
for the gate that bare *goSourceFilter* / bare *self* / *self.outPath*
all fail).

# ARGUMENTS

- *src* — REQUIRED. A path or derivation containing the Go source
  tree. For polyglot repos with the Go module under a subdirectory,
  pass *self + "/go"*.
- *name* — OPTIONAL explicit override for the output store-path
  prefix. When omitted, falls through (in order) to *src.name* (when
  *src* is a cleanSourceWith-like attrset), then to the last path
  element of the *module* directive in *${src}/go.mod*, then to
  *"source"*. Adopters with polyglot layouts (*src = self + "/go"*)
  typically set *name* explicitly to get a repo-prefixed store path
  (otherwise the inference yields just *"go"*). See
  amarbel-llc/nixpkgs#49.
- *extras* — OPTIONAL list of POSIX extended-regex strings added to
  the keep-set of *both* outputs. Use for files relevant to both
  prod and test builds (e.g. embedded asset directories, top-level
  config files referenced by *//go:embed*).
- *testExtras* — OPTIONAL list of POSIX extended-regex strings added
  only to *go-pkgs-test*. Use for fixtures that live outside the
  default *testdata* convention.

# OUTPUTS

*go-pkgs* is the prod shape. It contains all Go source files except
those ending in \_test.go; the module files (go.mod, go.sum,
gomod2nix.toml) matched by basename anywhere in the tree (except
under testdata), so go.work-based workspaces' child module files
survive; the workspace files (go.work, go.work.sum) at the source
root; and whatever paths *extras* additionally matches. Downstream
prod consumers bridge against this output by default.

*go-pkgs-test* is the test superset. It contains everything in
*go-pkgs*, plus test files (those ending in \_test.go), plus
testdata directory contents at any depth (matched both root-anchored
and nested, so single-module-at-root and subdirectory layouts both
work), plus whatever paths *testExtras* additionally matches. Used
for self-consumption (a producer building itself from its own
published artifact, exercising its own tests) and for downstream
consumers that need the producer's tests against the bridged source.

# SELF-CONSUMPTION

A producer SHOULD point its own *buildGoApplication*'s *src* and
*pwd* at its *go-pkgs-test* output:

```
let
  goPkgs = pkgs.mkGoPkgs { src = self; };
in {
  packages.${system} = {
    inherit (goPkgs) go-pkgs go-pkgs-test;
    default = pkgs.buildGoApplication {
      pname = "my-app";
      src = goPkgs.go-pkgs-test;
      pwd = goPkgs.go-pkgs-test;
      modules = ./gomod2nix.toml;
      # checkPhase runs `go test ./...` against the filtered tree —
      # contract test that catches publish-but-broken cases for
      # downstream consumers.
    };
  };
}
```

A producer that does not self-consume can publish a *go-pkgs-test*
that subtly fails downstream (missing a fixture, an embed asset, a
workspace file) and never notice. Self-consumption turns "the
published tree is valid" from a documentation claim into a build
invariant. See *RFC 0001 § Self-consumption SHOULD* for the
normative recommendation and madder#212 for the originating adopter
experience.

The *modules* argument is a producer-discretion call:

- *modules = ./gomod2nix.toml* (worktree-relative): evaluates faster
  at flake-eval time
- *modules = "${goPkgs.go-pkgs-test}/gomod2nix.toml"*
  (filtered-tree-relative): stronger contract; drift between the
  worktree's lockfile and the filter's view becomes structurally
  impossible

Either form satisfies the protocol.

# gomod.nix CONVENTION

*mkGoPkgs* is typically called from a *gomod.nix* file (the Nix
interface to *go.mod*) that captures the flake's Go-side surface:

```
# gomod.nix — pure producer
{ pkgs, src }:
pkgs.mkGoPkgs {
  inherit src;
  extras = [ ];
  testExtras = [ ];
}
```

```
# gomod.nix — mixed producer + consumer
{ pkgs, src, tap, tommy, system }: {
  goPkgs = pkgs.mkGoPkgs { inherit src; };
  goFlakeInputs = {
    "github.com/amarbel-llc/tap/go" = {
      src = tap.packages.${system}.go-pkgs;
      subPath = "go";
    };
    "github.com/amarbel-llc/tommy" = {
      src = tommy.packages.${system}.go-pkgs;
    };
  };
}
```

See *RFC 0001 § The gomod.nix convention* for the normative spec.

# RELATIONSHIP TO goSourceFilter

*pkgs.goSourceFilter* is the lower-level primitive that filters a
single source tree according to a flat regex keep-set.
*pkgs.mkGoPkgs* builds on top of the same *builtins.path* +
*runCommand* shape but applies the dual-output convention from RFC
0001's producer interface (prod vs. test split, plus self-consumption
contract). Producers SHOULD use *mkGoPkgs*; *goSourceFilter* remains
available for single-output cases and as an open building block.

# LIMITATIONS

- *extras* and *testExtras* use regex, not globs.
- Empty directories with no matching descendants are preserved in
  the filtered output (a consequence of always-traversing
  directories); this is harmless for *go build* but slightly inflates
  the output NAR.
- The middleware-aware variant (*mkGoPkgsWithMiddleware*, provisional
  name) is **not yet implemented**. Producers needing codegen today
  inline middleware steps in their flake and publish the result as
  *go-pkgs* / *go-pkgs-test* directly. See *RFC 0001 § Producers with
  codegen (deferred)*.
- *go.work* / *go.work.sum* are matched at the source root only.
  Workspaces with deeply-nested *go.work* files (which Go does not
  support) are not supported.
- Multi-module repos with multiple distinct Go modules at sibling
  paths can publish only one pair of *go-pkgs* / *go-pkgs-test*
  outputs. A naming convention for additional pairs
  (*go-pkgs-<module-name>*) is unspecified.

# SEE ALSO

*gomod2nix*(7), *goSourceFilter*(7), *lib.sources.sourceByRegex*,
*docs/rfcs/0001-flake-input-go_mod.md*.
