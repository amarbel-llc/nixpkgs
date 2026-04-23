/**
  gomod2nix build-support library.

  Exposes helpers for packaging Go applications that use
  gomod2nix.toml lockfiles as Nix derivations. The public surface is:

  - `buildGoApplication` — build a Go application from a gomod2nix.toml lockfile
  - `mkGoEnv` — create a vendor environment for use in devshells
  - `mkVendorEnv` — low-level: assemble a vendor/ directory from fetched modules
  - `mkGoCacheEnv` — pre-warm the Go build cache as a derivation

  The `go` argument defaults to the Go version specified in `go.mod` (via
  `selectGo`) and can be overridden: `buildGoApplication { go = pkgs.go_1_24; }`.

  The `gomod2nix` CLI is auto-injected from `pkgs.gomod2nix` via `callPackage`
  and is propagated through `mkGoEnv` so any devShell that includes the env
  gets the CLI on PATH (needed by `go-sync-wrap.sh` and `updateScript`).
*/
{
  buildEnv,
  buildPackages,
  cacert,
  fetchgit,
  git,
  gnutar,
  gomod2nix ? throw "gomod2nix: pkgs.gomod2nix must be available — ensure amarbel-llc/nixpkgs is your nixpkgs input",
  jq,
  lib,
  makeSetupHook,
  pkgsBuildBuild,
  rsync,
  runCommand,
  runtimeShell,
  stdenv,
  stdenvNoCC,
  writeScript,
  zstd,
}:
let

  hooks = import ./hooks/default.nix {
    inherit
      lib
      makeSetupHook
      buildPackages
      stdenv
      ;
  };

  inherit (hooks)
    goConfigHook
    goBuildHook
    goCheckHook
    goInstallHook
    goSyncWrapHook
    ;

  inherit (builtins)
    elemAt
    hasAttr
    readFile
    split
    substring
    toJSON
    ;
  inherit (lib)
    concatStringsSep
    fetchers
    filterAttrs
    mapAttrs
    mapAttrsToList
    optional
    optionalAttrs
    optionalString
    pathExists
    removePrefix
    ;

  inherit (import ./parser.nix) parseGoMod parseGoWork;

  # Internal only build-time attributes
  internal =
    let
      mkInternalPkg =
        name: src:
        pkgsBuildBuild.runCommand "gomod2nix-${name}"
          {
            inherit (pkgsBuildBuild.go) GOOS GOARCH;
            nativeBuildInputs = [ pkgsBuildBuild.go ];
          }
          ''
            export HOME=$(mktemp -d)
            go build -o "$HOME/bin" ${src}
            mv "$HOME/bin" "$out"
          '';
    in
    {
      # Create a symlink tree of vendored sources
      symlink = mkInternalPkg "symlink" ./symlink/symlink.go;

      # Install development dependencies from tools.go
      install = mkInternalPkg "symlink" ./install/install.go;

      # Generate dummy import file for cache warming
      cachegen = mkInternalPkg "cachegen" ./cachegen/cachegen.go;
    };

  fetchGoModule =
    {
      hash,
      goPackagePath,
      version,
      go,
    }:
    stdenvNoCC.mkDerivation {
      name = "${baseNameOf goPackagePath}_${version}";
      builder = ./fetch.sh;
      inherit goPackagePath version;
      nativeBuildInputs = [
        cacert
        git
        go
        jq
      ];
      outputHashMode = "recursive";
      outputHashAlgo = null;
      outputHash = hash;
      impureEnvVars = fetchers.proxyImpureEnvVars ++ [ "GOPROXY" ];
    };

  # Generate vendor/modules.txt content for workspace builds.
  # Format: ## workspace header, workspace module entries, external module entries with package lists.
  mkWorkspaceModulesTxt =
    pwd: goWork: modulesStruct:
    let
      # Parse all workspace modules' go.mod files
      workspaceModules = map (
        usePath:
        let
          moduleGoMod = parseGoMod (readFile "${toString pwd}/${usePath}/go.mod");
        in
        {
          path = usePath;
          modulePath = moduleGoMod.module;
          goVersion = moduleGoMod.go;
          requires = builtins.attrNames (moduleGoMod.require or { });
        }
      ) goWork.use;

      # Collect all module paths that are required by any workspace module
      allRequired = builtins.concatLists (map (m: m.requires) workspaceModules);

      # Only list workspace modules that are dependencies of other workspace modules
      dependedModules = builtins.filter (m: builtins.elem m.modulePath allRequired) workspaceModules;

      workspaceEntries = map (m: ''
        echo '# ${m.modulePath} v0.0.0 => ${m.path}' >> vendor/modules.txt
        echo '## explicit; go ${m.goVersion}' >> vendor/modules.txt
      '') dependedModules;

      # External module entries: # module version + ## explicit; go X.Y + package list.
      # Every module in any workspace go.mod's require block must get an explicit
      # marker, even if no workspace source imports any of its packages (e.g. indirect
      # deps whose only importers are build-tag-gated, like mousetrap via cobra on linux).
      # Otherwise `go build -mod=vendor` rejects the vendor tree as inconsistent.
      externalEntries = mapAttrsToList (
        name: meta:
        let
          vendorPkgs = meta.vendorPackages or [ ];
          pkgLines = concatStringsSep "\n" (map (p: "echo '${p}' >> vendor/modules.txt") vendorPkgs);
        in
        ''
          echo '# ${name} ${meta.version}' >> vendor/modules.txt
          echo '## explicit; go ${meta.goVersion or "1.21"}' >> vendor/modules.txt
          ${pkgLines}
        ''
      ) (modulesStruct.mod or { });
    in
    [
      ''
        echo '## workspace' > vendor/modules.txt
      ''
    ]
    ++ workspaceEntries
    ++ externalEntries;

  mkVendorEnv =
    {
      go,
      modulesStruct,
      defaultPackage ? "",
      goMod,
      pwd,
      goWork ? null,
    }:
    let
      localReplaceCommands =
        let
          localReplaceAttrs = filterAttrs (n: v: hasAttr "path" v) goMod.replace;
          commands = (
            mapAttrsToList (name: value: (''
              mkdir -p $(dirname vendor/${name})
              ln -s ${pwd + "/${value.path}"} vendor/${name}
            '')) localReplaceAttrs
          );
        in
        # In workspace mode, workspace module symlinks are not needed in vendor/
        # (Go resolves them from the source tree)
        if goWork != null then
          [ ]
        else if goMod != null then
          commands
        else
          [ ];

      workspaceVendorCommands =
        if goWork != null then mkWorkspaceModulesTxt pwd goWork modulesStruct else [ ];

      sources = mapAttrs (
        goPackagePath: meta:
        fetchGoModule {
          goPackagePath = meta.replaced or goPackagePath;
          inherit (meta) version hash;
          inherit go;
        }
      ) modulesStruct.mod;
    in
    runCommand "vendor-env"
      {
        nativeBuildInputs = [ go ];
        json = toJSON (filterAttrs (n: _: n != defaultPackage) modulesStruct.mod);

        sources = toJSON (filterAttrs (n: _: n != defaultPackage) sources);

        passthru = {
          inherit sources;
        };

        passAsFile = [
          "json"
          "sources"
        ];
      }
      (''
        mkdir vendor

        export GOCACHE=$TMPDIR/go-cache
        export GOPATH="$TMPDIR/go"

        ${internal.symlink}
        ${concatStringsSep "\n" localReplaceCommands}
        ${concatStringsSep "\n" workspaceVendorCommands}

        mv vendor $out
      '');

  mkGoCacheEnv =
    {
      go,
      modulesStruct,
      goMod,
      vendorEnv,
      depFilesPath,
      isWorkspace ? false,
      # Build environment parameters (should match buildGoApplication)
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      CGO_ENABLED ? go.CGO_ENABLED,
      tags ? [ ],
      ldflags ? [ ],
      allowGoReference ? false,
    }:
    let
      # Check if cachePackages is defined in modulesStruct
      cachePackages = modulesStruct.cachePackages or [ ];
      hasCachePackages = cachePackages != [ ];
    in
    stdenv.mkDerivation {
      name = "go-cache-env";

      dontUnpack = true;

      nativeBuildInputs = [
        rsync
        go
        goConfigHook
        gnutar
        zstd
      ]
      ++ nativeBuildInputs;

      inherit buildInputs;

      inherit (go) GOOS GOARCH;
      inherit CGO_ENABLED;

      # Pass allowGoReference to hook for GOFLAGS configuration
      allowGoReference = if allowGoReference then "1" else "";

      # Pass tags and ldflags (used by hooks)
      inherit tags ldflags;

      goVendorDir = vendorEnv;

      # Change the working directory in prePatch so GoConfigHook sets up
      # vendor/ at the right location
      prePatch =
        if isWorkspace then
          ''
            # Reconstruct workspace structure for cache compilation
            cp -r ${depFilesPath} source
            chmod -R +w source
            cd source
          ''
        else
          ''
            # Create a working directory (Go ignores go.mod in /build)
            mkdir -p source
            cd source

            # Copy go.mod and go.sum from filtered source
            cp ${depFilesPath}/go.mod ./go.mod
            cp ${depFilesPath}/go.sum ./go.sum 2>/dev/null || touch go.sum
          '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"
      '';

      buildPhase = ''
        runHook preBuild

        ${
          if hasCachePackages then
            ''
              echo "Building ${toString (builtins.length cachePackages)} packages to populate cache..."

              # Generate cache.go that imports all packages
              printf '%s\n' ${lib.escapeShellArgs cachePackages} | ${internal.cachegen} > cache.go

              cat cache.go

              # Build cache.go - Go will build all dependencies using its scheduler
              go build -v -mod=vendor cache.go || true

              echo "Cache population complete"
            ''
          else
            ''
              echo "No cache packages defined, skipping cache population"
            ''
        }

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        echo "Compressing Go build cache..."
        mkdir -p "$out"
        tar -cf - -C "$GOCACHE" . | zstd -T$NIX_BUILD_CORES -o "$out/cache.tar.zst"

        echo "Cache compressed to $out/cache.tar.zst"

        runHook postInstall
      '';
    };

  # Return a Go attribute and error out if the Go version is older than was specified in go.mod.
  selectGo =
    attrs: goMod:
    attrs.go or (
      if goMod == null then
        buildPackages.go
      else
        (
          let
            goVersion = goMod.go;
            goAttrs = lib.reverseList (
              builtins.filter (
                attr:
                lib.hasPrefix "go_" attr
                && (
                  let
                    try = builtins.tryEval buildPackages.${attr};
                  in
                  try.success && try.value ? version
                )
                && lib.versionAtLeast buildPackages.${attr}.version goVersion
              ) (lib.attrNames buildPackages)
            );
            goAttr = elemAt goAttrs 0;
          in
          (
            if goAttrs != [ ] then
              buildPackages.${goAttr}
            else
              throw "go.mod specified Go version ${goVersion}, but no compatible Go attribute could be found."
          )
        )
    );

  # Strip extra data that Go adds to versions, and fall back to a version based on the date if it's a placeholder value.
  # This is data that Nix can't handle in the version attribute.
  stripVersion =
    version:
    let
      parts = elemAt (split "(\\+|-)" (removePrefix "v" version));
      v = parts 0;
      d = parts 2;
    in
    if v != "0.0.0" then
      v
    else
      "unstable-"
      + (concatStringsSep "-" [
        (substring 0 4 d)
        (substring 4 2 d)
        (substring 6 2 d)
      ]);

  mkGoEnv =
    {
      pwd,
      toolsGo ? pwd + "/tools.go",
      modules ? pwd + "/gomod2nix.toml",
      allowGoReference ? false,
      ...
    }@attrs:
    let
      goMod = parseGoMod (readFile "${toString pwd}/go.mod");
      modulesStruct = fromTOML (readFile modules);

      go = selectGo attrs goMod;

      vendorEnv = mkVendorEnv {
        inherit
          go
          goMod
          modulesStruct
          pwd
          ;
      };

    in
    stdenv.mkDerivation (
      removeAttrs attrs [
        "pwd"
        "allowGoReference"
      ]
      // {
        name = "${baseNameOf goMod.module}-env";

        dontUnpack = true;
        dontConfigure = true;
        dontInstall = true;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference = if allowGoReference then "1" else "";

        nativeBuildInputs = [
          rsync
          goConfigHook
        ];

        propagatedBuildInputs = [ go gomod2nix goSyncWrapHook ];

        # Pass vendor directory to the setup hook
        goVendorDir = vendorEnv;

        preferLocalBuild = true;

        buildPhase = ''
          mkdir $out

          export GOPATH="$out"

        ''
        + optionalString (pathExists toolsGo) ''
          mkdir source
          cp ${pwd + "/go.mod"} source/go.mod
          cp ${pwd + "/go.sum"} source/go.sum
          cp ${toolsGo} source/tools.go
          cd source

          rsync -a -K --ignore-errors ${vendorEnv}/ vendor

          ${internal.install}
        '';
      }
    );

  buildGoApplication =
    {
      modules ? pwd + "/gomod2nix.toml",
      src ? pwd,
      pwd ? null,
      nativeBuildInputs ? [ ],
      allowGoReference ? false,
      meta ? { },
      passthru ? { },
      tags ? [ ],
      ldflags ? [ ],
      commit ?
        if src ? rev then
          src.rev
        else if src ? shortRev then
          src.shortRev
        else
          "unknown",
      disableGoCache ? false,

      ...
    }@attrs:
    let
      modulesStruct = if modules == null then { } else fromTOML (readFile modules);

      # Detect workspace: check for go.work at pwd
      goWorkPath = "${toString pwd}/go.work";
      hasWorkspace = pwd != null && pathExists goWorkPath;
      goWork = if hasWorkspace then parseGoWork (readFile goWorkPath) else null;

      # For workspaces, go.mod may not exist at pwd; use go.work's Go version
      goModPath = "${toString pwd}/go.mod";
      goMod = if pwd != null && pathExists goModPath then parseGoMod (readFile goModPath) else null;

      # For Go version selection, prefer go.mod, fall back to go.work
      goModForVersion =
        if goMod != null then
          goMod
        else if goWork != null then
          {
            go = goWork.go;
            module = "workspace";
          }
        else
          null;

      go = selectGo attrs goModForVersion;

      defaultPackage = modulesStruct.goPackagePath or "";

      vendorEnv =
        if modulesStruct != { } then
          mkVendorEnv {
            inherit
              defaultPackage
              go
              goWork
              modulesStruct
              pwd
              ;
            goMod = if goMod != null then goMod else { replace = { }; };
          }
        else
          null;

      # Filter source to only dependency files for cache derivation
      # Use fetched source when building from goPackagePath
      # When pwd is set but doesn't contain go.mod (goMod == null), use src instead
      depFilesSrc =
        if defaultPackage != "" then
          vendorEnv.passthru.sources.${defaultPackage}
        else if goMod != null then
          pwd
        else
          src;

      depFilesPath =
        if (!disableGoCache && modulesStruct != { } && depFilesSrc != null) then
          if hasWorkspace then
            # For workspaces, include go.work and all module go.mod/go.sum files
            lib.cleanSourceWith {
              src = pwd;
              filter =
                path: type:
                let
                  baseName = baseNameOf path;
                  relPath = removePrefix ((toString pwd) + "/") (toString path);
                in
                baseName == "go.work"
                || baseName == "go.mod"
                || baseName == "go.sum"
                || baseName == "gomod2nix.toml"
                # Allow intermediate directories for workspace modules
                || (
                  type == "directory"
                  && builtins.any (
                    u:
                    let
                      cleanU = removePrefix "./" u;
                    in
                    lib.hasPrefix relPath cleanU || lib.hasPrefix cleanU relPath
                  ) goWork.use
                );
              name = "go-workspace-dep-files";
            }
          else
            lib.cleanSourceWith {
              src = depFilesSrc;
              filter =
                path: type:
                let
                  baseName = baseNameOf path;
                in
                baseName == "go.mod" || baseName == "go.sum" || baseName == "gomod2nix.toml";
              name = "go-dep-files";
            }
        else
          null;

      cacheEnv =
        if (!disableGoCache && modulesStruct != { } && depFilesPath != null) then
          mkGoCacheEnv {
            inherit
              go
              modulesStruct
              vendorEnv
              depFilesPath
              tags
              ldflags
              allowGoReference
              ;
            isWorkspace = hasWorkspace;
            CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
            goMod = if goMod != null then goMod else { replace = { }; };
          }
        else
          null;

      pname = attrs.pname or baseNameOf defaultPackage;

      effectiveVersion =
        if attrs ? version then
          attrs.version
        else if defaultPackage != "" then
          stripVersion (modulesStruct.mod.${defaultPackage}).version
        else
          "dev";

      versionLdflags = [
        "-X main.version=${effectiveVersion}"
        "-X main.commit=${commit}"
      ];

      # Only used by the final build. Passing these to mkGoCacheEnv would
      # invalidate the cache hash on every commit without changing contents.
      effectiveLdflags = versionLdflags ++ ldflags;

    in
    stdenv.mkDerivation (
      optionalAttrs (defaultPackage != "") {
        inherit pname;
        version = stripVersion (modulesStruct.mod.${defaultPackage}).version;
        src = vendorEnv.passthru.sources.${defaultPackage};
      }
      // optionalAttrs (hasAttr "subPackages" modulesStruct) {
        subPackages = modulesStruct.subPackages;
      }
      // attrs
      // {
        nativeBuildInputs = [
          go
          goConfigHook
          goBuildHook
          goCheckHook
          goInstallHook
        ]
        ++ nativeBuildInputs;

        inherit (go) GOOS GOARCH;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference = if allowGoReference then "1" else "";

        goVendorDir = if vendorEnv != null then vendorEnv else "";
        goCacheDir = if cacheEnv != null then cacheEnv else "";
        inherit tags;
        ldflags = effectiveLdflags;
        modRoot = attrs.modRoot or "";

        preBuild = attrs.preBuild or "";

        doCheck = attrs.doCheck or true;

        strictDeps = true;

        disallowedReferences = optional (!allowGoReference) go;

        passthru = {
          inherit go vendorEnv hooks;
          goCacheEnv = cacheEnv;
        }
        // optionalAttrs (hasAttr "goPackagePath" modulesStruct) {

          updateScript =
            let
              generatorArgs =
                if hasAttr "subPackages" modulesStruct then
                  concatStringsSep " " (
                    map (subPackage: modulesStruct.goPackagePath + "/" + subPackage) modulesStruct.subPackages
                  )
                else
                  modulesStruct.goPackagePath;

            in
            writeScript "${pname}-updater" ''
              #!${runtimeShell}
              ${optionalString (pwd != null) "cd ${toString pwd}"}
              exec ${gomod2nix}/bin/gomod2nix generate ${generatorArgs}
            '';

        }
        // passthru;

        inherit meta;
      }
    );

in
{
  inherit
    buildGoApplication
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    hooks
    ;
}
