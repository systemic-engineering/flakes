# flakes

Shared Nix flake infrastructure for [systemic-engineering](https://github.com/systemic-engineering)
projects. Provides reusable devShells, Rust toolchains, BEAM environments, and
NIF support so individual projects don't each re-roll their own.

## What's in here

| File              | What it provides                                                   |
|-------------------|--------------------------------------------------------------------|
| `flake.nix`       | Top-level: exports `lib.{beam,rust,nif,conversation,crate}` + devShells |
| `rust.nix`        | Pinned Rust toolchain (1.94.0 via [rust-overlay]) + persistent CARGO_HOME |
| `beam.nix`        | Elixir 1.18 / OTP 27 + Gleam, worktree guard, glue connect         |
| `nif.nix`         | Rustler NIF build tools (for fragmentation, etc.)                  |
| `conversation.nix`| `.conv` package development environment                            |
| `crate.nix`       | Cargo.toml materialization DSL                                     |
| `ci.nix`          | Typed OBC pipeline module (observable, budget, cascade)            |
| `actor.nix`       | NixOS module for actor services                                    |

## How to consume

In your project's `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flakes.url      = "github:systemic-engineering/flakes";
  };

  outputs = { self, nixpkgs, flake-utils, flakes }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        rust = flakes.lib.rust.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = rust.rustTools;
          shellHook   = rust.rustHook;
        };
      });
}
```

Or grab a ready-made devShell directly:

```
nix develop github:systemic-engineering/flakes#rust
```

Available devShells: `default`, `rust`, `elixir`, `gleam`, `beam`,
`gleam-rust`, `elixir-nif`, `conversation`.

## Pinned toolchain — why

The Rust toolchain is pinned via [rust-overlay] at `1.94.0`. This is deliberate:
when consuming projects update `nixpkgs`, the rustc store path does **not**
change. Cargo fingerprints stay stable, which means CI caches (e.g.
`Swatinem/rust-cache`) actually hit on subsequent runs instead of invalidating
on every nixpkgs bump.

`CARGO_HOME` points at `~/.cargo` (persistent, shared across projects) rather
than per-project, so the registry index and crate sources are downloaded once
and reused everywhere. `CARGO_TARGET_DIR` is left to the consumer's
`~/.cargo/config.toml`.

Updating Rust is now an explicit edit to `rust.nix`, not a side effect of
`nix flake update`.

## License

[Apache-2.0](./LICENSE) — Copyright 2026 Alex Wolf / systemic.engineering.

[rust-overlay]: https://github.com/oxalica/rust-overlay
