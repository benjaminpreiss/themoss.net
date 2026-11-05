#!/usr/bin/env bash
# Edit packages/cli/src and packages/github-app-audit/src; bin/ is generated.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required: nix develop --no-write-lock-file .#dev' >&2; exit 1; }
mkdir -p docs/spec/cli/machine/bootstrap docs/spec/github-app-audit
tmp=$(mktemp -d "$root/.cli-gen.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bash packages/cli/helpers/assemble.sh packages/cli/src/machine/deploy.sh "$tmp/deploy.sh"
bash packages/cli/helpers/assemble.sh packages/cli/src/moss.sh "$tmp/moss.sh"
argc --argc-build "$tmp/deploy.sh" packages/cli/bin/machine/deploy.sh
bash packages/cli/helpers/export-spec.sh "$tmp/deploy.sh" >docs/spec/cli/machine/deploy.json
argc --argc-build packages/cli/src/machine/bootstrap/remote.sh packages/cli/bin/machine/bootstrap/remote.sh
bash packages/cli/helpers/export-spec.sh packages/cli/src/machine/bootstrap/remote.sh >docs/spec/cli/machine/bootstrap/remote.json
argc --argc-build packages/github-app-audit/src/audit-app.sh packages/github-app-audit/bin/audit-app.sh
bash packages/cli/helpers/export-spec.sh packages/github-app-audit/src/audit-app.sh >docs/spec/github-app-audit/audit-app.json
argc --argc-build "$tmp/moss.sh" packages/cli/bin/moss
bash packages/cli/helpers/export-spec.sh "$tmp/moss.sh" >docs/spec/cli/moss.json
chmod +x packages/cli/bin/moss packages/cli/bin/machine/deploy.sh packages/cli/bin/machine/bootstrap/remote.sh packages/github-app-audit/bin/audit-app.sh
# Public CLI reference is generated from the replacement clap command tree.
cli=$(nix build --no-link --print-out-paths .#moss)/bin/moss
"$cli" reference > docs/cli-reference.md
printf 'Generated CLI scripts, JSON specs and reference; run bash tests/argc.sh and bash tests/test.sh\n'
