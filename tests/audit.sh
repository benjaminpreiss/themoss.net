#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.audit-test.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export TMPDIR="$tmp" PATH="$tmp/bin:$PATH" AUDIT_SCENARIO=ok
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" >/dev/null 2>&1
cat >"$tmp/policy.json" <<'EOF'
{"permissions":{"contents":"write","pull_requests":"read","metadata":"read"},"repositories":{"owner/agentic":{"minApprovals":1,"requiredChecks":["Build and test / OS"]},"owner/relay":{"minApprovals":0,"requiredChecks":["Build and test / OS"]}}}
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output='' url="${*: -1}"
while (($#)); do
  if [[ $1 == --output ]]; then output=$2; shift; fi
  shift
done
[[ -n $output ]]
case $url in
  */access_tokens)
    if [[ $AUDIT_SCENARIO == excess-permission ]]; then
      printf '%s' '{"token":"synthetic","permissions":{"metadata":"read","pull_requests":"write","contents":"write"}}' >"$output"
    else printf '%s' '{"token":"synthetic","permissions":{"metadata":"read","pull_requests":"read","contents":"write"}}' >"$output"; fi
    echo 201 ;;
  */installation/repositories*)
    if [[ $AUDIT_SCENARIO == extra-repo ]]; then printf '%s' '{"repositories":[{"full_name":"owner/agentic"},{"full_name":"owner/relay"},{"full_name":"owner/unknown"}]}' >"$output";
    else printf '%s' '{"repositories":[{"full_name":"owner/agentic"},{"full_name":"owner/relay"}]}' >"$output"; fi
    echo 200 ;;
  */repos/owner/*/rules/branches/*)
    if [[ $AUDIT_SCENARIO == missing-check ]]; then checks='[]'; else checks='[{"context":"Build and test / OS"}]'; fi
    printf '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true}},{"type":"required_status_checks","parameters":{"required_status_checks":%s}}]' "$checks" >"$output"; echo 200 ;;
  */repos/owner/*/rulesets/*)
    if [[ $AUDIT_SCENARIO == bypass ]]; then bypass='[{"actor_type":"Integration","actor_id":123}]'; else bypass='[]'; fi
    if [[ $url == */rulesets/1* ]]; then
      printf '{"rules":[{"type":"deletion"},{"type":"non_fast_forward"}],"enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":%s}' "$bypass" >"$output"
    else
      printf '{"rules":[{"type":"pull_request"}],"enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":%s}' "$bypass" >"$output"
    fi
    echo 200 ;;
  */repos/owner/*/rulesets*) echo '[{"id":1},{"id":2}]' >"$output"; echo 200 ;;
  */repos/owner/*) echo '{"default_branch":"main"}' >"$output"; echo 200 ;;
  *) echo "unexpected mock URL: $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
check() { bash "$root/toolkit/audit-app.sh" 123 321 "$tmp/key.pem" "$tmp/policy.json"; }
check
for AUDIT_SCENARIO in missing-check bypass extra-repo excess-permission; do
  export AUDIT_SCENARIO
  if check > /dev/null 2>&1; then echo "audit passed $AUDIT_SCENARIO" >&2; exit 1; fi
done
echo 'App audit fixtures passed'
