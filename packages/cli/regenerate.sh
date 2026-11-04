#!/usr/bin/env bash
# Edit packages/cli/src and packages/github-app-audit/src; bin/ is generated.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required: nix develop --no-write-lock-file .#operator' >&2; exit 1; }
mkdir -p docs/cli-spec
for name in deploy bootstrap-remote new-operator-manifest; do
  argc --argc-build "packages/cli/src/machine/$name.sh" "packages/cli/bin/machine/$name.sh"
  argc --argc-export "packages/cli/src/machine/$name.sh" >"docs/cli-spec/$name.json"
  chmod +x "packages/cli/bin/machine/$name.sh"
done
argc --argc-build packages/github-app-audit/src/audit-app.sh packages/github-app-audit/bin/audit-app.sh
argc --argc-export packages/github-app-audit/src/audit-app.sh >docs/cli-spec/audit-app.json
chmod +x packages/github-app-audit/bin/audit-app.sh
argc --argc-build packages/cli/src/moss.sh packages/cli/bin/moss
argc --argc-export packages/cli/src/moss.sh >docs/cli-spec/moss.json
chmod +x packages/cli/bin/moss
bash packages/cli/render-cli-reference.sh > docs/cli-reference.md
printf 'Generated CLI scripts, JSON specs and reference; run bash tests/argc.sh and bash tests/test.sh\n'
