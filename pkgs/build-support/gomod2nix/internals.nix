{ }:
let
  sentinelPseudoVersion = "v0.0.0-00010101000000-000000000000";

  # Normalize a goFlakeInputs value into { src, subPath } form.
  # Accepts:
  #   - a derivation or path (subPath defaults to "")
  #   - an attrset already in { src, subPath } form
  normalizeFlakeInput =
    value:
    if value ? src then
      {
        inherit (value) src;
        subPath = value.subPath or "";
      }
    else
      {
        src = value;
        subPath = "";
      };

  # Build a go.mod that includes synthetic require + replace lines for
  # each entry in goFlakeInputs. Pure-eval derivation, no network.
  mkMergedGoMod =
    {
      consumerGoMod,
      go,
      goFlakeInputs,
      runCommand,
    }:
    runCommand "merged-go.mod"
      {
        buildInputs = [ go ];
      }
      (
        let
          normalized = builtins.mapAttrs (_: normalizeFlakeInput) goFlakeInputs;
          editCommands = builtins.concatStringsSep "\n" (
            builtins.attrValues (
              builtins.mapAttrs (
                modPath: v:
                let
                  target = "${v.src}${if v.subPath == "" then "" else "/${v.subPath}"}";
                in
                ''
                  go mod edit -require=${modPath}@${sentinelPseudoVersion}
                  go mod edit -replace=${modPath}=${target}
                ''
              ) normalized
            )
          );
        in
        ''
          # Go 1.24+ refuses to run `go mod edit` when go.mod lives directly in
          # /build (the sandbox temp root). A subdirectory satisfies the check.
          mkdir -p work
          cd work
          cp ${consumerGoMod} ./go.mod
          chmod +w ./go.mod  # store-path cp preserves read-only; `go mod edit` needs write access
          ${editCommands}
          cp ./go.mod $out
        ''
      );
in
{
  inherit
    sentinelPseudoVersion
    normalizeFlakeInput
    mkMergedGoMod
    ;
}
