# ci.nix — Continuous Integration as typed nix module
# OBC: Observable, Budget, Cascade
{ pkgs, lib }:
let
  # ── Types ─────────────────────────────────────────────────────────────
  # Matching @ci grammar and @ca grammar from mirror boot

  observable = lib.types.submodule {
    options = {
      paths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        description = "Paths to observe for changes.";
      };
      grammars = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "@code/rust" ];
        description = "Grammars to apply (@code/rust, @code/nix, @code/gleam).";
      };
    };
  };

  budget = lib.types.submodule {
    options = {
      holonomy = lib.mkOption {
        type = lib.types.float;
        default = 0.1;
        description = "Maximum holonomy before cascade triggers.";
      };
      convergence = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Maximum ticks from crystal before cascade.";
      };
      resolution = lib.mkOption {
        type = lib.types.float;
        default = 0.95;
        description = "Minimum resolution ratio (fraction of refs resolved).";
      };
    };
  };

  cascade = lib.types.submodule {
    options = {
      suggest = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Show suggestions when budget exceeded.";
      };
      enforce = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Auto-apply suggestions above confidence threshold.";
      };
      confidence = lib.mkOption {
        type = lib.types.float;
        default = 0.95;
        description = "Confidence threshold for auto-enforcement.";
      };
      notify = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "gutter" "ntfy" "spectral-db" "stdout" ]);
        default = [ "stdout" ];
        description = "Where to send notifications.";
      };
    };
  };

  # ── OBC ───────────────────────────────────────────────────────────────
  obc = lib.types.submodule {
    options = {
      observe = lib.mkOption { type = observable; };
      budget = lib.mkOption { type = budget; };
      cascade = lib.mkOption { type = cascade; };
    };
  };

in {
  inherit observable budget cascade obc;

  # ── CI ────────────────────────────────────────────────────────────────
  # Measure holonomy. Read-only. The fold.
  mkCI = { mirror, config }:
    pkgs.writeShellApplication {
      name = "mirror-ci";
      runtimeInputs = [ mirror ];
      text = ''
        set -euo pipefail
        PATHS=(${lib.concatMapStringsSep " " (p: ''"${p}"'') config.observe.paths})
        RESULT=0
        for path in "''${PATHS[@]}"; do
          if [ -d "$path" ]; then
            mirror ci "$path" || RESULT=$?
          elif [ -f "$path" ]; then
            mirror ci "$path" || RESULT=$?
          fi
        done
        exit $RESULT
      '';
    };

  # ── CA ────────────────────────────────────────────────────────────────
  # Observe + suggest + enforce. The fold + lens.
  mkCA = { mirror, config }:
    pkgs.writeShellApplication {
      name = "mirror-ca";
      runtimeInputs = [ mirror ];
      text = ''
        set -euo pipefail
        PATHS=(${lib.concatMapStringsSep " " (p: ''"${p}"'') config.observe.paths})
        ENFORCE_FLAG="${lib.optionalString config.cascade.enforce "--enforce"}"
        for path in "''${PATHS[@]}"; do
          mirror ca "$path" $ENFORCE_FLAG
        done
      '';
    };

  # ── Watch ─────────────────────────────────────────────────────────────
  # Continuous observation. The daemon.
  mkWatch = { mirror, config }:
    pkgs.writeShellApplication {
      name = "mirror-ca-watch";
      runtimeInputs = [ mirror pkgs.fswatch ];
      text = ''
        set -euo pipefail
        echo "mirror ca: watching ${lib.concatMapStringsSep " " toString config.observe.paths}"
        PATHS=(${lib.concatMapStringsSep " " (p: ''"${p}"'') config.observe.paths})
        fswatch -0 "''${PATHS[@]}" | while IFS= read -r -d "" path; do
          mirror ca "$path" ${lib.optionalString config.cascade.enforce "--enforce"} 2>&1 || true
        done
      '';
    };
}
