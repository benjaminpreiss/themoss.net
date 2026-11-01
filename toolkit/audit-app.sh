#!/usr/bin/env bash
# Compare App grants and require its installation to contain only the caller repo.
# Read-only: never creates PRs, changes settings, or reads branch rules.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'usage: audit-app.sh APP_ID KEY_FILE POLICY_JSON OWNER/REPO' >&2; exit 2; }
app=$1 key=$2 policy=$3 repo=$4
[[ $app =~ ^[0-9]+$ && $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid App ID or repo' >&2; exit 2; }
[[ -f $key && ! -L $key && -r $key && -f $policy && ! -L $policy ]] || { echo 'missing or linked key/policy' >&2; exit 2; }
for cmd in curl jq openssl base64 date; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
jq -e 'type == "object" and (keys == ["permissions"]) and (.permissions | type == "object" and length > 0)' "$policy" >/dev/null || { echo 'invalid audit policy (only permissions are configured; installation must contain caller repo alone)' >&2; exit 2; }
api_base=${THEMOSS_GITHUB_API:-https://api.github.com}
[[ $api_base == https://api.github.com || $api_base == http://127.0.0.1:* ]] || { echo 'unsupported API endpoint' >&2; exit 2; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
b64() { base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64)
payload=$(jq -cn --argjson iat "$((now-60))" --argjson exp "$((now+540))" --arg iss "$app" '{iat:$iat,exp:$exp,iss:$iss}' | b64)
signature=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$key" | b64)
jwt="$header.$payload.$signature"
request() {
  local method=$1 route=$2 credential=$3 expected=$4 status
  status=$(curl --silent --show-error --max-time 30 --request "$method" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "Authorization: Bearer $credential" \
    --output "$work/response" --write-out '%{http_code}' "$api_base$route") || { echo "GitHub request failed: $route" >&2; exit 1; }
  [[ $status == "$expected" ]] || { echo "GitHub $route: HTTP $status (expected $expected)" >&2; exit 1; }
}
# Inspect what the App itself can grant, not just a possibly down-scoped token.
request GET /app "$jwt" 200
app_permissions=$(jq -ec '.permissions | objects' "$work/response")
request GET "/repos/$repo/installation" "$jwt" 200
installation=$(jq -er '.id | numbers' "$work/response")
installation_permissions=$(jq -ec '.permissions | objects' "$work/response")
# The private key can mint tokens for *any* installation of this App.
# Check all installations, not only the one containing the caller repo.
installations='[]'; page=1
while :; do
  request GET "/app/installations?per_page=100&page=$page" "$jwt" 200
  count=$(jq -er 'arrays | length' "$work/response")
  installations=$(jq -cn --argjson old "$installations" --slurpfile new "$work/response" '$old + [$new[0][].id]')
  ((count < 100)) && break
  ((page+=1)); ((page <= 50)) || { echo 'installation pagination limit' >&2; exit 1; }
done
jq -en --argjson actual "$installations" --argjson expected "$installation" '$actual == [$expected]' >/dev/null || { echo 'App must have only the calling repository installation' >&2; exit 1; }
request POST "/app/installations/$installation/access_tokens" "$jwt" 201
token=$(jq -er '.token | strings | select(length > 0)' "$work/response")
token_permissions=$(jq -ec '.permissions | objects' "$work/response")
unset jwt signature
expected_permissions=$(jq -c '.permissions' "$policy")
for actual in "$app_permissions" "$installation_permissions" "$token_permissions"; do
  jq -en --argjson actual "$actual" --argjson expected "$expected_permissions" '$actual == $expected' >/dev/null || { echo 'App, installation or token permissions differ from policy' >&2; exit 1; }
done
repos='[]'; page=1
while :; do
  request GET "/installation/repositories?per_page=100&page=$page" "$token" 200
  count=$(jq -er '.repositories | arrays | length' "$work/response")
  repos=$(jq -cn --argjson old "$repos" --slurpfile new "$work/response" '$old + [$new[0].repositories[].full_name]')
  ((count < 100)) && break
  ((page+=1)); ((page <= 50)) || { echo 'repository pagination limit' >&2; exit 1; }
done
unset token
jq -en --arg repo "$repo" --argjson actual "$repos" '$actual == [$repo]' >/dev/null || { echo 'installation must contain only the calling repository' >&2; exit 1; }
printf 'App %s installation %s: permissions match policy; only %s accessible\n' "$app" "$installation" "$repo"
