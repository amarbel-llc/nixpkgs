# Packages added by amarbel-llc/nixpkgs that don't exist in upstream.
# Lives here (not all-packages.nix) so upstream merges never conflict.
final: prev: {
  fetchGgufModel = final.callPackage ../pkgs/build-support/fetch-gguf-model { };

  # Zig binary from nix-community/bun2nix, needed by fetchBunDeps.
  bun2nix-cache-entry-creator =
    final.callPackage ../pkgs/build-support/bun2nix/cache-entry-creator
      { };

  inherit
    (final.callPackage ../pkgs/build-support/bun2nix {
      cacheEntryCreator = final.bun2nix-cache-entry-creator;
    })
    buildBunBinary
    buildBunBinaries
    buildZxScript
    buildZxScriptFromFile
    fetchBunDeps
    mkBunDerivation
    writeBunApplication
    writeBunScriptBin
    ;

  inherit
    (final.callPackage ../pkgs/build-support/gomod2nix { })
    buildGoApplication
    buildGoRace
    buildGoCover
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    ;

  gomod2nix = final.callPackage ../pkgs/build-support/gomod2nix/cli {
    inherit (final) buildGoApplication go;
  };

  # Extend upstream's pkgs.testers attrset with fork-added testers.
  # Mirrors upstream convention (pkgs.testers.runCommand,
  # pkgs.testers.runNixOSTest, etc.). New testers go here, not at the
  # top level — see amarbel-llc/nixpkgs#16 for the broader migration.
  testers = (prev.testers or { }) // {
    batsLane =
      (final.callPackage ../pkgs/build-support/bats-test { }).batsLane;
  };
}
