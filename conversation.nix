# Canonical conversation environment.
# Provides the `conversation` binary for evaluating .conv packages.
#
# Consumed by:
#   - ~/.flakes/flake.nix (shared devShells)
#   - garden package flakes via `inputs.flakes`
#
# The conversation binary is built from dev/projects/conversation.
# Path deps (fragmentation) resolve from the same workspace.

{ pkgs, system, rustTools, cargoHook }:

let
  # ── Packages ───────────────────────────────────────────────────────────────
  # Conversation needs everything Rust needs plus crypto/encoding deps.
  conversationTools = rustTools ++ [
    pkgs.openssl
    pkgs.zlib
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.libiconv
  ];

  # ── Shell hook ─────────────────────────────────────────────────────────────
  # Locates the conversation binary from the workspace.
  # Checks release first, then debug. Warns if not found.
  conversationHook = cargoHook + ''
    _conv_find() {
      local base="''${CONVERSATION_PROJECT:-$HOME/dev/projects/conversation}"
      local bin=""
      if [ -f "$base/target/release/conversation" ]; then
        bin="$base/target/release"
      elif [ -f "$base/target/debug/conversation" ]; then
        bin="$base/target/debug"
      fi
      if [ -n "$bin" ]; then
        export PATH="$bin:$PATH"
        export CONVERSATION_BIN="$bin/conversation"
      fi
    }
    _conv_find
    unset -f _conv_find
  '';

in {
  inherit conversationTools conversationHook;
}
