# nixpkgs

This is a personal nixpkgs fork. The `origin` remote points at
`git@github.com:amarbel-llc/nixpkgs.git`; `upstream` points at
`https://github.com/NixOS/nixpkgs.git`.

## GitHub tools

`get-hubbed`'s default `repo_owner_name` resolves to
`<gh-authenticated-user>/<gh-default-name>` (i.e. `friedenberg/nixpkgs`),
which does not exist. Always pass `repo_owner_name: "amarbel-llc/nixpkgs"`
explicitly when calling `get-hubbed_issue-get`, `get-hubbed_issue-list`,
`get-hubbed_issue-comment`, `get-hubbed_issue-create`, etc.
