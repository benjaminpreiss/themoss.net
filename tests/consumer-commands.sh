#!/usr/bin/env bash
# Exercise the caller's Nix update/build command shape against a tiny machine.
# This does not mint an App token or test the PR/auto-merge path.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.consumer-test-tmp.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/fixtures/consumer/flake.nix" "$tmp/flake.nix"
# An independent repo keeps Nix from treating this disposable flake as an
# untracked path in the checkout under test.
git -C "$tmp" init -q
git -C "$tmp" add flake.nix
(
  cd "$tmp"
  nix flake update
  test -s flake.lock
  output=$(nix build --no-link --print-out-paths .#nixosConfigurations.synthetic.config.system.build.toplevel)
  [[ $(<"$output") == synthetic-machine ]]
)
echo 'Synthetic consumer update/build passed'
