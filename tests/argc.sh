#!/usr/bin/env bash
# Run in the pinned operator shell: nix develop --no-write-lock-file .#operator --command bash tests/argc.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required (use the pinned operator shell)' >&2; exit 1; }
tmp=$(mktemp -d "$root/.test-argc.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/specs"
for name in deploy bootstrap-remote new-operator-manifest audit-app; do
  if [[ $name == audit-app ]]; then
    source="packages/github-app-audit/src/$name.sh"; executable="packages/github-app-audit/bin/$name.sh"
  else
    source="packages/cli/src/machine/$name.sh"; executable="packages/cli/bin/machine/$name.sh"
  fi
  argc --argc-build "$source" "$tmp/$name.sh"
  cmp "$executable" "$tmp/$name.sh" || { echo "regenerate $executable" >&2; exit 1; }
  bash "$executable" --help >"$tmp/help"
  argc --argc-export "$source" >"$tmp/specs/$name.json"
  cmp "docs/cli-spec/$name.json" "$tmp/specs/$name.json" || { echo "regenerate docs/cli-spec/$name.json" >&2; exit 1; }
  jq -e '.name == $name and (.flag_options | any(.long_name == "--help"))' --arg name "$name" "$tmp/specs/$name.json" >/dev/null
  bash -n "$executable" "$source"
done
jq -e '[.subcommands[].name] | index("install") and index("bootstrap") and index("manifest") and index("poll")' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[] | select(.name == "manifest") | .subcommands[].name] | sort == ["bootstrap","install","plan","transition"]' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[].name] | sort == ["finish","prepare"]' "$tmp/specs/bootstrap-remote.json" >/dev/null
argc --argc-build packages/cli/src/moss.sh "$tmp/moss.sh"
cmp packages/cli/bin/moss "$tmp/moss.sh"
argc --argc-export packages/cli/src/moss.sh >"$tmp/specs/moss.json"
cmp docs/cli-spec/moss.json "$tmp/specs/moss.json"
jq -e '[.subcommands[] | select(.name == "machine") | .subcommands[].name] | sort == ["apply","bootstrap","plan"]' "$tmp/specs/moss.json" >/dev/null
bash -n packages/cli/bin/moss packages/cli/src/moss.sh
bash packages/cli/render-cli-reference.sh "$tmp/specs" >"$tmp/reference.md"
cmp docs/cli-reference.md "$tmp/reference.md" || { echo 'regenerate docs/cli-reference.md' >&2; exit 1; }
argc --argc-mangen packages/cli/src/machine/deploy.sh "$tmp/man" >/dev/null
[[ -s $tmp/man/deploy-install.1 && -s $tmp/man/deploy-manifest-install.1 ]]
# The generated scripts must work without argc on the operator or target.
env PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v basename)"):/usr/bin:/bin" bash packages/cli/bin/moss machine plan --help >"$tmp/help"
! bash packages/cli/bin/machine/deploy.sh install only-one-argument >"$tmp/help" 2>&1
! bash packages/cli/bin/machine/bootstrap-remote.sh prepare only-one-argument >"$tmp/help" 2>&1
echo 'argc-generated CLI contracts and standalone scripts match'
