{
  pkgs,
  hello ? pkgs.hello,
}:
let
  inherit (pkgs.callPackage ../../pkgs/build-support/gomod2nix/internals.nix { })
    mkMergedGoMod
    ;
  consumerGoMod = pkgs.writeText "go.mod" ''
    module github.com/test/consumer

    go 1.26
  '';
in
mkMergedGoMod {
  inherit consumerGoMod;
  go = pkgs.go;
  goFlakeInputs = {
    "github.com/example/lib" = {
      src = hello;
      subPath = "";
    };
  };
  runCommand = pkgs.runCommand;
}
