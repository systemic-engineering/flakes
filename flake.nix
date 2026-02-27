{
  description = "Shared flake infrastructure for systemic-engineering projects";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── Base tools ───────────────────────────────────────────────────────
        baseTools = [
          pkgs.git
          pkgs.just
          pkgs.jq
          pkgs.curl
          pkgs.dhall
          pkgs.dhall-json
        ];

        # ── BEAM / Elixir ────────────────────────────────────────────────────
        beamPkgs = pkgs.beam.packages.erlang_27;
        elixir   = beamPkgs.elixir_1_18;

        elixirTools = [
          elixir
          pkgs.erlang_27
          beamPkgs.rebar3
        ];

        # ── Gleam ────────────────────────────────────────────────────────────
        gleamTools = [
          pkgs.gleam
          pkgs.erlang_27
          beamPkgs.rebar3
        ];

        # ── Shell hooks ──────────────────────────────────────────────────────
        baseShellHook = ''
          export LANG=en_US.UTF-8
        '';

        # Isolate mix/hex state per project to avoid cross-contamination.
        elixirMixHook = ''
          export MIX_HOME=$PWD/.nix-mix
          export MIX_REBAR3=${beamPkgs.rebar3}/bin/rebar3
          export HEX_HOME=$PWD/.nix-hex
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
        '';

      in {
        devShells = {
          # Minimal: git, just, jq, dhall.
          default = pkgs.mkShell {
            buildInputs = baseTools;
            shellHook   = baseShellHook;
          };

          # Elixir 1.18 / OTP 27 + base tools.
          elixir = pkgs.mkShell {
            buildInputs = baseTools ++ elixirTools;
            shellHook   = baseShellHook + elixirMixHook;
          };

          # Gleam + OTP 27 + base tools.
          gleam = pkgs.mkShell {
            buildInputs = baseTools ++ gleamTools;
            shellHook   = baseShellHook;
          };

          # Full BEAM: Elixir + Gleam + base tools.
          beam = pkgs.mkShell {
            buildInputs = baseTools ++ elixirTools ++ gleamTools;
            shellHook   = baseShellHook + elixirMixHook;
          };
        };
      });
}
