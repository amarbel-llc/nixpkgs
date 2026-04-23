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

```go
var version = "dev"
var commit  = "unknown"
```

Then surface them in a *version* subcommand:

```go
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
