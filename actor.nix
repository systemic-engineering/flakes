# Reusable NixOS module for provisioning glue actors.
#
# Each actor gets: user account, SSH keys (CA-signed), git config with
# SSH commit signing, local bare repo, identity scaffold, and sops
# secret declarations (auto-generated from naming convention).
#
# Usage:
#   services.actors.keel = {
#     uid      = 1002;
#     email    = "keel@systemic.engineering";
#     role     = "QA engineer";
#     publicKey = "ssh-ed25519 AAAA...";
#     projects = [ "glue" ];   # scoped bindfs mount of /Users/alexwolf/dev/projects/glue
#   };
#
# The module auto-declares sops.secrets.{name}_ssh_{private_key,cert,public_key}
# and wires them into the setup service. Just add the keys to your sops file.

{ config, pkgs, lib, ... }:

let
  cfg = config.services.actors;

  # macOS UID/GID constants for bindfs mapping.
  # Projects live at /Users/alexwolf/dev/projects/ on macOS (UID 501, GID 20 staff).
  # virtiofs exposes them at /run/dev-raw/projects/ in the VM.
  macAlexUid  = "501";
  macStaffGid = "20";
  linuxUsersGid = "100";  # NixOS 'users' group

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

      projects = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Project directories under /Users/alexwolf/dev/projects/ to mount via bindfs.";
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

  # Sops secret paths follow the convention: {name}_ssh_{private_key,cert,public_key}
  sopsPath = name: key: config.sops.secrets."${name}_ssh_${key}".path;

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
        "ssh_private_key:${sopsPath name "private_key"}"
        "ssh_cert:${sopsPath name "cert"}"
        "ssh_public_key:${sopsPath name "public_key"}"
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

    # ── Sops secrets ─────────────────────────────────────────────
    # Auto-declared from naming convention: {name}_ssh_{private_key,cert,public_key}
    sops.secrets = lib.listToAttrs (lib.concatMap (name: [
      { name = "${name}_ssh_private_key"; value = { owner = name; mode = "0400"; }; }
      { name = "${name}_ssh_cert";        value = { owner = name; mode = "0444"; }; }
      { name = "${name}_ssh_public_key";  value = { owner = name; mode = "0444"; }; }
    ]) (lib.attrNames cfg));

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
    systemd.tmpfiles.rules = lib.concatMap (name: let
      actor = cfg.${name};
    in [
      "d /home/${name}/.ssh 0700 ${name} users -"
    ] ++ lib.optional (actor.projects != [])
      "d /home/${name}/projects 0755 ${name} users -"
    ) (lib.attrNames cfg);

    # ── Project mounts ────────────────────────────────────────
    # Per-actor bindfs: only authorized projects are visible.
    # Source: virtiofs raw mount at /run/dev-raw/projects/<project>
    # Target: /home/<actor>/projects/<project>
    # UID map: macOS alexwolf (501) → actor UID, staff (20) → users (100)
    # nofail: virtiofs absent on Hetzner — mounts silently skipped.
    fileSystems = lib.listToAttrs (lib.concatMap (name: let
      actor = cfg.${name};
      uidMap = "${macAlexUid}/${toString actor.uid}:@${macStaffGid}/@${linuxUsersGid}";
    in map (project: {
      name = "/home/${name}/projects/${project}";
      value = {
        device  = "/run/dev-raw/projects/${project}";
        fsType  = "fuse.bindfs";
        options = [
          "nofail"
          "map=${uidMap}"
          "x-systemd.requires-mounts-for=/run/dev-raw"
        ];
        noCheck = true;
      };
    }) actor.projects) (lib.attrNames cfg));

    # ── Setup services ─────────────────────────────────────────
    systemd.services = lib.mapAttrs' (name: actor:
      lib.nameValuePair "${name}-setup" (mkSetupService name actor)
    ) cfg;
  };
}
