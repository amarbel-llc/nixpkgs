{
  description = "PoC: source a Go module dependency from a Nix flake input via go.mod replace.";

  inputs = {
    # Absolute path: `path:../..` gets re-rooted to the /nix/store copy of
    # this flake at eval time, not to the on-disk location, resolving to
    # /nix/ (forbidden in pure mode). Same workaround as rolldown-poc.
    nixpkgs.url = "path:/home/sasha/eng/repos/nixpkgs/.worktrees/fair-rowan";

    # The "upstream Go library", consumed as a non-flake source. In the real
    # use case this would be e.g. github:owner/lib; here it points at the
    # ./upstream/ subdirectory of this PoC.
    poc-lib = {
      url = "path:./upstream";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      poc-lib,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.go
        ];
      };

      packages.${system} = {
        default = pkgs.callPackage ./default.nix {
          pocLibSrc = poc-lib;
        };
        via-gomod2nix = pkgs.callPackage ./default-via-gomod2nix.nix {
          pocLibSrc = poc-lib;
        };
        mkgoenv-test = pkgs.callPackage ./mkgoenv-test.nix {
          pocLibSrc = poc-lib;
        };
      };
    };
}
