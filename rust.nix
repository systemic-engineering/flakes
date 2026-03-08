# Canonical Rust shell configuration.
# Single source of truth for Rust dev environments.
#
# Consumed by:
#   - ~/.flakes/flake.nix (shared devShells)
#   - project flakes via `inputs.flakes` (fragmentation, etc.)
#
# Accepts shared hooks from beam.nix to avoid duplication.

{ pkgs, system, worktreeGuard ? "", glueConnect ? "" }:

let
  # ── Packages ───────────────────────────────────────────────────────────────
  rustTools = [
    pkgs.rustc
    pkgs.cargo
    pkgs.clippy
    pkgs.rustfmt
    pkgs.rust-analyzer
    pkgs.pkg-config
  ];

  # ── Shell hook ─────────────────────────────────────────────────────────────
  # Isolate cargo state per project.
  cargoHook = ''
    export CARGO_HOME=$PWD/.nix-cargo
    export PATH=$CARGO_HOME/bin:$PATH
  '';

in {
  inherit rustTools cargoHook;

  # Rust project: cargo isolation + worktree guard + glue
  rustHook = cargoHook + worktreeGuard + glueConnect;
}
