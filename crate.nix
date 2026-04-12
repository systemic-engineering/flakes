# Crate DSL: declare Rust crate metadata in Nix, materialize Cargo.toml.
#
# Cargo.toml becomes a compiled artifact, not a source file.
# The Nix expression is the single source of truth.
#
# Consumed by project flakes:
#   crate = flakes.lib.${system}.crate;
#   devShells.default = crate.mkShell { name = "my-crate"; ... };

{ pkgs, rust }:

let
  # ── TOML helpers ────────────────────────────────────────────────────────────
  tomlString = s: ''"${s}"'';

  tomlList = items:
    "[${builtins.concatStringsSep ", " (map tomlString items)}]";

  # Render a single dependency value.
  # String → version string: foo = "1.0"
  # Attrset → inline table: foo = { version = "1.0", features = ["serde"] }
  renderDep = name: value:
    if builtins.isString value
    then ''${name} = "${value}"''
    else
      let
        parts = builtins.attrValues (builtins.mapAttrs (k: v:
          if builtins.isString v then ''${k} = "${v}"''
          else if builtins.isList v then "${k} = ${tomlList v}"
          else if builtins.isBool v then "${k} = ${if v then "true" else "false"}"
          else "${k} = ${toString v}"
        ) value);
      in ''${name} = { ${builtins.concatStringsSep ", " parts} }'';

  renderDeps = deps:
    builtins.concatStringsSep "\n"
      (builtins.attrValues (builtins.mapAttrs renderDep deps));

  # ── mkCargo ─────────────────────────────────────────────────────────────────
  # Takes crate metadata, returns a Cargo.toml string.
  mkCargo = { name
            , version ? "0.0.0-dev"
            , edition ? "2024"
            , license ? "Apache-2.0"
            , repository ? ""
            , description ? ""
            , keywords ? []
            , categories ? []
            , dependencies ? {}
            , devDependencies ? {}
            , ...
            }:
    let
      optLine = cond: line: if cond then line else "";
      pkg = builtins.concatStringsSep "\n" (builtins.filter (s: s != "") [
        "[package]"
        ''name = "${name}"''
        ''version = "${version}"''
        ''edition = "${edition}"''
        ''license = "${license}"''
        (optLine (repository != "") ''repository = "${repository}"'')
        (optLine (description != "") ''description = "${description}"'')
        (optLine (keywords != []) "keywords = ${tomlList keywords}")
        (optLine (categories != []) "categories = ${tomlList categories}")
      ]);
      depsSection = let rendered = renderDeps dependencies; in
        if dependencies == {} then ""
        else "\n[dependencies]\n${rendered}";
      devDepsSection = let rendered = renderDeps devDependencies; in
        if devDependencies == {} then ""
        else "\n[dev-dependencies]\n${rendered}";
    in
      pkg + depsSection + devDepsSection + "\n";

  # ── writeCargoHook ──────────────────────────────────────────────────────────
  # Shell snippet that writes Cargo.toml only when content has changed.
  writeCargoHook = cargoToml: ''
    _NIX_CARGO_TOML=$(cat <<'CARGO_EOF'
${cargoToml}
CARGO_EOF
)
    _EXISTING=""
    if [ -f Cargo.toml ]; then
      _EXISTING=$(cat Cargo.toml)
    fi
    if [ "$_NIX_CARGO_TOML" != "$_EXISTING" ]; then
      echo "$_NIX_CARGO_TOML" > Cargo.toml
      echo "crate.nix: Cargo.toml materialized"
    fi
  '';

  # ── mkShell ─────────────────────────────────────────────────────────────────
  # Combines rust.nix tools/hook with Cargo.toml materialization.
  mkShell = args@{ name
                 , extraBuildInputs ? []
                 , extraShellHook ? ""
                 , ... }:
    let
      cargoToml = mkCargo args;
    in pkgs.mkShell {
      buildInputs = [
        pkgs.git
        pkgs.just
        pkgs.jq
      ] ++ rust.rustTools
        ++ extraBuildInputs
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        pkgs.libiconv
      ];

      shellHook = ''
        export LANG=en_US.UTF-8
      '' + rust.rustHook + ''
        # crate.nix: materialize Cargo.toml from Nix declaration
        ${writeCargoHook cargoToml}
      '' + extraShellHook;
    };

in {
  inherit mkCargo mkShell writeCargoHook;
}
