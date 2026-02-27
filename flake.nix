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
        # MIX_BUILD_ROOT per platform avoids recompilation when source is
        # shared across architectures (e.g. virtiofs between macOS and VM).
        elixirMixHook = ''
          export MIX_HOME=$PWD/.nix-mix
          export MIX_REBAR3=${beamPkgs.rebar3}/bin/rebar3
          export HEX_HOME=$PWD/.nix-hex
          export MIX_BUILD_ROOT=$PWD/_build-${system}
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
        '';

        # ── Deploy script ────────────────────────────────────────────────────
        # Builds body release on the VM (source available via virtiofs),
        # copies to /opt/body, and restarts via Nomad.
        #
        # Usage: nix run .#deploy-body [-- --strategy hot|cold]
        # Called by OBC pipeline's BEAM.Reload cascade.
        deploy-body = pkgs.writeShellApplication {
          name = "deploy-body";
          runtimeInputs = [ pkgs.openssh ];
          text = ''
            set -euo pipefail

            STRATEGY="cold"
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --strategy) STRATEGY="$2"; shift 2 ;;
                *) echo "Unknown arg: $1" >&2; exit 1 ;;
              esac
            done

            if [[ "$STRATEGY" != "hot" && "$STRATEGY" != "cold" ]]; then
              echo "Invalid strategy: $STRATEGY (must be hot or cold)" >&2
              exit 1
            fi

            # ── Find VM ──────────────────────────────────────────────────
            VM_IP=""
            for ip in $(arp -an 2>/dev/null | grep -oE '192\.168\.64\.[0-9]+' | grep -v '\.1$\|\.255$') \
                      $(seq 2 30 | xargs -I{} echo "192.168.64.{}"); do
              if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                     -o ConnectTimeout=2 -o BatchMode=yes -o LogLevel=ERROR \
                     "reed@$ip" true 2>/dev/null; then
                VM_IP="$ip"
                break
              fi
            done

            if [[ -z "$VM_IP" ]]; then
              echo "VM not reachable." >&2
              exit 1
            fi
            echo "VM at reed@$VM_IP"

            SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

            # ── Build ────────────────────────────────────────────────────
            echo "Building body release on VM..."
            $SSH "reed@$VM_IP" bash -l << 'BUILD'
              set -euo pipefail
              cd /Users/alexwolf/dev/projects/body

              export MIX_ENV=prod
              export MIX_BUILD_ROOT=$PWD/_build-aarch64-linux
              export MIX_HOME=$PWD/.nix-mix
              export HEX_HOME=$PWD/.nix-hex
              export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH

              mix local.hex --force --if-missing
              mix local.rebar --force --if-missing
              mix deps.get --only prod
              mix deps.compile
              mix compile
              mix release glue --overwrite

              # Atomic deploy: copy to staging, then swap
              rm -rf /opt/body-staging
              cp -r _build-aarch64-linux/prod/rel/glue /opt/body-staging
              if [ -d /opt/body ]; then
                rm -rf /opt/body-old
                mv /opt/body /opt/body-old
              fi
              mv /opt/body-staging /opt/body
              rm -rf /opt/body-old
              echo "Release deployed to /opt/body"
            BUILD

            # ── Reload ───────────────────────────────────────────────────
            if [[ "$STRATEGY" == "cold" ]]; then
              echo "Cold reload: restarting body via Nomad..."
              $SSH "reed@$VM_IP" bash -l << 'COLD'
                export NOMAD_ADDR=http://127.0.0.1:4646
                nomad job stop body 2>/dev/null || true
                sleep 1
                nomad job run /home/reed/nomad/jobs/body.nomad.hcl
              COLD
            else
              echo "Hot reload: signaling body to upgrade..."
              $SSH "reed@$VM_IP" /opt/body/bin/glue rpc \
                "IO.puts(\"Hot reload not yet implemented — restart manually\")"
            fi

            echo "Done. strategy=$STRATEGY"
          '';
        };

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

        apps.deploy-body = {
          type = "app";
          program = "${deploy-body}/bin/deploy-body";
        };
      });
}
