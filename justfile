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

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | grep -v '^$' | sort -u)

    if [[ -z "$all_pkgs" ]]; then
        gum log --level info "no changed packages or overlays detected"
        exit 0
    fi

    gum log --level info "checking packages:" $all_pkgs

    failed=()
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

    all_pkgs=$(echo -e "${changed_pkgs}\n${overlay_pkgs}" | grep -v '^$' | sort -u)

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
