# Smoke tests for mkGoPkgs (RFC 0001 § Producer interface).
# Build with: nix-build pkgs/build-support/gomod2nix/mk-go-pkgs-test.nix
{ pkgs ? import ../../.. { } }:
let
  # Realistic fixture exercising:
  #   - prod Go file (cmd/example/main.go)
  #   - test Go file (cmd/example/main_test.go)
  #   - module files (go.mod, go.sum, gomod2nix.toml)
  #   - workspace files (go.work, go.work.sum)
  #   - root-anchored testdata/ (testdata/golden.txt)
  #   - nested testdata/ (internal/foo/testdata/cases.json)
  #   - non-Go file the filter should drop (README.md)
  #   - directory that should be traversed but otherwise filtered
  fixture = pkgs.runCommand "mk-go-pkgs-fixture" { } ''
    mkdir -p $out/cmd/example
    echo "package main" > $out/cmd/example/main.go
    echo "package main" > $out/cmd/example/main_test.go
    echo "module example.com/x" > $out/go.mod
    touch $out/go.sum
    touch $out/gomod2nix.toml
    echo "go 1.26" > $out/go.work
    touch $out/go.work.sum
    echo "# README" > $out/README.md

    mkdir -p $out/testdata
    echo "golden" > $out/testdata/golden.txt

    mkdir -p $out/internal/foo
    echo "package foo" > $out/internal/foo/foo.go
    mkdir -p $out/internal/foo/testdata
    echo '{"k":"v"}' > $out/internal/foo/testdata/cases.json
  '';

  built = pkgs.mkGoPkgs { src = fixture; };
  builtWithExtras = pkgs.mkGoPkgs {
    src = fixture;
    extras = [ "^README\\.md$" ];
    testExtras = [ "^.*\\.fixtures$" ]; # synthetic, fixture has none
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";

  inherit (pkgs.lib) isDerivation;

  prodTopFiles = builtins.attrNames (builtins.readDir built.go-pkgs);
  prodHasNested = builtins.pathExists "${built.go-pkgs}/internal/foo/foo.go";
  # testdata directories are always preserved (the empty-directory
  # leakthrough documented in goSourceFilter); what MUST be filtered is
  # their file contents.
  prodRootTestdataContents =
    if builtins.pathExists "${built.go-pkgs}/testdata"
    then builtins.attrNames (builtins.readDir "${built.go-pkgs}/testdata")
    else [ ];
  prodNestedTestdataContents =
    if builtins.pathExists "${built.go-pkgs}/internal/foo/testdata"
    then builtins.attrNames (builtins.readDir "${built.go-pkgs}/internal/foo/testdata")
    else [ ];
  prodHasMainTest = builtins.pathExists "${built.go-pkgs}/cmd/example/main_test.go";

  testTopFiles = builtins.attrNames (builtins.readDir built.go-pkgs-test);
  testHasMainTest = builtins.pathExists "${built.go-pkgs-test}/cmd/example/main_test.go";
  testHasNestedTestdata = builtins.pathExists "${built.go-pkgs-test}/internal/foo/testdata/cases.json";
  testHasRootTestdata = builtins.pathExists "${built.go-pkgs-test}/testdata/golden.txt";

  extrasProdHasReadme = builtins.pathExists "${builtWithExtras.go-pkgs}/README.md";
  extrasTestHasReadme = builtins.pathExists "${builtWithExtras.go-pkgs-test}/README.md";
in
pkgs.runCommand "mk-go-pkgs-tests"
  {
    _ignored = [
      # Schema-acceptance regression: both outputs must be real
      # derivations so they pass `nix flake check` (cf. #38, #44).
      (assert' "type: go-pkgs is a derivation" (isDerivation built.go-pkgs))
      (assert' "type: go-pkgs-test is a derivation" (isDerivation built.go-pkgs-test))

      # go-pkgs keeps the prod surface.
      (assert' "prod: keeps go.mod" (builtins.elem "go.mod" prodTopFiles))
      (assert' "prod: keeps go.sum" (builtins.elem "go.sum" prodTopFiles))
      (assert' "prod: keeps go.work" (builtins.elem "go.work" prodTopFiles))
      (assert' "prod: keeps go.work.sum" (builtins.elem "go.work.sum" prodTopFiles))
      (assert' "prod: keeps gomod2nix.toml" (builtins.elem "gomod2nix.toml" prodTopFiles))
      (assert' "prod: keeps cmd/example/main.go" prodHasNested)

      # go-pkgs drops the test surface (file contents — directories
      # may persist empty as a goSourceFilter-shared leakthrough).
      (assert' "prod: drops cmd/example/main_test.go" (! prodHasMainTest))
      (assert' "prod: root testdata/ is empty"
        (prodRootTestdataContents == [ ]))
      (assert' "prod: nested testdata/ is empty"
        (prodNestedTestdataContents == [ ]))
      (assert' "prod: drops README.md (no extras)"
        (! (builtins.elem "README.md" prodTopFiles)))

      # go-pkgs-test is a superset.
      (assert' "test: keeps cmd/example/main_test.go" testHasMainTest)
      (assert' "test: keeps nested testdata/cases.json" testHasNestedTestdata)
      (assert' "test: keeps root testdata/golden.txt" testHasRootTestdata)
      (assert' "test: still keeps go.mod" (builtins.elem "go.mod" testTopFiles))
      (assert' "test: drops README.md (no extras)"
        (! (builtins.elem "README.md" testTopFiles)))

      # extras applies to BOTH outputs.
      (assert' "extras: prod gets README.md when in extras" extrasProdHasReadme)
      (assert' "extras: test gets README.md when in extras" extrasTestHasReadme)
    ];
  }
  "touch $out"
