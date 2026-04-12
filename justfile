# vim: ft=just

default: build-changed

# Build packages changed relative to master
build-changed:
    #!/usr/bin/env bash
    set -euo pipefail

    changed_pkgs=$(
        git diff --name-only master -- pkgs/by-name/ \
        | sed -n 's|^pkgs/by-name/[a-z0-9_-]\{2\}/\([^/]\+\)/.*|\1|p' \
        | sort -u
    )

    if [[ -z "$changed_pkgs" ]]; then
        gum log --level info "no changed by-name packages detected"
        exit 0
    fi

    gum log --level info "changed packages:" $changed_pkgs

    failed=()
    for pkg in $changed_pkgs; do
        gum log --level info "building $pkg"
        if NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths ".#$pkg"; then
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
    NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths ".#{{ pkg }}"
