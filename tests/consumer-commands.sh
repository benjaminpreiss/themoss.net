#!/usr/bin/env bash
# Exercise the caller's Nix update/build command shape against a tiny machine.
# This does not mint an App token or test the PR/auto-merge path.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.consumer-test-tmp.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/fixtures/consumer/flake.nix" "$tmp/flake.nix"
mkdir -p "$tmp/packages/cli/src/machine" "$tmp/packages/cli/rust"
cp "$root/packages/cli/src/machine/update.nix" "$tmp/packages/cli/src/machine/"
cp "$root/packages/cli/rust/"{Cargo.toml,Cargo.lock,package.nix} "$tmp/packages/cli/rust/"
cp -R "$root/packages/cli/rust/src" "$root/packages/cli/rust/tests" "$tmp/packages/cli/rust/"
# An independent repo keeps Nix from treating this disposable flake as an
# untracked path in the checkout under test.
git -C "$tmp" init -q
git -C "$tmp" add flake.nix packages/cli/src/machine/update.nix packages/cli/rust
(
  cd "$tmp"
  nix flake update
  test -s flake.lock
  output=$(nix build --no-link --print-out-paths .#nixosConfigurations.synthetic.config.system.build.toplevel)
  [[ $(<"$output") == synthetic-machine ]]
  nix eval --raw .#nixosConfigurations.agentic.config.system.build.toplevel.drvPath >/dev/null
  [[ $(nix eval --raw .#nixosConfigurations.agentic.config.systemd.services.themoss-update.serviceConfig.ExecStart) == *' poll /root/agentic '* ]]
)
# Exercise the pinned Rust CLI with a mocked target and disk.
cli=$(nix build --no-link --print-out-paths "$root#moss")/bin/moss
"$cli" reference | cmp "$root/docs/cli-reference.md" - || { echo 'regenerate clap CLI reference' >&2; exit 1; }
nix develop --no-write-lock-file "$root#operator" --command env MOSS_RUST_BIN="$cli" bash "$root/tests/rust-lifecycle.sh"
# Legacy Bash entry points remain active until all current fixtures are migrated.
nix develop --no-write-lock-file "$root#dev" --command bash "$root/tests/argc.sh"
echo 'Synthetic consumer update/build and operator environment passed'
