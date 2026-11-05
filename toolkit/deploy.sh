#!/usr/bin/env bash
# Compatibility launcher; deployment logic is exclusively in the Rust moss CLI.
set -euo pipefail
if ! command -v moss >/dev/null; then
  echo 'themoss: install moss (nix build .#moss) and run its binary directly' >&2
  exit 2
fi
exec moss "$@"
