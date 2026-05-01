# vim: ft=just

default: check-changed

# Eval-check changed packages (fast — catches nix errors without building)
check-changed:
    #!/usr/bin/env bash
    set -euo pipefail

    changed_pkgs=$(
        git diff --name-only master -- pkgs/by-name/ \
        | sed -n 's|^pkgs/by-name/[a-z0-9_-]\{2\}/\([^/]\+\)/.*|\1|p' \
        | sort -u
    )

    # Overlay pins: extract package names from changed pin files
    overlay_pkgs=$(
        git diff --name-only master -- overlays/pins/ \
        | sed -n 's|^overlays/pins/\(.*\)\.nix$|\1|p' \
        | sort -u
    )

    failed=()

    # amarbel-packages overlay: always check these (not discoverable by filename).
    # Checked separately since some are functions, not derivations.
    amarbel_pkgs=(fetchGgufModel buildBunBinary buildBunBinaries buildZxScript buildZxScriptFromFile fetchBunDeps mkBunDerivation writeBunApplication writeBunScriptBin gomod2nix)
    for pkg in "${amarbel_pkgs[@]}"; do
        gum log --level info "evaluating $pkg"
        if nix eval "path:.#$pkg" > /dev/null 2>&1; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed to evaluate"
            failed+=("$pkg")
        fi
    done

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | { grep -v '^$' || true; } | sort -u)

    if [[ -z "$all_pkgs" ]]; then
        if [[ ${#failed[@]} -gt 0 ]]; then
            gum log --level error "failed packages:" "${failed[@]}"
            exit 1
        fi
        gum log --level info "no changed packages or overlays detected"
        exit 0
    fi

    gum log --level info "checking packages:" $all_pkgs

    for pkg in $all_pkgs; do
        gum log --level info "evaluating $pkg"
        if nix eval --json "path:.#$pkg.version" > /dev/null 2>&1 \
           || nix eval --json "path:.#$pkg.name" > /dev/null 2>&1; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed to evaluate"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        gum log --level error "failed packages:" "${failed[@]}"
        exit 1
    fi

    gum log --level info "all changed packages evaluated successfully"

# Build changed packages (slow — full nix build)
build-changed:
    #!/usr/bin/env bash
    set -euo pipefail

    changed_pkgs=$(
        git diff --name-only master -- pkgs/by-name/ \
        | sed -n 's|^pkgs/by-name/[a-z0-9_-]\{2\}/\([^/]\+\)/.*|\1|p' \
        | sort -u
    )

    overlay_pkgs=$(
        git diff --name-only master -- overlays/pins/ \
        | sed -n 's|^overlays/pins/\(.*\)\.nix$|\1|p' \
        | sort -u
    )

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | { grep -v '^$' || true; } | sort -u)

    if [[ -z "$all_pkgs" ]]; then
        gum log --level info "no changed packages or overlays detected"
        exit 0
    fi

    gum log --level info "building packages:" $all_pkgs

    failed=()
    for pkg in $all_pkgs; do
        gum log --level info "building $pkg"
        if NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths "path:.#$pkg"; then
            gum log --level info "$pkg ok"
        else
            gum log --level error "$pkg failed"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        gum log --level error "failed packages:" "${failed[@]}"
        exit 1
    fi

    gum log --level info "all changed packages built successfully"

# Build a specific package by attribute name
build pkg:
    NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths "path:.#{{ pkg }}"

# [explore] Test the overlay-flake migration against amarbel-llc/maneater
# Clones into .tmp/maneater (or reuses), bumps the nixpkgs input, runs
# nix flake check + nix build .#default.
[group: 'explore']
test-overlay-against-maneater:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .tmp
    target=.tmp/maneater
    if [[ -d "$target/.git" ]]; then
      gum log --level info "reusing existing $target"
      git -C "$target" fetch --quiet origin
      git -C "$target" reset --hard origin/HEAD
    else
      gum log --level info "cloning maneater into $target"
      git clone --quiet git@github.com:amarbel-llc/maneater.git "$target"
    fi

    # Override maneater's nixpkgs input to the LOCAL worktree
    # so the test exercises the in-progress overlay flake, not whatever
    # has been pushed to origin.
    local_overlay="$(pwd)"
    cd "$target"
    gum log --level info "overriding nixpkgs input to path:$local_overlay"

    gum log --level info "running nix flake check (eval-only)"
    NIXPKGS_ALLOW_UNFREE=1 nix flake check \
      --keep-going --no-build --impure \
      --override-input nixpkgs "path:$local_overlay"
