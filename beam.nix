# Canonical BEAM shell configuration.
# Single source of truth for Elixir/Gleam/OTP dev environments.
#
# Consumed by:
#   - ~/.flakes/flake.nix (shared devShells)
#   - project flakes via `inputs.flakes` (glue, body, gestalt, etc.)
#   - ~/.os deploy scripts
#
# Authoritative. Hardlinked from ~/.os.

{ pkgs, system }:

let
  # ── Packages ───────────────────────────────────────────────────────────────
  beamPkgs = pkgs.beam.packages.erlang_27;
  elixir   = beamPkgs.elixir_1_18;
  erlang   = pkgs.erlang_27;
  gleam    = pkgs.gleam;
  rebar3   = beamPkgs.rebar3;

  elixirTools = [ elixir erlang rebar3 ];
  gleamTools  = [ gleam erlang rebar3 ];

  # ── Shell hooks ────────────────────────────────────────────────────────────

  # Isolate mix/hex state per project. MIX_BUILD_ROOT per platform avoids
  # recompilation when source is shared across architectures (virtiofs).
  mixHook = ''
    export MIX_HOME=$PWD/.nix-mix
    export MIX_REBAR3=${rebar3}/bin/rebar3
    export HEX_HOME=$PWD/.nix-hex
    export MIX_BUILD_ROOT=$PWD/_build-${system}
    export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
  '';

  # Worktree guard: enforces branch isolation for agents.
  # Runs silently in main worktree (human use); enforces in feature worktrees.
  worktreeGuard = ''
    _worktree_guard() {
      if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return 0
      fi
      if [ -n "$(git rev-parse --show-superproject-working-tree 2>/dev/null)" ]; then
        return 0
      fi
      _wt_main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
      _wt_real=$(pwd -P 2>/dev/null)
      _wt_main_real=$(cd "''${_wt_main}" 2>/dev/null && pwd -P)
      if [ "''${_wt_real}" != "''${_wt_main_real}" ]; then
        _wt_branch=$(git branch --show-current 2>/dev/null)
        if [ -z "''${_wt_branch}" ]; then
          echo "worktree guard: detached HEAD — agents must be on a named branch"
          return 1
        fi
        if [ "''${_wt_branch}" = "main" ] || [ "''${_wt_branch}" = "master" ]; then
          echo "worktree guard: agents must use a feature branch, not ''${_wt_branch}"
          return 1
        fi
        export AGENT_BRANCH="''${_wt_branch}"
        export GLUE_SESSION="''${GLUE_SESSION:-''${_wt_branch}}"
      fi
    }
    _worktree_guard || exit 1
    unset -f _worktree_guard
  '';

  # Glue bus connect: locates glue binary, connects to bus, exports helpers.
  # Soft-warns if daemon unreachable — safe for CI and offline contexts.
  glueConnect = ''
    export GLUE_NODE="''${GLUE_NODE:-glue@localhost}"
    if [ -f "''${HOME}/.local/libexec/glue/bin/glue" ]; then
      export GLUE_BIN="''${HOME}/.local/libexec/glue/bin/glue"
      export GLUE_COOKIE="$(cat ''${HOME}/.local/libexec/glue/releases/COOKIE 2>/dev/null || echo glue_local)"
    elif [ -f "''${HOME}/dev/projects/glue/_build/prod/rel/glue/bin/glue" ]; then
      export GLUE_BIN="''${HOME}/dev/projects/glue/_build/prod/rel/glue/bin/glue"
      export GLUE_COOKIE="$(cat ''${HOME}/dev/projects/glue/_build/prod/rel/glue/releases/COOKIE 2>/dev/null || echo glue_local)"
    else
      export GLUE_BIN=""
      export GLUE_COOKIE="glue_local"
    fi
    export GLUE_ACTOR="''${GLUE_ACTOR:-agent-$$}"
    export GLUE_SESSION="''${GLUE_SESSION:-main-$(date +%Y-%m-%d)}"

    if [ -z "$GLUE_BIN" ] || [ ! -f "$GLUE_BIN" ]; then
      true  # silent — glue not installed yet
    elif ! "$GLUE_BIN" rpc "node()" 2>/dev/null | grep -q "glue@"; then
      true  # silent — daemon not running
    else
      "$GLUE_BIN" connect --actor "$GLUE_ACTOR" --session "$GLUE_SESSION" 2>/dev/null
    fi

    glue-peek()    { "$GLUE_BIN" peek --session "''${1:-$GLUE_SESSION}" "''${@:2}"; }
    glue-drain()   { "$GLUE_BIN" drain --session "''${1:-$GLUE_SESSION}" "''${@:2}"; }
    glue-status()  {
      if "$GLUE_BIN" rpc "node()" 2>/dev/null | grep -q "glue@"; then echo "glue: up"
      else echo "glue: unreachable"; fi
    }
    glue-message() { "$GLUE_BIN" message --actor "$GLUE_ACTOR" --session "$GLUE_SESSION" --text "$1"; }
    glue-dm()      { "$GLUE_BIN" dm --actor "$GLUE_ACTOR" --session "$GLUE_SESSION" --to "$1" --text "$2"; }
    export -f glue-peek glue-drain glue-status glue-message glue-dm
  '';

in {
  inherit elixir erlang gleam rebar3 beamPkgs;
  inherit elixirTools gleamTools;
  inherit mixHook worktreeGuard glueConnect;

  # ── Ready-made shell hooks ─────────────────────────────────────────────────

  # Elixir project: mix isolation + worktree guard + glue
  elixirHook = mixHook + worktreeGuard + glueConnect;

  # Gleam project: worktree guard + glue (no mix)
  gleamHook = worktreeGuard + glueConnect;

  # Full BEAM: everything
  beamHook = mixHook + worktreeGuard + glueConnect;
}
