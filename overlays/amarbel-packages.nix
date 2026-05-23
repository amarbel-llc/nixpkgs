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

  # Validates the scdoc man page sources under
  # pkgs/build-support/gomod2nix/. Exposed as a flake check so syntax
  # errors in *.7.scd are caught by the pre-merge hook rather than
  # silently shipped. See eng-manpages(7) § SCDOC PATTERN.
  gomod2nix-man = final.stdenvNoCC.mkDerivation {
    pname = "gomod2nix-man";
    version = final.gomod2nix.version or "0.0.0";
    src = ../pkgs/build-support/gomod2nix;
    nativeBuildInputs = [ final.scdoc ];
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/share/man/man1
      mkdir -p $out/share/man/man5
      mkdir -p $out/share/man/man7
      for f in $src/*.1.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man1/$(basename "$f" .scd)"
      done
      for f in $src/*.5.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man5/$(basename "$f" .scd)"
      done
      for f in $src/*.7.scd; do
        [ -e "$f" ] || continue
        scdoc < "$f" > "$out/share/man/man7/$(basename "$f" .scd)"
      done
    '';
  };
}
