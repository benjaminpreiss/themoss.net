#!/usr/bin/env bash
# Run inside the pinned operator shell after changing toolkit/source/*.sh.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required: nix develop --no-write-lock-file .#operator' >&2; exit 1; }
mkdir -p docs/cli-spec
for name in deploy audit-app bootstrap-remote new-operator-manifest; do
  argc --argc-build "toolkit/source/$name.sh" "toolkit/$name.sh"
  argc --argc-export "toolkit/source/$name.sh" >"docs/cli-spec/$name.json"
  chmod +x "toolkit/$name.sh"
done
bash toolkit/render-cli-reference.sh > docs/cli-reference.md
printf 'Generated standalone toolkit scripts, JSON specs and reference; run bash tests/argc.sh and bash tests/test.sh\n'
