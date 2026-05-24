# Smoke tests for goSourceFilter.
# Build with: nix-build pkgs/build-support/gomod2nix/source-filter-test.nix
{ pkgs ? import ../../.. { } }:
let
  fixture = pkgs.runCommand "go-source-filter-fixture" { } ''
    mkdir -p $out/cmd/example
    echo "package main" > $out/cmd/example/main.go
    echo "module example.com/x" > $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
    echo "# README" > $out/README.md
    mkdir -p $out/doc
    echo "doc" > $out/doc/intro.md
    echo "VERSION" > $out/VERSION
  '';

  basic = pkgs.goSourceFilter { src = fixture; };
  withExtras = pkgs.goSourceFilter {
    src = fixture;
    extras = [ "^doc/.*" "^VERSION$" ];
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";

  basicFiles = builtins.attrNames (builtins.readDir basic);
  basicCmdFiles = builtins.attrNames (builtins.readDir "${basic}/cmd/example");

  withExtrasFiles = builtins.attrNames (builtins.readDir withExtras);
  withExtrasDocFiles =
    if builtins.pathExists "${withExtras}/doc"
    then builtins.attrNames (builtins.readDir "${withExtras}/doc")
    else [];

  middlewareResult = pkgs.goSourceFilterMiddleware fixture;
  middlewareFiles = builtins.attrNames (builtins.readDir middlewareResult);
in
pkgs.runCommand "go-source-filter-tests"
  {
    _ignored = [
      (assert' "basic: keeps go.mod" (builtins.elem "go.mod" basicFiles))
      (assert' "basic: keeps go.sum" (builtins.elem "go.sum" basicFiles))
      (assert' "basic: keeps gomod2nix.toml" (builtins.elem "gomod2nix.toml" basicFiles))
      (assert' "basic: drops README.md" (! (builtins.elem "README.md" basicFiles)))
      (assert' "basic: drops VERSION" (! (builtins.elem "VERSION" basicFiles)))
      (assert' "basic: keeps cmd/example/main.go"
        (builtins.elem "main.go" basicCmdFiles))
      (assert' "extras: keeps VERSION" (builtins.elem "VERSION" withExtrasFiles))
      (assert' "extras: keeps doc/intro.md" (builtins.elem "intro.md" withExtrasDocFiles))
      (assert' "basic: doc/ dir is kept even with no extras matching its contents"
        (builtins.elem "doc" basicFiles))
      (assert' "middleware: behaves identically to goSourceFilter with no extras"
        (middlewareFiles == basicFiles))
      # Regression check for amarbel-llc/nixpkgs#38: result must NOT be a
      # set, so it passes the flake schema check for packages.<system>.<name>
      # ("expected ... a derivation or path but found a set: { ... }").
      # `builtins.path` returns a string (store path with context), which
      # the flake schema accepts; `lib.cleanSourceWith` returns an attrset,
      # which it rejects. If this assertion fails, downstream producers
      # can't write `go-pkgs = pkgs.goSourceFilter { ... };` without an
      # explicit `.outPath` coercion. The POC fixture at
      # zz-pocs/goflake-poc/.#go-pkgs-test exercises the flake-schema
      # acceptance end-to-end.
      (assert' "type: goSourceFilter result must not be a set (regression check for #38)"
        (builtins.typeOf basic != "set"))
      (assert' "type: middleware result must not be a set (regression check for #38)"
        (builtins.typeOf middlewareResult != "set"))
    ];
  }
  "touch $out"
