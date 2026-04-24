# Packages added by amarbel-llc/nixpkgs that don't exist in upstream.
# Lives here (not all-packages.nix) so upstream merges never conflict.
final: _prev: {
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

  gomod2nix = final.callPackage ../pkgs/build-support/gomod2nix/cli {
    inherit (final) buildGoApplication go;
  };
}
