gomod2nix(7) ["amarbel-llc/nixpkgs"]

# NAME

gomod2nix - build helpers for Go applications using gomod2nix lockfiles

# SYNOPSIS

In a flake that builds a Go application:

```
pkgs = import nixpkgs { inherit system; };  # nixpkgs = "github:amarbel-llc/nixpkgs"

pkgs.buildGoApplication { ... }
pkgs.mkGoEnv { pwd = ./.; }
```

# DESCRIPTION

*amarbel-llc/nixpkgs* carries the gomod2nix build helpers natively. Flakes
that previously depended on *github:nix-community/gomod2nix* and its overlay
can drop that input entirely and use *pkgs.buildGoApplication* and
*pkgs.mkGoEnv* directly.

The public surface exposed on *pkgs* is:

- *buildGoApplication* — build a Go binary from a gomod2nix.toml lockfile
- *mkGoEnv* — create a vendor environment for devshells; propagates *go*,
  *gomod2nix* CLI, and the *go-sync-wrap* shell hook automatically
- *mkVendorEnv* — low-level: assemble a vendor/ directory from fetched modules
- *mkGoCacheEnv* — pre-warm the Go build cache as a derivation
- *gomod2nix* — the gomod2nix CLI binary (available via *mkGoEnv*; rarely
  needed explicitly)

# MIGRATING FROM nix-community/gomod2nix

## 1. Change the nixpkgs input

Replace the pinned upstream nixpkgs with the fork:

```
# Before
nixpkgs.url = "github:NixOS/nixpkgs/<pin>";

# After
nixpkgs.url = "github:amarbel-llc/nixpkgs";
```

## 2. Remove the gomod2nix flake input

Delete the *gomod2nix* input block and its *follows* entries entirely:

```
# Remove:
gomod2nix = {
  url = "github:nix-community/gomod2nix";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.follows = "utils";
};
```

Remove *gomod2nix* from the *outputs* function arguments too.

## 3. Remove the overlay

The *gomod2nix.overlays.default* overlay was the mechanism that injected
*buildGoApplication* into *pkgs*. It is no longer needed:

```
# Before
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    gomod2nix.overlays.default
    (_: _: { go = pkgs-master.go; })
  ];
};

# After
pkgs = import nixpkgs { inherit system; };
```

The *go* version override in the overlay is also gone. See *GO VERSION
SELECTION* below for how the fork handles this.

## 4. Simplify the package derivation

*buildGoApplication* is now called directly on *pkgs*:

```
# Before (via overlay)
pkgs.buildGoApplication { ... }

# After (identical call, no overlay needed)
pkgs.buildGoApplication { ... }
```

No change to the call site is required — only the overlay that made it
available is removed.

## 5. Simplify devShells with mkGoEnv

Replace explicit *go* and *gomod2nix* CLI listings with a single *mkGoEnv*
derivation. *mkGoEnv* propagates both into the shell automatically, along
with the *go-sync-wrap* hook that regenerates *gomod2nix.toml* after
*go get*, *go mod tidy*, and related commands.

```
# Before
devShells.default = pkgs.mkShell {
  packages = [
    pkgs-master.go
    gomod2nix.packages.${system}.default
    pkgs-master.gopls
    ...
  ];
};

# After
devShells.default = pkgs-master.mkShell {
  packages = [
    (pkgs.mkGoEnv { pwd = ./.; })
    pkgs-master.gopls
    ...
  ];
};
```

# GO VERSION SELECTION

*buildGoApplication* selects the Go toolchain in this order:

. Explicit *go* attribute passed to the call: *buildGoApplication { go = pkgs-master.go_1_26; ... }*
. Version declared in *go.mod* — matched against toolchains available in *pkgs*
. Default *pkgs.go*

For projects that need a specific toolchain (e.g. a release candidate or a
version not yet in the pinned nixpkgs), pass it explicitly:

```
buildGoApplication {
  go = pkgs-master.go_1_26;
  ...
}
```

To avoid two different Go versions silently appearing (one in the build, one
in the devshell), bind the toolchain to a single variable and thread it
through:

```
go = pkgs-master.go_1_26;

tommy-unwrapped = pkgs.buildGoApplication {
  inherit go;
  ...
};

devShells.default = pkgs-master.mkShell {
  packages = [
    (pkgs.mkGoEnv { pwd = ./.; inherit go; })
    ...
  ];
};
```

# GOFLAKEINPUTS

*buildGoApplication* and *mkGoEnv* accept an optional *goFlakeInputs* attribute
that bridges sibling flake-input Go modules into the consumer's module graph
without publishing them or rewriting *go.mod* by hand. This is the supported
way to consume a Go library that lives in a flake input — including polyglot
repos where the Go module is in a subdirectory.

## Value shape

