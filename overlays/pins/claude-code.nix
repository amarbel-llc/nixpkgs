# Pin claude-code to 2.1.83 — later versions have TTY issues.
# Matches the pin in amarbel-llc/eng (nixpkgs SHA 5b471d29a8).
final: prev: {
  claude-code = prev.claude-code.overrideAttrs (old: rec {
    version = "2.1.83";
    src = prev.fetchzip {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
      hash = "sha256-tRrJ1UuolwI9d7ZOvBml0xJ9yZ3u57vGBfvF69artI8=";
    };
    npmDepsHash = "sha256-ll47m1mgOur+cbx8MkNRttSUCXyKKG5ZlceH1lhC5Y0=";
  });
}
