# Canonical NIF build configuration for fragmentation.
# Single source of truth for Rust/C deps needed to compile the
# fragmentation Rustler NIF (libgit2 + libssh2 + openssl).
#
# Consumed by:
#   - ~/.flakes/flake.nix (shared devShells)
#   - project flakes via `inputs.flakes` (glue, witness, fragmentation-repo)
#
# Separate from rust.nix because rust.nix is for pure Rust projects.
# NIF projects need the Rust toolchain PLUS C library deps for libgit2.

{ pkgs, system, rustTools }:

let
  # ── C library deps for libgit2-sys / libssh2-sys ───────────────────────────
  nativeLibs = [
    pkgs.cmake
    pkgs.git
    pkgs.openssl
    pkgs.libssh2
    pkgs.zlib
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.libiconv
  ];

  # ── Full NIF build deps: Rust toolchain + C libs ───────────────────────────
  # Does NOT include clippy/rustfmt/rust-analyzer — those are dev tools from
  # rust.nix, not build requirements.
  nifTools = [
    pkgs.rustc
    pkgs.cargo
    pkgs.pkg-config
  ] ++ nativeLibs;

  # ── Environment variables needed by the NIF build ──────────────────────────
  nifEnv = {
    LIBSSH2_SYS_USE_PKG_CONFIG = "1";
  };

  # ── Shell hook ─────────────────────────────────────────────────────────────
  nifHook = ''
    export LIBSSH2_SYS_USE_PKG_CONFIG=1
  '';

in {
  inherit nifTools nifEnv nifHook nativeLibs;
}
