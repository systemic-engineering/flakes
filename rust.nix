# Canonical Rust shell configuration.
# Single source of truth for Rust dev environments.
#
# Consumed by:
#   - ~/.flakes/flake.nix (shared devShells)
#   - project flakes via `inputs.flakes` (fragmentation, etc.)
#
# Accepts shared hooks from beam.nix to avoid duplication.
#
# KEY DESIGN DECISIONS (cache stability):
#   1. Rust toolchain is provided via oxalica/rust-overlay with a PINNED
#      version. This means `rustc --version --verbose` output is STABLE
#      across nixpkgs updates, preventing cargo fingerprint invalidation.
#   2. CARGO_HOME points to a persistent per-user location (~/.cargo),
#      NOT per-project. The registry cache is shared across all projects.
#   3. CARGO_TARGET_DIR defaults to per-user location but can be overridden
#      by the user's cargo config.toml (which it already is).

{ pkgs, system, rustOverlay ? null, worktreeGuard ? "", glueConnect ? "" }:

let
  # ── Toolchain ───────────────────────────────────────────────────────────────
  # Use rust-overlay for a PINNED toolchain when available.
  # This prevents nixpkgs updates from changing the rustc store path/version,
  # which would invalidate all cargo fingerprints in target directories.
  #
  # The pin is the Rust RELEASE version (e.g. "1.94.0"). Updating this is
  # an explicit, deliberate action — not a side effect of `nix flake update`.
  pinnedVersion = "1.94.0";

  # When rust-overlay is available, use it for the pinned toolchain.
  # Otherwise fall back to nixpkgs (less stable but still functional).
  hasOverlay = rustOverlay != null;

  pinnedToolchain = if hasOverlay then
    rustOverlay.rust-bin.stable.${pinnedVersion}.default.override {
      extensions = [ "rust-src" "rust-analyzer" "clippy" "llvm-tools-preview" ];
    }
  else
    null;

  # Individual tools: either from the pinned overlay or from nixpkgs.
  rustc'       = if hasOverlay then pinnedToolchain else pkgs.rustc;
  cargo'       = if hasOverlay then pinnedToolchain else pkgs.cargo;
  clippy'      = if hasOverlay then pinnedToolchain else pkgs.clippy;
  rustfmt'     = if hasOverlay then pinnedToolchain else pkgs.rustfmt;
  rustAnalyzer = if hasOverlay then pinnedToolchain else pkgs.rust-analyzer;

  rustSrc = if hasOverlay then
    "${pinnedToolchain}/lib/rustlib/src/rust/library"
  else
    pkgs.rustPlatform.rustLibSrc;

  # When using rust-overlay, the single derivation provides all tools.
  # When using nixpkgs, we list them individually.
  rustTools = if hasOverlay then [
    pinnedToolchain
    pkgs.pkg-config
    pkgs.cargo-llvm-cov
    pkgs.llvmPackages.llvm
  ] else [
    pkgs.rustc
    pkgs.cargo
    pkgs.clippy
    pkgs.rustfmt
    pkgs.rust-analyzer
    pkgs.pkg-config
    pkgs.cargo-llvm-cov
    pkgs.llvmPackages.llvm
  ];

  # ── Shell hook ─────────────────────────────────────────────────────────────
  # CARGO_HOME is persistent and shared across projects.
  # The registry index and crate sources live here — downloaded once, used everywhere.
  # CARGO_TARGET_DIR respects the user's ~/.cargo/config.toml setting.
  cargoHook = ''
    export CARGO_HOME="$HOME/.cargo"
    export PATH="$CARGO_HOME/bin:$PATH"
    export LLVM_COV=${pkgs.llvmPackages.llvm}/bin/llvm-cov
    export LLVM_PROFDATA=${pkgs.llvmPackages.llvm}/bin/llvm-profdata
    export RUST_SRC_PATH=${rustSrc}
  '';

in {
  inherit rustTools cargoHook pinnedVersion;

  # Rust project: cargo isolation + worktree guard + glue
  rustHook = cargoHook + worktreeGuard + glueConnect;
}
