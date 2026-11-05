#!/usr/bin/env bash
# Run in the pinned dev shell: nix develop --no-write-lock-file .#dev --command bash tests/argc.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
command -v argc >/dev/null || { echo 'argc required (use the pinned dev shell)' >&2; exit 1; }
tmp=$(mktemp -d "$root/.test-argc.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/specs"
bash packages/cli/helpers/assemble.sh packages/cli/src/moss.sh "$tmp/moss.sh"
bash packages/cli/helpers/assemble.sh packages/cli/src/machine/deploy.sh "$tmp/deploy.sh"
for name in moss deploy remote audit-app; do
  case $name in
    moss) source="$tmp/moss.sh"; executable=packages/cli/bin/moss; spec=docs/spec/cli/moss.json ;;
    deploy) source="$tmp/deploy.sh"; executable=packages/cli/bin/machine/deploy.sh; spec=docs/spec/cli/machine/deploy.json ;;
    remote) source=packages/cli/src/machine/bootstrap/remote.sh; executable=packages/cli/bin/machine/bootstrap/remote.sh; spec=docs/spec/cli/machine/bootstrap/remote.json ;;
    audit-app) source=packages/github-app-audit/src/audit-app.sh; executable=packages/github-app-audit/bin/audit-app.sh; spec=docs/spec/github-app-audit/audit-app.json ;;
  esac
  argc --argc-build "$source" "$tmp/$name.generated"
  cmp "$executable" "$tmp/$name.generated" || { echo "regenerate $executable" >&2; exit 1; }
  bash "$executable" --help >"$tmp/help"
  argc --argc-export "$source" >"$tmp/specs/$name.json"
  cmp "$spec" "$tmp/specs/$name.json" || { echo "regenerate $spec" >&2; exit 1; }
  jq -e '.name == $name and (.flag_options | any(.long_name == "--help"))' --arg name "$name" "$tmp/specs/$name.json" >/dev/null
  bash -n "$executable" "$source"
done
jq -e '[.subcommands[].name] | index("install") and index("bootstrap") and index("inputs") and index("poll")' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[] | select(.name == "inputs") | .subcommands[].name] | sort == ["apply","check"]' "$tmp/specs/deploy.json" >/dev/null
jq -e '[.subcommands[].name] | sort == ["finish","prepare"]' "$tmp/specs/remote.json" >/dev/null
jq -e '[.subcommands[] | select(.name == "machine") | .subcommands[].name] | sort == ["apply","bootstrap","plan"]' "$tmp/specs/moss.json" >/dev/null
bash -n packages/cli/bin/moss "$tmp/moss.sh"
! grep -q '^# @include ' packages/cli/bin/moss packages/cli/bin/machine/deploy.sh
bash packages/cli/helpers/render-cli-reference.sh "$tmp/specs" >"$tmp/reference.md"
cmp docs/cli-reference.md "$tmp/reference.md" || { echo 'regenerate docs/cli-reference.md' >&2; exit 1; }
argc --argc-mangen "$tmp/deploy.sh" "$tmp/man" >/dev/null
[[ -s $tmp/man/deploy-install.1 && -s $tmp/man/deploy-inputs-apply.1 ]]
# The generated scripts must work without argc on the operator or target.
env PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v basename)"):/usr/bin:/bin" bash packages/cli/bin/moss machine plan --help >"$tmp/help"
! bash packages/cli/bin/machine/deploy.sh install only-one-argument >"$tmp/help" 2>&1
! bash packages/cli/bin/machine/bootstrap/remote.sh prepare only-one-argument >"$tmp/help" 2>&1
echo 'argc-generated CLI contracts and standalone scripts match'
