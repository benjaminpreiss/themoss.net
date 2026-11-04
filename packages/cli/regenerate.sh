#!/usr/bin/env bash
# Edit packages/cli/src and packages/github-app-audit/src; bin/ is generated.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required: nix develop --no-write-lock-file .#dev' >&2; exit 1; }
mkdir -p docs/cli-spec/machine/bootstrap
tmp=$(mktemp -d "$root/.cli-gen.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bash packages/cli/assemble.sh packages/cli/src/machine/deploy.sh "$tmp/deploy.sh"
bash packages/cli/assemble.sh packages/cli/src/moss.sh "$tmp/moss.sh"
argc --argc-build "$tmp/deploy.sh" packages/cli/bin/machine/deploy.sh
argc --argc-export "$tmp/deploy.sh" >docs/cli-spec/deploy.json
argc --argc-build packages/cli/src/machine/bootstrap/remote.sh packages/cli/bin/machine/bootstrap/remote.sh
argc --argc-export packages/cli/src/machine/bootstrap/remote.sh >docs/cli-spec/machine/bootstrap/remote.json
argc --argc-build packages/github-app-audit/src/audit-app.sh packages/github-app-audit/bin/audit-app.sh
argc --argc-export packages/github-app-audit/src/audit-app.sh >docs/cli-spec/audit-app.json
argc --argc-build "$tmp/moss.sh" packages/cli/bin/moss
argc --argc-export "$tmp/moss.sh" >docs/cli-spec/moss.json
chmod +x packages/cli/bin/moss packages/cli/bin/machine/deploy.sh packages/cli/bin/machine/bootstrap/remote.sh packages/github-app-audit/bin/audit-app.sh
bash packages/cli/render-cli-reference.sh > docs/cli-reference.md
printf 'Generated CLI scripts, JSON specs and reference; run bash tests/argc.sh and bash tests/test.sh\n'
