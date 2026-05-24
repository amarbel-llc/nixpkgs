# Source-tree filter for the go-pkgs producer convention (RFC 0001).
# Returns a *path* (the filtered store path of `src`) that keeps
# Go-relevant regular files (matched against the default keep-set or
# caller-supplied `extras` regex patterns). Directories are always
# traversed so the filter composes on deep trees; empty directories
# that have no matching descendants are preserved in the output
# (harmless for `go build`).
#
# Patterns are POSIX extended regex (builtins.match semantics), NOT
# globs. Examples: "^doc/.*" "^VERSION$" ".*\\.tmpl$".
#
# Implementation notes:
#
# 1. `lib.sources.sourceByRegex` applies the regex list to both files
#    and directories, so deep trees fail to traverse unless every
#    intermediate directory also matches some regex. To keep the
#    user-facing contract simple (the regex list is matched against
#    files only) this helper applies the directory-always-allow rule
#    in its own predicate.
#
# 2. `lib.cleanSourceWith` returns an attrset `{ _isLibCleanSourceWith;
#    origSrc; filter; name; outPath; }`, which the flake schema rejects
#    in the `packages.<system>.<name>` slot ("expected ... a derivation
#    or path but found a set"). `builtins.path` is the lower-level
#    primitive that returns an actual path value, which the flake
#    schema accepts directly. Producers can then write
#    `packages.${system}.go-pkgs = pkgs.goSourceFilter { src = self; };`
#    without a `.outPath` coercion (see amarbel-llc/nixpkgs#38, #43).
{ lib }:
let
  defaultRegexes = [
    ".*\\.go$"
    "^go\\.mod$"
    "^go\\.sum$"
    "^gomod2nix\\.toml$"
  ];

  goSourceFilter =
    {
      src,
      extras ? [ ],
    }:
    let
      regexes = defaultRegexes ++ extras;
      # Unwrap an already-filtered src so the relative-path computation
      # stays anchored at the original source root when composing.
      origSrc = if src ? origSrc then src.origSrc else src;
    in
    builtins.path {
      name = src.name or "source";
      path = origSrc;
      filter =
        path: type:
        let
          relPath = lib.removePrefix (toString origSrc + "/") (toString path);
        in
        type == "directory" || lib.any (re: builtins.match re relPath != null) regexes;
    };

  goSourceFilterMiddleware = src: goSourceFilter { inherit src; };
in
{
  inherit goSourceFilter goSourceFilterMiddleware;
}
