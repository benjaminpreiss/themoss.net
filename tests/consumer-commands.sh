#!/usr/bin/env bash
# Exercise the caller's Nix update/build command shape against a tiny machine.
# This does not mint an App token or test the PR/auto-merge path.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.consumer-test-tmp.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$root/tests/fixtures/consumer/flake.nix" "$tmp/flake.nix"
mkdir -p "$tmp/packages/cli/src/machine" "$tmp/packages/cli/bin/machine"
cp "$root/packages/cli/src/machine/update.nix" "$tmp/packages/cli/src/machine/"
cp "$root/packages/cli/bin/machine/deploy.sh" "$tmp/packages/cli/bin/machine/"
# An independent repo keeps Nix from treating this disposable flake as an
# untracked path in the checkout under test.
git -C "$tmp" init -q
git -C "$tmp" add flake.nix packages/cli/src/machine/update.nix packages/cli/bin/machine/deploy.sh
(
  cd "$tmp"
  nix flake update
  test -s flake.lock
  output=$(nix build --no-link --print-out-paths .#nixosConfigurations.synthetic.config.system.build.toplevel)
  [[ $(<"$output") == synthetic-machine ]]
  nix eval --raw .#nixosConfigurations.agentic.config.system.build.toplevel.drvPath >/dev/null
  [[ $(nix eval --raw .#nixosConfigurations.agentic.config.systemd.services.themoss-update.serviceConfig.ExecStart) == *' poll /root/agentic '* ]]
)
# CI exercises the pinned Linux operator environment without a target or disk.
nix develop --no-write-lock-file "$root#operator" --command bash -n "$root/packages/cli/bin/machine/deploy.sh" "$root/packages/cli/bin/machine/bootstrap/remote.sh"
# CI verifies generated standalone scripts, JSON specs and Markdown in this step.
nix develop --no-write-lock-file "$root#operator" --command bash "$root/tests/argc.sh"
nix develop --no-write-lock-file "$root#operator" --command bash "$root/tests/operator-smoke.sh"
echo 'Synthetic consumer update/build and operator environment passed'
