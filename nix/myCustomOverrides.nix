# myCustomOverrides.nix
#
# This file provides overrides for packages that need to come from nixpkgs
# instead of uv2nix. Common use cases:
#   - torch (complex build requirements, system libraries)
#   - pyside6/shiboken6 (Qt bindings with many dependencies)
#   - Any package that needs specific nixpkgs versions
#
# Usage: Uncomment and modify the overrides as needed.

{ pkgs, python }:

final: prev: {
  # Example: Force torch from nixpkgs instead of uv2nix
  # torch = pkgs.python312Packages.torch;

  # Example: Force PySide6 from nixpkgs
  # pyside6 = pkgs.python312Packages.pyside6;
  # shiboken6 = pkgs.python312Packages.shiboken6;

  # Add custom packages here if needed
  # vulkan = pkgs.python312Packages.vulkan;
}
