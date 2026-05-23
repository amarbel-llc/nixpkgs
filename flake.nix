{
  description = "amarbel-llc overlay flake — fork-specific package additions and pins on top of nixpkgs.";

  inputs = {
    nixpkgs-master.url = "github:NixOS/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
  };

  outputs =
    { self, nixpkgs-master }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs-master.lib.genAttrs systems;
    in
    {
      lib = nixpkgs-master.lib;

      overlays = {
        default = nixpkgs-master.lib.composeManyExtensions (import ./overlays nixpkgs-master.lib);
        amarbelPackages = import ./overlays/amarbel-packages.nix;
      };

      legacyPackages = forAllSystems (
        system:
        import nixpkgs-master {
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
            gomod2nix-man
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
          gomod2nix-man = pkgs.gomod2nix-man;
          nix-man = pkgs.nix.man;
        }
      );

      nixosModules = nixpkgs-master.nixosModules;
    };
}
