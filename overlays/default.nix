# Package pin overlays for this fork.
# Each file in pins/ overrides a single package.
# Add new pins as new files — no upstream files need modification.
lib:
let
  pinFiles = lib.filesystem.listFilesRecursive ./pins;
in
map import pinFiles
