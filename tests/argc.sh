#!/usr/bin/env bash
# Run in the pinned operator shell: nix develop --no-write-lock-file .#operator --command bash tests/argc.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required (use the pinned operator shell)' >&2; exit 1; }
tmp=$(mktemp -d "$root/.test-argc.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/specs"
for name in deploy audit-app bootstrap-remote new-operator-manifest; do
  argc --argc-build "packages/cli/internal/source/$name.sh" "$tmp/$name.sh"
  cmp "packages/cli/internal/$name.sh" "$tmp/$name.sh" || { echo "regenerate packages/cli/internal/$name.sh" >&2; exit 1; }
  bash "packages/cli/internal/$name.sh" --help >"$tmp/help"
  argc --argc-export "packages/cli/internal/source/$name.sh" >"$tmp/specs/$name.json"
  cmp "docs/cli-spec/$name.json" "$tmp/specs/$name.json" || { echo "regenerate docs/cli-spec/$name.json" >&2; exit 1; }
  jq -e '.name == $name and (.flag_options | any(.long_name == "--help"))' --arg name "$name" "$tmp/specs/$name.json" >/dev/null
  bash -n "packages/cli/internal/$name.sh" "packages/cli/internal/source/$name.sh"
done
jq -e '[.subcommands[].name] | index("install") and index("bootstrap") and index("manifest") and index("poll")' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[] | select(.name == "manifest") | .subcommands[].name] | sort == ["bootstrap","install","plan","transition"]' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[].name] | sort == ["finish","prepare"]' "$tmp/specs/bootstrap-remote.json" >/dev/null
argc --argc-build packages/cli/source/moss.sh "$tmp/moss.sh"
cmp packages/cli/moss.sh "$tmp/moss.sh"
argc --argc-export packages/cli/source/moss.sh >"$tmp/specs/moss.json"
cmp docs/cli-spec/moss.json "$tmp/specs/moss.json"
jq -e '[.subcommands[] | select(.name == "machine") | .subcommands[].name] | sort == ["apply","bootstrap","plan"]' "$tmp/specs/moss.json" >/dev/null
bash -n packages/cli/moss.sh packages/cli/source/moss.sh
bash packages/cli/render-cli-reference.sh "$tmp/specs" >"$tmp/reference.md"
cmp docs/cli-reference.md "$tmp/reference.md" || { echo 'regenerate docs/cli-reference.md' >&2; exit 1; }
argc --argc-mangen packages/cli/internal/source/deploy.sh "$tmp/man" >/dev/null
[[ -s $tmp/man/deploy-install.1 && -s $tmp/man/deploy-manifest-install.1 ]]
# The generated scripts must work without argc on the operator or target.
env PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v basename)"):/usr/bin:/bin" bash packages/cli/moss.sh machine plan --help >"$tmp/help"
! bash packages/cli/internal/deploy.sh install only-one-argument >"$tmp/help" 2>&1
! bash packages/cli/internal/bootstrap-remote.sh prepare only-one-argument >"$tmp/help" 2>&1
echo 'argc-generated CLI contracts and standalone scripts match'
