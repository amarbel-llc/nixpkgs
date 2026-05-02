/**
  bats-test build-support library.

  Exposes `batsLane` — a derivation that runs a bats integration suite
  against a pre-built binary inside the nix build sandbox. Used by
  consumers (madder, dodder, …) to surface per-tag test lanes as flake
  outputs without rebuilding Go per filter.

  The builder takes one or more binaries by store-path reference,
  stages the bats source tree into a writable scratch dir, exports
  caller-named env vars pointing at each binary, optionally extends
  `BATS_LIB_PATH`, and runs `bats *.bats` with an optional `--filter-tags`
  expression. Output is a stamp file (touched on success).

  Two binary-export forms are accepted:
  - **single-binary shortcut**: `base` + `binaryName` + (optional)
    `binaryEnvVarName`. The most common case.
  - **multi-binary**: `binaries` map of ENV_VAR_NAME → { base; name; }.
    Use when a suite needs more than one binary in scope, or when the
    binaries live in different derivations.

  When `binaries` is set, the shortcut args are ignored except `base`
  is still consulted as the naming anchor for the default derivation
  name.

  See amarbel-llc/nixpkgs#14 for the design rationale.
*/
{
  lib,
  runCommand,
  bats,
  parallel,
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
      # Single-binary shortcut: pre-built derivation containing the
      # binary under test at ${base}/bin/${binaryName}. Caller is
      # responsible for ensuring `base` is built (typically a
      # buildGoApplication-derived derivation). Also used as the naming
      # anchor for the default derivation name (`${base.pname}-bats-...`)
      # — left consulted even when `binaries` is set.
      base ? null,

      # Directory containing the *.bats test files. Copied recursively
      # into the staging scratch dir.
      batsSrc,

      # Single-binary shortcut: subpath under ${base}/bin that the
      # test binary lives at.
      binaryName ? null,

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

      # Single-binary shortcut: name of the env var set to
      # ${base}/bin/${binaryName}. Tests consult this var to locate the
      # binary under test (madder reads MADDER_BIN; consumers pick
      # whatever name their tests expect). Ignored when `binaries` is
      # set.
      binaryEnvVarName ? "BATS_BIN",

      # Multi-binary form: map of ENV_VAR_NAME → { base; name; }. Each
      # entry exports `<ENV_VAR_NAME>=${spec.base}/bin/${spec.name}`
      # before bats runs. Use this when a suite needs more than one
      # binary in scope (e.g. a CLI plus a sibling tool), or when the
      # binaries live in different derivations. When set, supersedes
      # the single-binary shortcut args (`base`/`binaryName`/
      # `binaryEnvVarName` are ignored for env-var purposes; `base` is
      # still used as a naming anchor if present).
      binaries ? null,

      # Additional env vars to export before invoking bats. Map of
      # NAME → value. Values are shell-escaped via lib.escapeShellArg.
      # Use for BATS_TEST_TIMEOUT, custom debug flags, config toggles.
      extraEnv ? { },

      # Extra args appended to the `bats` invocation, after `--jobs`
      # and `--filter-tags` and before `*.bats`. Each entry is
      # shell-escaped. Use for `--tag-expr`, `--no-parallelize-within-files`,
      # `--print-output-on-failure`, and other bats flags the builder
      # doesn't surface as first-class args.
      extraBatsArgs ? [ ],

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
      # Single-binary shortcut synthesizes into the multi-binary form
      # so there's only one downstream code path.
      resolvedBinaries =
        if binaries != null then
          binaries
        else if base != null && binaryName != null then
          { ${binaryEnvVarName} = { inherit base; name = binaryName; }; }
        else
          throw "testers.batsLane: either `binaries` or both `base` and `binaryName` must be set";

      # Naming anchor for the default derivation name. Prefer top-level
      # `base.pname` (works for both shortcut and multi-binary forms);
      # fall back to the first entry's base.pname when `binaries` is
      # the only form set.
      namingPname =
        if base != null then
          base.pname
        else
          (lib.head (lib.attrValues resolvedBinaries)).base.pname;

      derivedSuffix =
        if filter != "" then sanitizeFilter filter else "all";

      derivationName =
        if name != null then name else "${namingPname}-bats-${derivedSuffix}";

      binaryExports =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (envVar: spec: ''export ${envVar}="${spec.base}/bin/${spec.name}"'')
            resolvedBinaries
        );

      libPathExport =
        lib.optionalString (batsLibPath != [ ]) ''
          export BATS_LIB_PATH="''${BATS_LIB_PATH:+$BATS_LIB_PATH:}${
            lib.concatStringsSep ":" (map toString batsLibPath)
          }"
        '';

      filterFlag =
        lib.optionalString (filter != "") "--filter-tags '${filter}'";

      extraEnvExports =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (name: value: "export ${name}=${lib.escapeShellArg value}")
            extraEnv
        );

      extraBatsArgsStr =
        lib.concatMapStringsSep " " lib.escapeShellArg extraBatsArgs;

      extraStagingCommands =
        lib.concatMapStringsSep "\n"
          (entry: "cp ${entry.src} stage/${entry.dest}")
          extraStagedFiles;
    in
    runCommand derivationName
      {
        # parallel is required by `bats --jobs` (>1); included
        # unconditionally so consumers don't get a runtime
        # "parallel: command not found" surprise.
        nativeBuildInputs = nativeBuildInputs ++ [ parallel ];
      }
      ''
        mkdir -p stage/zz-tests_bats
        cp -r ${batsSrc}/* stage/zz-tests_bats/
        chmod -R u+w stage

        ${extraStagingCommands}

        ${binaryExports}
        ${libPathExport}
        ${extraEnvExports}

        cd stage/zz-tests_bats
        ${bats}/bin/bats \
          --jobs $NIX_BUILD_CORES \
          ${filterFlag} \
          ${extraBatsArgsStr} \
          *.bats

        touch $out
      '';

in
{
  inherit batsLane;
}
