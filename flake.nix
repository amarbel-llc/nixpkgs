{
  description = "amarbel-llc overlay flake — fork-specific package additions and pins on top of nixpkgs.";

  inputs = {
    nixpkgs-master.url = "github:NixOS/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";

    # bun2nix — only needed for its CLI binary, which the bun2nix-lint
    # stack regen / drift-guard plumbing wraps. The Nix library
    # functions and the cacheEntryCreator Zig binary live under
    # pkgs/build-support/bun2nix/ in-tree.
    bun2nix.url = "github:nix-community/bun2nix";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs-master";

    # batman — bats wrapper with bundled support libraries, consumed by
    # the bun-dev devShell. Does NOT follow nixpkgs-master: nokogiri
    # (a ronn dep) fails to build against nixpkgs-unstable. See
    # amarbel-llc/bats#100.
    bats.url = "github:amarbel-llc/bats";
  };

  outputs =
    { self, nixpkgs-master, bun2nix, bats }:
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

          # -- bun2nix test fixtures --
          # Exercise buildBunBinary / buildZxScript / buildZxScriptFromFile
          # against pinned source trees so the surface area is build-tested
          # on every flake check. Lint-relevant fixtures are also referenced
          # by the lint-rejects-process-exit smoke check below.

          test-zx-basic = pkgs.buildZxScript {
            pname = "test-zx-basic";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/zx-basic;
          };

          test-zx-extra-deps = pkgs.buildZxScript {
            pname = "test-zx-extra-deps";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/zx-extra-deps;
            extraDeps = {
              "chalk@5.4.1" = pkgs.fetchurl {
                url = "https://registry.npmjs.org/chalk/-/chalk-5.4.1.tgz";
                hash = "sha512-zgVZuo2WcZgfUEmsn6eO3kINexW8RAE4maiQ8QNs8CtpPCSyMiYsULR3HQYkm3w8FIA3SberyMJMSldGsW+U3w==";
              };
            };
          };

          test-zx-from-file = pkgs.buildZxScriptFromFile {
            pname = "test-zx-from-file";
            version = "0.0.1";
            script = ./pkgs/build-support/bun2nix/tests/zx-from-file/index.ts;
          };

          # Lint passes: `process.exitCode = N; return;` (the recommended pattern).
          test-bin-no-process-exit = pkgs.buildBunBinary {
            pname = "test-bin-no-process-exit";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/bin-no-process-exit;
          };

          # Lint passes: `process.exit()` allowed via inline eslint-disable.
          test-bin-process-exit-disabled = pkgs.buildBunBinary {
            pname = "test-bin-process-exit-disabled";
            version = "0.0.1";
            src = ./pkgs/build-support/bun2nix/tests/bin-process-exit-disabled;
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          bun2nixCli = bun2nix.packages.${system}.bun2nix;
          regenLintStack = import ./pkgs/build-support/bun2nix/lint/regen.nix {
            inherit pkgs;
            bun = pkgs.bun;
            bun2nix = bun2nixCli;
          };
        in
        {
          regen-bun2nix-lint-stack = {
            type = "app";
            program = "${regenLintStack}/bin/regen-bun2nix-lint-stack";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          bun2nixCli = bun2nix.packages.${system}.bun2nix;
        in
        {
          claude-code = pkgs.claude-code;
          gomod2nix = pkgs.gomod2nix;
          gomod2nix-man = pkgs.gomod2nix-man;
          nix-man = pkgs.nix.man;

          bun2nix-lint-stack-up-to-date = import ./pkgs/build-support/bun2nix/lint/check.nix {
            inherit pkgs;
            bun2nix = bun2nixCli;
            bunLock = ./pkgs/build-support/bun2nix/lint/bun.lock;
            bunNix = ./pkgs/build-support/bun2nix/lint/bun.nix;
          };

          # Smoke check: confirm the lint stack actually fires on a
          # known-bad fixture. Targets `.passthru.lint` because
          # `testBuildFailure'` can only catch failures from the
          # wrapped derivation's own builder — failures in the lint
          # derivation cascade past the wrapper and bundle.
          bun2nix-lint-stack-rejects-process-exit = pkgs.testers.testBuildFailure' {
            drv =
              (pkgs.buildBunBinary {
                pname = "test-bin-process-exit-fail";
                version = "0.0.1";
                src = ./pkgs/build-support/bun2nix/tests/bin-process-exit-fail;
              }).passthru.lint;
            expectedBuilderLogEntries = [ "n/no-process-exit" ];
          };

          # Echo bun2nix fixtures as checks so flake check builds them.
          inherit (self.packages.${system})
            test-zx-basic
            test-zx-extra-deps
            test-zx-from-file
            test-bin-no-process-exit
            test-bin-process-exit-disabled
            ;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};

          # LLVM 21 — matches Bun's bootstrap.sh target.
          llvm = pkgs.llvm_21;
          clang = pkgs.clang_21;
          lld = pkgs.lld_21;

          # Node 24 — matches bootstrap.sh.
          nodejs = pkgs.nodejs_24;

          batman = bats.packages.${system}.batman;

          bunDevPackages =
            [
              # Core build tools
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.ccache

              # Compilers / toolchain
              clang
              llvm
              lld
              pkgs.gcc
              pkgs.rustc
              pkgs.cargo
              pkgs.go

              # Bun itself (for `bun bd`)
              pkgs.bun

              # Node.js 24
              nodejs

              # Other build deps from bootstrap.sh
              pkgs.python3
              pkgs.libtool
              pkgs.ruby
              pkgs.perl

              # Libraries
              pkgs.openssl
              pkgs.zlib
              pkgs.libxml2
              pkgs.libiconv

              # Dev tools
              pkgs.git
              pkgs.curl
              pkgs.wget
              pkgs.unzip
              pkgs.xz

              # Testing
              batman
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              # Debugging
              pkgs.gdb

              # Chromium runtime deps for Puppeteer tests (bootstrap.sh
              # lines 1397-1483).
              pkgs.libx11
              pkgs.libxcb
              pkgs.libxcomposite
              pkgs.libxcursor
              pkgs.libxdamage
              pkgs.libxext
              pkgs.libxfixes
              pkgs.libxi
              pkgs.libxrandr
              pkgs.libxrender
              pkgs.libxscrnsaver
              pkgs.libxtst
              pkgs.libxkbcommon
              pkgs.mesa
              pkgs.nspr
              pkgs.nss
              pkgs.cups
              pkgs.dbus
              pkgs.expat
              pkgs.fontconfig
              pkgs.freetype
              pkgs.glib
              pkgs.gtk3
              pkgs.pango
              pkgs.cairo
              pkgs.alsa-lib
              pkgs.at-spi2-atk
              pkgs.at-spi2-core
              pkgs.libgbm
              pkgs.liberation_ttf
              pkgs.atk
              pkgs.libdrm
              pkgs.libxshmfence
              pkgs.gdk-pixbuf
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              # New unified Apple SDK pattern.
              pkgs.apple-sdk
            ];
        in
        {
          # Build environment for amarbel-llc/bun. Direct port of the
          # Bun fork's `devShells.default` so the Bun fork can re-export
          # `nixpkgs.devShells.${system}.bun-dev` and drop its own copy.
          # FORTIFY_SOURCE is incompatible with Bun's build assumptions —
          # disable it.
          bun-dev =
            (pkgs.mkShell.override { stdenv = pkgs.clangStdenv; })
              {
                packages = bunDevPackages;
                hardeningDisable = [ "fortify" ];

                shellHook =
                  ''
                    export CC="${pkgs.lib.getExe clang}"
                    export CXX="${pkgs.lib.getExe' clang "clang++"}"
                    export AR="${llvm}/bin/llvm-ar"
                    export RANLIB="${llvm}/bin/llvm-ranlib"
                    export CMAKE_C_COMPILER="$CC"
                    export CMAKE_CXX_COMPILER="$CXX"
                    export CMAKE_AR="$AR"
                    export CMAKE_RANLIB="$RANLIB"
                    export CMAKE_SYSTEM_PROCESSOR="$(uname -m)"
                    export TMPDIR="''${TMPDIR:-/tmp}"
                  ''
                  + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                    export LD="${pkgs.lib.getExe' lld "ld.lld"}"
                    export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK:+$NIX_CFLAGS_LINK }-fuse-ld=lld"
                    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath bunDevPackages}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                  '';

                CMAKE_BUILD_TYPE = "Debug";
                ENABLE_CCACHE = "1";
              };
        }
      );

      nixosModules = nixpkgs-master.nixosModules;
    };
}
