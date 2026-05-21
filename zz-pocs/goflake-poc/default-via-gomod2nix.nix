{
  buildGoApplication,
  pocLibSrc,
}:

# Phase 3: build the same consumer via gomod2nix's buildGoApplication.
#
# Phase 2 used nixpkgs's stock buildGoModule with `vendorHash = null` +
# `proxyVendor = true` + a preBuild symlink. This phase probes whether the
# fork's buildGoApplication tolerates the same flake-input-bridge pattern
# (replace => ./.flake-inputs/poc-lib + runtime symlink).
#
# Key behavioral difference (from pkgs/build-support/gomod2nix/default.nix:
# 198-205): buildGoApplication parses goMod.replace at nix-eval time and
# builds the vendor/ tree by running `ln -s ${pwd + "/${value.path}"}
# vendor/<module>` — i.e. it bakes the replace target into the derivation
# as a path. If `.flake-inputs/poc-lib` doesn't exist at eval time, the
# vendor symlink dangles (or eval errors).

buildGoApplication {
  pname = "goflake-poc-via-gomod2nix";
  version = "0.1.0";
  src = ./.;
  pwd = ./.;

  # Minimal gomod2nix.toml (just `schema = 3`, no [mod] entries) — the
  # only require is replaced to a local path. We still need a non-empty
  # toml to make buildGoApplication call mkVendorEnv, which is what runs
  # the localReplaceCommands that symlink replaces into vendor/.
  modules = ./gomod2nix.toml;

  subPackages = [ "." ];

  # Same symlink trick as phase 2. The question is whether
  # buildGoApplication's vendor-building runs before or after preBuild,
  # and whether it walks the source's `.flake-inputs/` (gitignored) at
  # eval time.
  preBuild = ''
    mkdir -p .flake-inputs
    ln -sfn ${pocLibSrc} .flake-inputs/poc-lib
  '';
}
