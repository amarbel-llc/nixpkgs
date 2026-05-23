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

  # Union the consumer's gomod2nix.toml with each flake input's. On
  # conflict (same Go module path in both), consumer wins.
  mergeGomod2nixTomls =
    { consumer, flakeInputs }:
    let
      # Build a single merged attrset across all flake-input mods.
      # `//` is right-wins; in this fold, later flake inputs override
      # earlier ones. (For now we assume flake-input collisions are
      # rare — they'd indicate a deeper conflict the consumer should
      # resolve manually.)
      flakeInputMerged =
        builtins.foldl' (acc: t: acc // (t.mod or { })) { } flakeInputs;
    in
    {
      schema = consumer.schema or 3;
      mod = flakeInputMerged // (consumer.mod or { });
    };
in
{
  inherit
    sentinelPseudoVersion
    normalizeFlakeInput
    mkMergedGoMod
    mergeGomod2nixTomls
    ;
}
