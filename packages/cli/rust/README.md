# Rust `moss` replacement (draft)

This crate now implements the public `init`, `machine plan`, `machine apply`, and `machine bootstrap` commands, plus root-only polling, reviewed updates, transition, adoption and retryable bootstrap. The consumer controls the NixOS flake and machine configuration; the CLI never infers a safe Disko layout. Only `install::install` can call `nixos-anywhere`.

**Not yet cut over:** the existing `../bin/moss` remains the active CLI. The Rust implementation builds with `nix build .#moss` and is included in `.#operator` and the optional update module for validation. Do not deploy the new module to a real target until the target-binary handoff/version policy and the complete lifecycle fixtures have been reviewed. The module currently makes `/run/current-system/sw/bin/moss` available when enabled; an installed host without it refuses Rust bootstrap/update rather than streaming an unreviewed executable. `packages/github-app-audit` is outside this migration.

## Worktree-local development

```bash
cd packages/cli/rust
mkdir -p .tmp .cargo-home
export TMPDIR="$PWD/.tmp" CARGO_HOME="$PWD/.cargo-home" CARGO_TARGET_DIR="$PWD/target"
cargo fmt --check
cargo test --locked
MOSS_RUST_BIN="$PWD/target/debug/moss" bash ../../../tests/rust-lifecycle.sh
cd ../../..
nix build --no-link .#moss
TMPDIR="$PWD/packages/cli/rust/.tmp" bash tests/consumer-commands.sh
```

The mocked Rust lifecycle fixture tests install/build failure, typed erase denial, receipt creation, failed/retried bootstrap upload, pinned initial selector, reviewed update, uncertain switch blocking, guided disk choice and latest-plan selection. It makes **no real SSH or disk calls**. `tests/test.sh` still exercises the old CLI; its safety scenarios must be migrated before replacing the active entry point. Test a disposable VM separately.

The public Markdown reference is generated from the clap tree with `moss reference` (hidden internal operation) and checked byte-for-byte in `tests/consumer-commands.sh`. The old argc specs remain temporarily for the legacy executables, but no longer generate `docs/cli-reference.md`.
