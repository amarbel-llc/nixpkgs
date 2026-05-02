/**
  bats-test build-support library.

  Exposes `batsLane` — a derivation that runs a bats integration suite
  against a pre-built binary inside the nix build sandbox. Used by
  consumers (madder, dodder, …) to surface per-tag test lanes as flake
  outputs without rebuilding Go per filter.

  The builder takes a binary by store-path reference (`base`), stages
  the bats source tree into a writable scratch dir, exports a
  caller-named env var pointing at the binary, optionally extends
  `BATS_LIB_PATH`, and runs `bats *.bats` with an optional `--filter-tags`
  expression. Output is a stamp file (touched on success).

  See amarbel-llc/nixpkgs#14 for the design rationale.
*/
{
  lib,
  runCommand,
  bats,
}:

let
  defaultBats = bats;

  # Sanitize a bats `--filter-tags` expression for use as a derivation
  # name suffix. Replaces shell-unfriendly characters with `_`.
  sanitizeFilter =
    filter:
    builtins.replaceStrings
      [ "!" "," ":" " " ]
      [ "not_" "_" "_" "_" ]
      filter;

  batsLane =
    {
      # Pre-built derivation containing the binary under test at
      # ${base}/bin/${binaryName}. Caller is responsible for ensuring
      # `base` is built (typically a buildGoApplication-derived
      # derivation).
      base,

      # Directory containing the *.bats test files. Copied recursively
      # into the staging scratch dir.
      batsSrc,

      # Subpath under ${base}/bin that the test binary lives at. No
      # default — explicit is safer than inferring from base.pname.
      binaryName,

      # `bats --filter-tags` expression. Empty string means no filter
      # (run all tests). The flag is conditionally omitted when empty.
      filter ? "",

      # Override the derivation name. When null, the name is
      # `${base.pname}-bats-${suffix}` where suffix is derived from
      # `filter` (sanitized) or "all" if filter is empty.
      name ? null,

      # Bats binary to invoke. Defaults to nixpkgs's `pkgs.bats`.
      # Caller can override with a wrapper (e.g. amarbel-llc/bob's
      # batman) — but the wrapper's flags must be compatible with the
      # invocation below (`--jobs`, optional `--filter-tags`, `*.bats`).
      bats ? defaultBats,

      # Entries appended to BATS_LIB_PATH (colon-joined). Each entry
      # should be a derivation or path containing a `share/bats`-style
      # layout that bats's `bats_load_library` resolves against.
      # When empty, BATS_LIB_PATH is left unchanged.
      batsLibPath ? [ ],

      # Name of the env var set to ${base}/bin/${binaryName}. Tests
      # consult this var to locate the binary under test (madder reads
      # MADDER_BIN; consumers pick whatever name their tests expect).
      binaryEnvVarName ? "BATS_BIN",

      # Additional files to copy into the staging dir alongside the
      # bats sources. Each entry is { src; dest; } where `dest` is a
      # path relative to the staging root (which contains the
      # zz-tests_bats/ subdir). Use this for side-channel files like
      # version manifests that tests read via $BATS_TEST_DIRNAME/...
      extraStagedFiles ? [ ],

      # Extra build-time tools the bats helpers need (jq, curl, etc.).
      nativeBuildInputs ? [ ],
    }:
    let
      derivedSuffix =
        if filter != "" then sanitizeFilter filter else "all";

      derivationName =
        if name != null then name else "${base.pname}-bats-${derivedSuffix}";

      libPathExport =
        lib.optionalString (batsLibPath != [ ]) ''
          export BATS_LIB_PATH="''${BATS_LIB_PATH:+$BATS_LIB_PATH:}${
            lib.concatStringsSep ":" (map toString batsLibPath)
          }"
        '';

      filterFlag =
        lib.optionalString (filter != "") "--filter-tags '${filter}'";

      extraStagingCommands =
        lib.concatMapStringsSep "\n"
          (entry: "cp ${entry.src} stage/${entry.dest}")
          extraStagedFiles;
    in
    runCommand derivationName
      {
        inherit nativeBuildInputs;
      }
      ''
        mkdir -p stage/zz-tests_bats
        cp -r ${batsSrc}/* stage/zz-tests_bats/
        chmod -R u+w stage

        ${extraStagingCommands}

        export ${binaryEnvVarName}="${base}/bin/${binaryName}"
        ${libPathExport}

        cd stage/zz-tests_bats
        ${bats}/bin/bats \
          --jobs $NIX_BUILD_CORES \
          ${filterFlag} \
          *.bats

        touch $out
      '';

in
{
  inherit batsLane;
}
