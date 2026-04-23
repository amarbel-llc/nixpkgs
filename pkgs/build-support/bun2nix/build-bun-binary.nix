# buildBunBinary  { pname, version, src, entrypoint, ... }
# buildBunBinaries { pname, version, src, entrypoints, ... }
#
# buildBunBinary produces $out/bin/$pname — a shell wrapper that execs
# bun from the nix store with a pre-built ESM bundle.
#
# buildBunBinaries produces $out/bin/{name1,name2,...} from a single
# shared bundle derivation. One `bun install` + one `bun build` with
# multiple entrypoints, then one wrapper per binary. See amarbel-llc/bun#3.
#
# Uses ESM format (not --bytecode) to support top-level await.
# See amarbel-llc/bun#2.
#
# The `bun` argument is overridable — when a future bun-minimal exists,
# consumers just pass it.
{ pkgs, lib, bun, fetchBunDeps }:

let
  # Map a .ts/.tsx/.mts/.cts basename to .js
  tsToJs =
    name:
    lib.replaceStrings
      [
        ".ts"
        ".tsx"
        ".mts"
        ".cts"
      ]
      [
        ".js"
        ".js"
        ".js"
        ".js"
      ]
      (builtins.baseNameOf name);

  # Shared: create the bundle derivation for one or more entrypoints.
  # entrypointPaths is a list of source-relative paths.
  mkBundle =
    {
      pname,
      version,
      src,
      entrypointPaths,
      bunNix ? null,
      bunBuildFlags ? [ ],
      bunfigPath ? null,
      npmrcPath ? null,
      overrides ? { },
    }:
    let
      hasDeps = bunNix != null;
      bunDeps = lib.optionalAttrs hasDeps {
        cache = fetchBunDeps {
          inherit bunNix bunfigPath npmrcPath overrides;
        };
      };
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "${pname}-bundle";
      inherit version src;

      nativeBuildInputs = [ bun ];

      buildPhase = ''
        runHook preBuild

        ${lib.optionalString hasDeps ''
          export BUN_INSTALL_CACHE_DIR=$(mktemp -d)
          cp -r ${bunDeps.cache}/share/bun-cache/. "$BUN_INSTALL_CACHE_DIR"
          bun install --frozen-lockfile --linker=isolated
        ''}

        mkdir -p $out
        bun build ${lib.escapeShellArgs entrypointPaths} \
          --target=bun \
          --format=esm \
          --outdir=$out \
          ${lib.escapeShellArgs bunBuildFlags}

        runHook postBuild
      '';

      dontInstall = true;
      dontFixup = true;
    };

  # Shared: create a wrapper script for a single binary.
  mkWrapper =
    {
      name,
      bundle,
      jsFile,
      runtimeInputs ? [ ],
      runtimeEnv ? { },
    }:
    let
      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") runtimeEnv
      );
      pathSetup = lib.optionalString (runtimeInputs != [ ]) ''
        export PATH="${lib.makeBinPath runtimeInputs}:$PATH"
      '';
    in
    pkgs.writeShellScriptBin name ''
      ${envExports}
      ${pathSetup}
      unset LD_LIBRARY_PATH
      exec ${bun}/bin/bun ${bundle}/${jsFile} "$@"
    '';

in
{
  # Single entrypoint → single binary.
  buildBunBinary =
    {
      pname,
      version,
      src,
      entrypoint ? "index.ts",
      bunNix ? null,
      bunBuildFlags ? [ ],
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      bunfigPath ? null,
      npmrcPath ? null,
      overrides ? { },
      ...
    }:
    let
      bundle = mkBundle {
        inherit
          pname
          version
          src
          bunNix
          bunBuildFlags
          bunfigPath
          npmrcPath
          overrides
          ;
        entrypointPaths = [ entrypoint ];
      };
    in
    mkWrapper {
      name = pname;
      inherit bundle runtimeInputs runtimeEnv;
      jsFile = tsToJs entrypoint;
    };

  # Multiple entrypoints → multiple binaries in one $out.
  # entrypoints is an attrset: { "bin-name" = "path/to/entry.ts"; ... }
  buildBunBinaries =
    {
      pname,
      version,
      src,
      entrypoints,
      bunNix ? null,
      bunBuildFlags ? [ ],
      runtimeInputs ? [ ],
      runtimeEnv ? { },
      bunfigPath ? null,
      npmrcPath ? null,
      overrides ? { },
      ...
    }:
    let
      bundle = mkBundle {
        inherit
          pname
          version
          src
          bunNix
          bunBuildFlags
          bunfigPath
          npmrcPath
          overrides
          ;
        entrypointPaths = builtins.attrValues entrypoints;
      };

      wrappers = lib.mapAttrsToList (
        name: entrypoint:
        mkWrapper {
          inherit name bundle runtimeInputs runtimeEnv;
          jsFile = tsToJs entrypoint;
        }
      ) entrypoints;
    in
    pkgs.symlinkJoin {
      name = pname;
      paths = wrappers;
    };
}
