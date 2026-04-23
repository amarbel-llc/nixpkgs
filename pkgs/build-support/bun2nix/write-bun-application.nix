# Bun Application Builder
#
# Used to create an executable for a project which
# running requires:
# - A `bun install`
# - Running some command from package.json
{ pkgs, lib, bun, mkDerivation }:

lib.extendMkDerivation {
  constructDrv = mkDerivation;

  excludeDrvArgNames = [
    "startScript"
    "runtimeInputs"
    "runtimeEnv"
    "excludeShellChecks"
    "extraShellCheckFlags"
    "bashOptions"
    "inheritPath"
  ];

  extendDrvArgs =
    _finalAttrs:
    {
      startScript,
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      excludeShellChecks ? [ ],
      extraShellCheckFlags ? [ ],
      bashOptions ? [
        "errexit"
        "nounset"
        "pipefail"
      ],
      inheritPath ? true,
      nativeBuildInputs ? [ ],
      ...
    }@args:
    let
      script = pkgs.writeShellApplication {
        inherit
          runtimeEnv
          excludeShellChecks
          extraShellCheckFlags
          bashOptions
          inheritPath
          ;

        name = "bun2nix-application-startup";
        text = startScript;
        runtimeInputs = [
          bun
        ]
        ++ runtimeInputs;
      };
    in
    {
      nativeBuildInputs = [
        pkgs.makeWrapper
      ]
      ++ nativeBuildInputs;

      installPhase =
        args.installPhase or ''
          runHook preInstall

          mkdir -p \
            "$out/share/$pname" \
            "$out/bin"

          cp -r ./. "$out/share/$pname"

          makeWrapper ${lib.getExe script} $out/bin/$pname \
            --chdir "$out/share/$pname"

          runHook postInstall
        '';
    };
}
