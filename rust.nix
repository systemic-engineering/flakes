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

#   4. A consumer that pins its own toolchain passes it as `toolchain`
#      (through lib.mkRust). Then that toolchain is the only one: rustTools,
#      RUST_SRC_PATH and the hook all point at it. Otherwise the shell would
#      carry two compilers and the one the shell tests isn't the one that
#      ships (nix-button, 2026-10-31).

{ pkgs, system, rustOverlay ? null, toolchain ? null, worktreeGuard ? "", glueConnect ? "" }:

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
  hasOverlay = toolchain != null || rustOverlay != null;

  pinnedToolchain = if toolchain != null then toolchain
  else if rustOverlay != null then
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

  # cargo-llvm-cov 0.9.0 in nixpkgs 58deea65 fails its own test suite on
  # aarch64-darwin (14 of 20 tests; the instrumented test binaries crash), so
  # Hydra has no build of it and a local one dies in checkPhase. Same
  # override as prism and mirror; coverage stays gated on measured numbers in
  # each consumer. Only 0.9.0, so consumers following an older nixpkgs keep
  # the cached build. Drop it once nixpkgs builds the tool.
  cargoLlvmCov =
    if pkgs.cargo-llvm-cov.version == "0.9.0"
    then pkgs.cargo-llvm-cov.overrideAttrs (_: { doCheck = false; })
    else pkgs.cargo-llvm-cov;

  # When using rust-overlay, the single derivation provides all tools.
  # When using nixpkgs, we list them individually.
  rustTools = if hasOverlay then [
    pinnedToolchain
    pkgs.pkg-config
    cargoLlvmCov
    pkgs.llvmPackages.llvm
  ] else [
    pkgs.rustc
    pkgs.cargo
    pkgs.clippy
    pkgs.rustfmt
    pkgs.rust-analyzer
    pkgs.pkg-config
    cargoLlvmCov
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
  inherit rustTools rustSrc cargoHook pinnedVersion;

  # Rust project: cargo isolation + worktree guard + glue
  rustHook = cargoHook + worktreeGuard + glueConnect;
}
