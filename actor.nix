# Reusable NixOS module for provisioning glue actors.
#
# Each actor gets: user account, SSH keys (CA-signed), git config with
# SSH commit signing, local bare repo, and identity scaffold (CLAUDE.md).
#
# Usage:
#   services.actors.keel = {
#     uid   = 1002;
#     email = "keel@systemic.engineering";
#     role  = "QA engineer";
#     sshKeys = {
#       privateKey = config.sops.secrets.keel_ssh_private_key.path;
#       cert       = config.sops.secrets.keel_ssh_cert.path;
#       publicKey  = config.sops.secrets.keel_ssh_public_key.path;
#     };
#   };

{ config, pkgs, lib, ... }:

let
  cfg = config.services.actors;

  capitalize = s:
    let
      first = builtins.substring 0 1 s;
      rest  = builtins.substring 1 (builtins.stringLength s) s;
    in builtins.replaceStrings
      ["a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z"]
      ["A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M" "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z"]
      first + rest;

  actorOpts = { name, ... }: {
    options = {
      uid = lib.mkOption {
        type = lib.types.int;
        description = "Fixed UID for the actor.";
      };

      email = lib.mkOption {
        type = lib.types.str;
        description = "Email for git config and identity.";
      };

      role = lib.mkOption {
        type = lib.types.str;
        description = "One-line role description for CLAUDE.md.";
      };

      displayName = lib.mkOption {
        type = lib.types.str;
        default = capitalize name;
        description = "Capitalized display name for git commits.";
      };

      shell = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bash;
        description = "Login shell.";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "SSH public key for authorized_keys fallback.";
      };

      trustedBy = lib.mkOption {
        type = lib.types.str;
        default = "Reed";
        description = "Who signed this actor's SSH certificate.";
      };

      sshKeys = {
        privateKey = lib.mkOption {
          type = lib.types.path;
          description = "Path to decrypted SSH private key.";
        };

        cert = lib.mkOption {
          type = lib.types.path;
          description = "Path to decrypted SSH certificate.";
        };

        publicKey = lib.mkOption {
          type = lib.types.path;
          description = "Path to decrypted SSH public key.";
        };
      };

      extraRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra lines appended to the Rules section of CLAUDE.md.";
      };
    };
  };

  mkIdentity = name: actor: pkgs.writeText "${name}-claude-md" ''
    # ${actor.displayName}

    ${actor.role}. Background agent on the VM.

    ## Identity
    - Commit as `${actor.displayName} <${actor.email}>`
    - SSH key signed by ${actor.trustedBy} (CA chain)
    - Work tracked through Glue signals

    ## Trust Chain
    ${actor.trustedBy} -> ${actor.displayName}. ${actor.trustedBy} signed this key. ${actor.trustedBy} vouches for this agent.

    ## Rules
    - Always work on a branch — never commit directly to main
    - Document thinking through Glue signals
    - Push to /srv/git/${name}.git (local bare repo)
    ${actor.extraRules}
  '';

  mkMemory = name: actor: pkgs.writeText "${name}-memory-md" ''
    # Memory

    Operational state across sessions. Updated by ${actor.displayName}.

    ## Origin
    - SSH key signed by ${actor.trustedBy}'s CA key
  '';

  mkSetupService = name: actor: let
    identity = mkIdentity name actor;
    memory   = mkMemory name actor;
    home     = "/home/${name}";
    bareRepo = "/srv/git/${name}.git";
  in {
    description = "Provision ${name} actor — SSH keys, git, identity";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "root";

      LoadCredential = [
        "ssh_private_key:${actor.sshKeys.privateKey}"
        "ssh_cert:${actor.sshKeys.cert}"
        "ssh_public_key:${actor.sshKeys.publicKey}"
      ];
    };

    path = [ pkgs.git pkgs.openssh ];

    script = ''
      ACTOR_HOME="${home}"
      ACTOR_SSH="$ACTOR_HOME/.ssh"
      BARE_REPO="${bareRepo}"
      CREDS="$CREDENTIALS_DIRECTORY"

      # ── SSH keys ──────────────────────────────────────────────
      if [ ! -f "$ACTOR_SSH/id_ed25519" ]; then
        echo "Deploying ${name} SSH keys..."
        install -m 0700 -o ${name} -g users -d "$ACTOR_SSH"
        install -m 0400 -o ${name} -g users "$CREDS/ssh_private_key" "$ACTOR_SSH/id_ed25519"
        install -m 0444 -o ${name} -g users "$CREDS/ssh_public_key"  "$ACTOR_SSH/id_ed25519.pub"
        install -m 0444 -o ${name} -g users "$CREDS/ssh_cert"        "$ACTOR_SSH/id_ed25519-cert.pub"
      fi

      # ── Git config ───────────────────────────────────────────
      if [ ! -f "$ACTOR_HOME/.gitconfig" ]; then
        echo "Setting up ${name} git config..."
        cat > "$ACTOR_HOME/.gitconfig" << 'GIT'
      [user]
        name = ${actor.displayName}
        email = ${actor.email}
        signingkey = ${home}/.ssh/id_ed25519.pub
      [gpg]
        format = ssh
      [commit]
        gpgsign = true
      [safe]
        directory = *
      GIT
      fi

      # ── Bare repo ────────────────────────────────────────────
      if [ ! -d "$BARE_REPO" ]; then
        echo "Creating bare repo at $BARE_REPO..."
        git init --bare -b main "$BARE_REPO"
      fi

      # ── Identity scaffold ────────────────────────────────────
      if [ ! -f "$ACTOR_HOME/CLAUDE.md" ]; then
        echo "Scaffolding ${name} identity..."
        cp ${identity} "$ACTOR_HOME/CLAUDE.md"
        cp ${memory}   "$ACTOR_HOME/MEMORY.md"
      fi

      # ── Working repo ─────────────────────────────────────────
      # Root runs git in actor-owned home — safe.directory needed.
      # Bare repo chown deferred so push doesn't hit ownership check.
      if [ ! -d "$ACTOR_HOME/.git" ]; then
        echo "Initializing ${name} working repo..."
        cd "$ACTOR_HOME"
        git -c safe.directory='*' init -b main
        git -c safe.directory='*' remote add origin "$BARE_REPO"
        git -c safe.directory='*' add CLAUDE.md MEMORY.md
        git -c safe.directory='*' -c user.name='${actor.displayName}' -c user.email=${actor.email} \
          commit --no-gpg-sign -m "${name}: identity scaffold"
        git -c safe.directory='*' push -u origin main
      fi

      # ── Ownership ──────────────────────────────────────────
      chown -R ${name}:users "$ACTOR_HOME"
      chown -R ${name}:users "$BARE_REPO"

      echo "${actor.displayName} provisioned."
    '';
  };

in {
  options.services.actors = lib.mkOption {
    type    = lib.types.attrsOf (lib.types.submodule actorOpts);
    default = {};
    description = "Glue actors to provision on this machine.";
  };

  config = lib.mkIf (cfg != {}) {

    # ── Users ──────────────────────────────────────────────────
    users.users = lib.mapAttrs (name: actor: {
      isNormalUser = true;
      uid          = actor.uid;
      home         = "/home/${name}";
      shell        = actor.shell;
      openssh.authorizedKeys.keys =
        lib.optional (actor.publicKey != "") actor.publicKey;
    }) cfg;

    # ── Directories ────────────────────────────────────────────
    systemd.tmpfiles.rules = lib.concatMap (name: [
      "d /home/${name}/.ssh 0700 ${name} users -"
    ]) (lib.attrNames cfg);

    # ── Setup services ─────────────────────────────────────────
    systemd.services = lib.mapAttrs' (name: actor:
      lib.nameValuePair "${name}-setup" (mkSetupService name actor)
    ) cfg;
  };
}
