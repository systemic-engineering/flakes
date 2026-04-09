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
  rustSrc = pkgs.rustPlatform.rustLibSrc;

  rustTools = [
    pkgs.rustc
    pkgs.cargo
    pkgs.clippy
    pkgs.rustfmt
    pkgs.rust-analyzer
    pkgs.pkg-config
    # Coverage — required for `just coverage` (--fail-under-lines 100)
    pkgs.cargo-llvm-cov
    pkgs.llvmPackages.llvm
  ];

  # ── Shell hook ─────────────────────────────────────────────────────────────
  # Isolate cargo state per project.
  cargoHook = ''
    export CARGO_HOME=$PWD/.nix-cargo
    export CARGO_TARGET_DIR=''${CARGO_TARGET_DIR:-$HOME/.cargo-target}
    export PATH=$CARGO_HOME/bin:$PATH
    export LLVM_COV=${pkgs.llvmPackages.llvm}/bin/llvm-cov
    export LLVM_PROFDATA=${pkgs.llvmPackages.llvm}/bin/llvm-profdata
    export RUST_SRC_PATH=${rustSrc}
  '';

in {
  inherit rustTools cargoHook;

  # Rust project: cargo isolation + worktree guard + glue
  rustHook = cargoHook + worktreeGuard + glueConnect;
}
