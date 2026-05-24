# mkGoPkgs — canonical producer-side helper for the flake-input-go_mod
# protocol (RFC 0001 § Producer interface).
#
# Returns the two flake outputs RFC 0001 mandates:
#
#   go-pkgs       — prod shape: *.go (excluding *_test.go), module
#                   files, workspace files, plus caller-supplied
#                   `extras`. Downstream prod consumers bridge against
#                   this by default.
#
#   go-pkgs-test  — superset: go-pkgs + *_test.go + testdata/** +
#                   caller-supplied `testExtras`. Used for self-
#                   consumption (a producer building itself from its
#                   own published artifact, exercising its own tests)
#                   and for downstream consumers that need to run the
#                   producer's tests against the bridged source.
#
# Implementation notes (informed by madder#212's inline contract test):
#
# 1. The testdata predicate matches both root-anchored (`^testdata/.*`,
#    for repos with a top-level `testdata/`) and nested
#    (`.*/testdata/.*`, for fixtures under internal packages). Both
#    patterns are needed in the same convention because Go module
#    layouts differ between single-module-at-root and subdirectory
#    producers.
#
# 2. The `runCommand` wrap is essentially free (<1s on madder's first
#    eval); `preferLocalBuild = true` + `allowSubstitutes = false`
#    keeps the wrap-step cheap and local.
#
# 3. The contract test for this helper is *self-consumption*: a
#    producer's own `buildGoApplication { src = pkgs.go-pkgs-test;
#    pwd = pkgs.go-pkgs-test; }` builds and tests cleanly. Without
#    self-consumption a producer can publish `go-pkgs-test` that
#    subtly fails downstream and never notice. RFC 0001 § Producer
#    interface carries the corresponding SHOULD recommendation.
{ lib, runCommand }:
let
  # Module / workspace files kept in BOTH outputs (mirrors
  # `goSourceFilter`'s default keep-set; see amarbel-llc/nixpkgs#45 for
  # go.work / go.work.sum).
  isModuleFile =
    relPath:
    relPath == "go.mod"
    || relPath == "go.sum"
    || relPath == "go.work"
    || relPath == "go.work.sum"
    || relPath == "gomod2nix.toml";

  # Build a derivation containing the files of `src` that satisfy
  # `predicate`, always traversing directories. The predicate receives
  # the source-tree-relative path of each non-directory file.
  filteredTree =
    {
      name,
      src,
      predicate,
    }:
    let
      origSrc = if src ? origSrc then src.origSrc else src;
      filteredPath = builtins.path {
        inherit name;
        path = origSrc;
        filter =
          path: type:
          let
            relPath = lib.removePrefix (toString origSrc + "/") (toString path);
          in
          type == "directory" || predicate relPath;
      };
    in
    runCommand name {
      preferLocalBuild = true;
      allowSubstitutes = false;
    } ''
      cp -r ${filteredPath} $out
    '';

  mkGoPkgs =
    {
      src,
      # Extra regex patterns added to BOTH outputs (e.g. embedded
      # assets, top-level config files referenced by //go:embed).
      extras ? [ ],
      # Extra regex patterns added ONLY to go-pkgs-test (e.g. fixtures
      # outside the testdata/ convention).
      testExtras ? [ ],
    }:
    let
      baseName = src.name or "source";

      isExtra = relPath: lib.any (re: builtins.match re relPath != null) extras;
      isTestExtra = relPath: lib.any (re: builtins.match re relPath != null) testExtras;

      isProdGoFile =
        relPath:
        lib.hasSuffix ".go" relPath
        && !lib.hasSuffix "_test.go" relPath;

      isTestGoFile = relPath: lib.hasSuffix "_test.go" relPath;

      isTestdataFile =
        relPath:
        builtins.match ".*/testdata/.*" relPath != null
        || builtins.match "^testdata/.*" relPath != null;

      prodPredicate =
        relPath:
        isProdGoFile relPath
        || isModuleFile relPath
        || isExtra relPath;

      testPredicate =
        relPath:
        prodPredicate relPath
        || isTestGoFile relPath
        || isTestdataFile relPath
        || isTestExtra relPath;
    in
    {
      go-pkgs = filteredTree {
        name = "${baseName}-go-pkgs";
        inherit src;
        predicate = prodPredicate;
      };

      go-pkgs-test = filteredTree {
        name = "${baseName}-go-pkgs-test";
        inherit src;
        predicate = testPredicate;
      };
    };
in
{
  inherit mkGoPkgs;
}
