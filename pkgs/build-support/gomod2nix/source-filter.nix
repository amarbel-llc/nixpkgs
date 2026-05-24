# Source-tree filter for the go-pkgs producer convention (RFC 0001).
# Returns a cleanSourceWith-filtered view of `src` that keeps Go-relevant
# regular files (matched against the default keep-set or caller-supplied
# `extras` regex patterns). Directories are always traversed so the filter
# composes on deep trees; empty directories that have no matching
# descendants are preserved in the output (harmless for `go build`).
#
# Patterns are POSIX extended regex (builtins.match semantics), NOT
# globs. Examples: "^doc/.*" "^VERSION$" ".*\\.tmpl$".
#
# Implementation note: `lib.sources.sourceByRegex` applies the regex
# list to both files and directories, so deep trees fail to traverse
# unless every intermediate directory also matches some regex. To keep
# the user-facing contract simple (the regex list is matched against
# files only) the filter here uses `lib.cleanSourceWith` directly,
# always permitting directories to be traversed and applying the
# regex set only to regular files. The defaultRegexes + extras
# semantics are otherwise identical to `sourceByRegex`'s.
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
      origSrc = if src ? origSrc then src.origSrc else src;
    in
    lib.cleanSourceWith {
      inherit src;
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
