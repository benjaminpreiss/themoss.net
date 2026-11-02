#!/usr/bin/env bash
# Run in the pinned operator shell: nix develop --no-write-lock-file .#operator --command bash tests/argc.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required (use the pinned operator shell)' >&2; exit 1; }
tmp=$(mktemp -d "$root/.test-argc.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/specs"
for name in deploy audit-app bootstrap-remote new-operator-manifest; do
  argc --argc-build "toolkit/source/$name.sh" "$tmp/$name.sh"
  cmp "toolkit/$name.sh" "$tmp/$name.sh" || { echo "regenerate toolkit/$name.sh" >&2; exit 1; }
  bash "toolkit/$name.sh" --help >"$tmp/help"
  argc --argc-export "toolkit/source/$name.sh" >"$tmp/specs/$name.json"
  cmp "docs/cli-spec/$name.json" "$tmp/specs/$name.json" || { echo "regenerate docs/cli-spec/$name.json" >&2; exit 1; }
  jq -e '.name == $name and (.flag_options | any(.long_name == "--help"))' --arg name "$name" "$tmp/specs/$name.json" >/dev/null
  bash -n "toolkit/$name.sh" "toolkit/source/$name.sh"
done
jq -e '[.subcommands[].name] | index("install") and index("bootstrap") and index("manifest") and index("poll")' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[] | select(.name == "manifest") | .subcommands[].name] | sort == ["bootstrap","install","plan","transition"]' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[].name] | sort == ["finish","prepare"]' "$tmp/specs/bootstrap-remote.json" >/dev/null
bash toolkit/render-cli-reference.sh "$tmp/specs" >"$tmp/reference.md"
cmp docs/cli-reference.md "$tmp/reference.md" || { echo 'regenerate docs/cli-reference.md' >&2; exit 1; }
argc --argc-mangen toolkit/source/deploy.sh "$tmp/man" >/dev/null
[[ -s $tmp/man/deploy-install.1 && -s $tmp/man/deploy-manifest-install.1 ]]
# The generated scripts must work without argc on the operator or target.
env PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v basename)"):/usr/bin:/bin" bash toolkit/deploy.sh manifest plan --help >"$tmp/help"
! bash toolkit/deploy.sh install only-one-argument >"$tmp/help" 2>&1
! bash toolkit/bootstrap-remote.sh prepare only-one-argument >"$tmp/help" 2>&1
echo 'argc-generated CLI contracts and standalone scripts match'
