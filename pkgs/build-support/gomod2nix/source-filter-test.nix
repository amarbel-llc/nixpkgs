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
    ];
  }
  "touch $out"
