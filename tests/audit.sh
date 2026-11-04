#!/usr/bin/env bash
# Credential-free App permission audit fixtures. Invoked by tests/test.sh
# (and thus .github/workflows/ci.yml); also runnable as `bash tests/audit.sh`.
# A mock curl responds to JWT/installation/repository queries; no GitHub call.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.audit-test.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export TMPDIR="$tmp" PATH="$tmp/bin:$PATH" AUDIT_SCENARIO=ok
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" >/dev/null 2>&1
cat >"$tmp/policy.json" <<'EOF'
{"permissions":{"contents":"write","pull_requests":"write","metadata":"read"}}
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output='' url="${*: -1}" auth='' data=''
while (($#)); do
  case $1 in --output) output=$2; shift;; --header) [[ $2 != Authorization:* ]] || auth=$2; shift;; --data) data=$2; shift;; esac
  shift
done
[[ -n $output && $auth == 'Authorization: Bearer '* ]] || exit 1
permissions='{"contents":"write","pull_requests":"write","metadata":"read"}'
case $url in
  */app) if [[ $AUDIT_SCENARIO == app-drift ]]; then permissions='{"contents":"write","pull_requests":"write","issues":"write","metadata":"read"}'; fi
    if [[ $AUDIT_SCENARIO == app-id-mismatch ]]; then app_id=999; else app_id=123; fi
    printf '{"id":%s,"permissions":%s}' "$app_id" "$permissions" >"$output"; echo 200 ;;
  */repos/owner/agentic/installation)
    if [[ $AUDIT_SCENARIO == installation-drift ]]; then permissions='{"contents":"write","pull_requests":"read","metadata":"read"}'; fi
    if [[ $AUDIT_SCENARIO == shared-installation ]]; then selection=all; else selection=selected; fi
    printf '{"id":321,"repository_selection":"%s","permissions":%s}' "$selection" "$permissions" >"$output"; echo 200 ;;
  */access_tokens)
    jq -e '.repositories == ["agentic"]' <<<"$data" >/dev/null || exit 1
    if [[ $AUDIT_SCENARIO == token-drift ]]; then permissions='{"contents":"write","pull_requests":"read","metadata":"read"}'; fi
    printf '{"token":"synthetic","permissions":%s}' "$permissions" >"$output"; echo 201 ;;
  */installation/repositories*)
    if [[ $AUDIT_SCENARIO == extra-repo ]]; then repos='[{"full_name":"owner/agentic"},{"full_name":"owner/unexpected"}]';
    elif [[ $AUDIT_SCENARIO == missing-repo ]]; then repos='[]';
    else repos='[{"full_name":"owner/agentic"}]'; fi
    printf '{"repositories":%s}' "$repos" >"$output"; echo 200 ;;
  *) echo "unexpected mock URL: $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
check() { bash "$root/packages/cli/internal/audit-app.sh" 123 "$tmp/key.pem" "$tmp/policy.json" owner/agentic; }
check
AUDIT_SCENARIO=shared-installation check # extra repo membership does not fail a caller-scoped audit
AUDIT_SCENARIO=app-drift check # global App grants can differ outside this installation
for AUDIT_SCENARIO in app-id-mismatch installation-drift token-drift extra-repo missing-repo; do
  export AUDIT_SCENARIO
  if check > /dev/null 2>&1; then echo "audit passed $AUDIT_SCENARIO" >&2; exit 1; fi
done
echo 'App permission audit fixtures passed'
