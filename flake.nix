{
  description = "amarbel-llc overlay flake — fork-specific package additions and pins on top of nixpkgs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      lib = nixpkgs.lib;

      overlays = {
        default = nixpkgs.lib.composeManyExtensions (import ./overlays nixpkgs.lib);
        amarbelPackages = import ./overlays/amarbel-packages.nix;
      };

      legacyPackages = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          config.allowUnfree = true;
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
        in
        {
          inherit (pkgs)
            claude-code
            gomod2nix
            ;
          nix-man = pkgs.nix.man;
          default = pkgs.claude-code;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
        in
        {
          claude-code = pkgs.claude-code;
          gomod2nix = pkgs.gomod2nix;
          nix-man = pkgs.nix.man;
        }
      );

      nixosModules = nixpkgs.nixosModules;
    };
}