The shorthand form maps a Go module path to a derivation (typically a flake
input's *self*):

```
goFlakeInputs = {
  "code.linenoise.icu/zit/go" = inputs.tap;
};
```

For polyglot repos where the Go module is rooted in a subdirectory of the
flake, use the *{ src, subPath }* form:

```
goFlakeInputs = {
  "code.linenoise.icu/zit/go" = {
    src = inputs.tap;
    subPath = "go";
  };
};
```

## Effect on go.mod

At eval time, *buildGoApplication* and *mkGoEnv* invoke *go mod edit* to
inject a synthetic *require* and *replace* line per entry. The *replace*
points at the absolute */nix/store* path of the flake input (plus *subPath*
when set). The injected pseudo-version is the zero sentinel
*v0.0.0-00010101000000-000000000000*; the *require* line is unconditional and
will appear even if *go.mod* already declares an organic *require* for the
same module path. *go.mod* on disk is not modified — the edit happens on a
copy used for the build.

## Effect on gomod2nix.toml

If the flake input ships its own *gomod2nix.toml*, it is unioned with the
consumer's *gomod2nix.toml*. On a module-path conflict the consumer wins;
this lets a consumer pin a transitive dependency without coordinating with
the upstream input. Transitive deps that the input pulls in but the consumer
does not yet track must be added to the consumer's *gomod2nix.toml* (regen
via *go-sync-wrap*) until full FOD-regen lands as a follow-up — see
*LIMITATIONS* below.

## mkGoEnv parity

*mkGoEnv* accepts the same *goFlakeInputs* attribute and applies the same
synthesis. Devshells see the same merged module graph as *nix build*, so
*go build ./...*, *gopls*, and editor tooling resolve cross-flake imports
identically to the production build.

## passthru.mergedGoMod

*mkGoEnv* exposes the synthesized *go.mod* as *passthru.mergedGoMod* —
a derivation containing the *go.mod* and *go.sum* with the *replace* lines
injected. Consumers who want the merged file materialized into their working
tree (so editors and *gopls* read it directly) can wire it into a *shellHook*:

```
let goEnv = pkgs.mkGoEnv { pwd = ./.; inherit goFlakeInputs; };
in pkgs-master.mkShell {
  packages = [ goEnv ];
  shellHook = ''
    cp -f ${goEnv.passthru.mergedGoMod}/go.mod ./go.mod
    chmod u+w ./go.mod
  '';
}
```

## Example

*madder* consumes *tap*, whose Go module lives in the *go/* subdirectory of
the *tap* flake:

```
{
  inputs.tap.url = "github:amarbel-llc/tap";

  outputs = { self, nixpkgs, tap, ... }:
    let pkgs = import nixpkgs { inherit system; };
        goFlakeInputs = {
          "code.linenoise.icu/zit/go" = { src = tap; subPath = "go"; };
        };
    in {
      packages.default = pkgs.buildGoApplication {
        pwd = ./.;
        src = self;
        inherit goFlakeInputs;
      };

      devShells.default = pkgs-master.mkShell {
        packages = [ (pkgs.mkGoEnv { pwd = ./.; inherit goFlakeInputs; }) ];
      };
    };
}
```

## Limitations

- *goFlakeInputs* values must be source derivations (a flake's *self*, a
  path, or a fetched src). Pre-built Go binary derivations are not supported
  — only sources are consumed.
- The synthetic *require* line is unconditional. An organic *require* in
  *go.mod* for the same module path is not auto-removed; both lines coexist
  and *go.mod* should be kept tidy manually (or the organic *require*
  removed once the flake input is wired in).
- Transitive deps of the flake input that are not in the consumer's
  *gomod2nix.toml* must be added there (regen via *go-sync-wrap* in the
  devshell). Full FOD-driven regeneration of the merged *gomod2nix.toml* is
  tracked as a follow-up.

## See also

For design rationale and the alternatives considered, see
*docs/features/0003-bridge-go-flake-inputs.md*.

# VERSION AND COMMIT INJECTION

*buildGoApplication* automatically injects the following ldflags into every
build:

```
-X main.version=<version>
-X main.commit=<commit>
```

*version* comes from the *version* attribute passed to *buildGoApplication*,
or from *gomod2nix.toml* if *goPackagePath* is set there. *commit* comes from
*src.rev* or *src.shortRev* if the source is a flake input; otherwise it is
the string *"unknown"*.

## Getting a real commit hash

*src = ./.;* is a plain path — it has no *.rev* and commit will always be
*"unknown"*. To bake in the real commit, pass *self* as *src*:

```
outputs = { self, nixpkgs, ... }:
  let
    myapp = pkgs.buildGoApplication {
      src = self;   # self.rev / self.shortRev come from the flake lock
      ...
    };
  in { ... }
```

*self.rev* is only set when the working tree is clean and the flake was
evaluated from a committed ref (e.g. via *nix build* after *git commit*).
*self.shortRev* is the 7-character abbreviation. *buildGoApplication* prefers
*.rev* and falls back to *.shortRev* automatically.

During local development with a dirty tree, *self.rev* is absent — the commit
field falls back to *"unknown"*, which is the intended behaviour.

## Go-side wiring

Declare the variables at package scope in *package main* so the linker can
set them via the *-X* flag:

```
var version = "dev"
var commit  = "unknown"
```

Then surface them in a *version* subcommand:

```
case "version":
    fmt.Printf("myapp %s (%s)\n", version, commit)
```

The variable names must match the ldflag paths exactly: *main.version* and
*main.commit*. If they live in a different package, adjust accordingly (e.g.
*-X mypkg.version*) and update the *ldflags* attribute on *buildGoApplication*.

In development (*nix develop*), the binary is built without the ldflag
injection, so *version* and *commit* will read *"dev"* and *"unknown"*
respectively — which is the intended behaviour.

# SEE ALSO

*gomod2nix*(1), *nix-build*(1), *nix*(1)
