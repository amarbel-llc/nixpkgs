{ bun2nix }:

bun2nix.mkBunDerivation {
  src = ./.;
  packageJson = ./package.json;
  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./bun.nix;
  };

  # Override: run the package.json `build` script (which invokes rolldown)
  # instead of `bun build` (Bun's own bundler) that the hook defaults to.
  buildPhase = ''
    runHook preBuild
    bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r dist "$out/"
    runHook postInstall
  '';
}
