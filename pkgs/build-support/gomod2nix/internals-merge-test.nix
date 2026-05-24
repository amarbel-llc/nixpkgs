# Regression tests for `mergeGomod2nixTomls` (gomod2nix internals).
# Build with: nix-build pkgs/build-support/gomod2nix/internals-merge-test.nix
#
# Specifically covers amarbel-llc/nixpkgs#50: when a consumer bridges
# module X via goFlakeInputs and a producer flake-input's own
# gomod2nix.toml has a transitive pin for X, the merge MUST strip X
# from the resulting `mod` table. Otherwise mkVendorEnv's symlink.go
# pre-creates vendor/<X> and collides with the synthetic
# localReplaceCommands.
{ pkgs ? import ../../.. { } }:
let
  inherit (pkgs.callPackage ./internals.nix { }) mergeGomod2nixTomls;

  # Fixture: consumer has its own pin for `shared` AND `only-in-consumer`.
  # Producer flake-input has pins for `shared` (different version,
  # leaks-transitively case) and `only-in-flake`.
  # Consumer bridges `shared` via goFlakeInputs.
  consumer = {
    schema = 3;
    mod = {
      "github.com/example/shared" = {
        version = "v1.0.0";
        hash = "consumer-hash";
      };
      "github.com/example/only-in-consumer" = {
        version = "v2.0.0";
        hash = "c";
      };
    };
  };

  flakeInputs = [
    {
      schema = 3;
      mod = {
        # Producer-side transitive pin for the same module the consumer
        # is bridging — this is the #50 leak vector.
        "github.com/example/shared" = {
          version = "v0.9.0";
          hash = "flake-hash";
        };
        "github.com/example/only-in-flake" = {
          version = "v3.0.0";
          hash = "f";
        };
      };
    }
  ];

  # Call mergeGomod2nixTomls with `bridgedKeys` declaring that
  # `shared` is handled by goFlakeInputs.
  merged = mergeGomod2nixTomls {
    inherit consumer flakeInputs;
    bridgedKeys = [ "github.com/example/shared" ];
  };

  # Call WITHOUT bridgedKeys to verify the legacy behaviour (used by
  # the no-goFlakeInputs path).
  mergedNoBridge = mergeGomod2nixTomls {
    inherit consumer flakeInputs;
  };

  assert' = label: cond: if cond then null else throw "${label}: assertion failed";
in
pkgs.runCommand "internals-merge-tests"
  {
    _ignored = [
      # #50 regression: bridged keys MUST be stripped from the merged
      # `mod` table, regardless of which side declared them (consumer
      # AND producer entries for the same key are both removed).
      (assert' "bridged key stripped (consumer's pin removed) (#50)"
        (! merged.mod ? "github.com/example/shared"))

      # Non-bridged keys survive unchanged.
      (assert' "non-bridged consumer key kept"
        (merged.mod ? "github.com/example/only-in-consumer"))
      (assert' "non-bridged producer key kept"
        (merged.mod ? "github.com/example/only-in-flake"))

      # Schema preserved from consumer.
      (assert' "schema preserved" (merged.schema == 3))

      # Legacy behaviour without bridgedKeys: nothing stripped,
      # consumer wins on conflict.
      (assert' "no-bridge: shared key kept" (mergedNoBridge.mod ? "github.com/example/shared"))
      (assert' "no-bridge: consumer wins on conflict"
        (mergedNoBridge.mod."github.com/example/shared".hash == "consumer-hash"))
    ];
  }
  "touch $out"
