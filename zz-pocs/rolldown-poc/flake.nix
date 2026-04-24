{
  description = "PoC: build a rolldown-using project with bun2nix";

  inputs = {
    # Absolute path: `path:../..` gets re-rooted to the /nix/store copy of
    # this flake at eval time, not to the on-disk location, resolving to
    # /nix/ (forbidden in pure mode).
    nixpkgs.url = "path:/home/sasha/eng/repos/nixpkgs/.worktrees/plain-linden";
    bun2nix-flake = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      bun2nix-flake,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      bun2nixCli = bun2nix-flake.packages.${system}.default;
      # Re-call the fork's bun2nix library with `cacheEntryCreator` wired up.
      # The overlay at overlays/amarbel-packages.nix passes `{}` so fetchBunDeps
      # would throw; bypass by calling directly.
      bun2nix = pkgs.callPackage (pkgs.path + /pkgs/build-support/bun2nix) {
        cacheEntryCreator = bun2nix-flake.packages.${system}.cacheEntryCreator;
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.bun
          bun2nixCli
        ];
      };
      packages.${system}.default = pkgs.callPackage ./default.nix {
        inherit bun2nix;
      };
    };
}
