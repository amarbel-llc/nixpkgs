# Packages added by amarbel-llc/nixpkgs that don't exist in upstream.
# Lives here (not all-packages.nix) so upstream merges never conflict.
final: _prev: {
  fetchGgufModel = final.callPackage ../pkgs/build-support/fetch-gguf-model { };

  inherit
    (final.callPackage ../pkgs/build-support/bun2nix { })
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
