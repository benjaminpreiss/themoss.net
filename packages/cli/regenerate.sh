#!/usr/bin/env bash
# Run inside the pinned operator shell after changing packages/cli/*/source/*.sh.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required: nix develop --no-write-lock-file .#operator' >&2; exit 1; }
mkdir -p docs/cli-spec
for name in deploy audit-app bootstrap-remote new-operator-manifest; do
  argc --argc-build "packages/cli/internal/source/$name.sh" "packages/cli/internal/$name.sh"
  argc --argc-export "packages/cli/internal/source/$name.sh" >"docs/cli-spec/$name.json"
  chmod +x "packages/cli/internal/$name.sh"
done
argc --argc-build packages/cli/source/moss.sh packages/cli/moss.sh
argc --argc-export packages/cli/source/moss.sh >docs/cli-spec/moss.json
chmod +x packages/cli/moss.sh
bash packages/cli/render-cli-reference.sh > docs/cli-reference.md
printf 'Generated CLI scripts, JSON specs and reference; run bash tests/argc.sh and bash tests/test.sh\n'
