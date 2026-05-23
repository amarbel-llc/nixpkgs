---
status: draft
date: 2026-05-23
promotion-criteria: |
  draft → proposed: at least one producer in this fork adopts `pkgs.goSourceFilter`
  for its `packages.${system}.go-pkgs` flake output; FDR-0003 and FDR-0004 are
  thinned to reference this RFC for normative spec.

  proposed → experimental: tommy (or another producer) publishes
  `packages.${system}.go-pkgs = pkgs.goSourceFilter { src = self; }` and a
  consumer (madder) builds successfully against the filtered output.

  experimental → testing: lazy-trees interaction and mkGoEnv parity for the
  filter are empirically verified.

  testing → accepted: at least two producers carry filtered `go-pkgs` for a
  release cycle without reverting to bare `self`.
---

# RFC 0001 — flake-input-go_mod protocol

## Abstract

(filled in Task 2)

## Terminology

(filled in Task 2)

## Protocol overview

(filled in Task 2)

## Consumer interface: `goFlakeInputs`

(filled in Task 3)

## Producer interface: `packages.${system}.go-pkgs` and `mkGoPkgs`

(filled in Task 4)

## Source filtering: `goSourceFilter`

(filled in Task 5)

## Consumer convention: `gomod.nix` colocation

(filled in Task 6)

## Multi-producer closures: `follows` + passthru inheritance

(filled in Task 7)

## Limitations

(filled in Task 8)

## Open questions

(filled in Task 8)

## References

(filled in Task 8)
