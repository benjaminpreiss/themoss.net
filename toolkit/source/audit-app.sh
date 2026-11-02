#!/usr/bin/env bash
# Compare caller-repo installation and scoped-token permissions to policy.
# The audit token is restricted to the caller repo; other installations/repos
# are outside this check and must be reviewed separately.
# Read-only: never creates PRs, changes settings, or reads branch rules.
# @describe Read-only GitHub App installation and scoped-token permission audit.
# @arg app! <APP_ID> Numeric GitHub App ID
# @arg key! <FILE> Private App signing key path (never contents)
# @arg policy! <FILE> Expected permissions JSON
# @arg repo! <OWNER/REPO> Calling repository
set -euo pipefail
umask 077
audit_main() {
[[ $# == 4 ]] || { echo 'usage: audit-app.sh APP_ID KEY_FILE POLICY_JSON OWNER/REPO' >&2; exit 2; }
app=$1 key=$2 policy=$3 repo=$4
[[ $app =~ ^[0-9]+$ && $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid App ID or repo' >&2; exit 2; }
[[ -f $key && ! -L $key && -r $key && -f $policy && ! -L $policy ]] || { echo 'missing or linked key/policy' >&2; exit 2; }
for cmd in curl jq openssl base64 date; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
jq -e 'type == "object" and (keys == ["permissions"]) and (.permissions | type == "object" and length > 0)' "$policy" >/dev/null || { echo 'invalid audit policy (configure permissions only; caller repo comes from workflow)' >&2; exit 2; }
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
  local -a args=(--silent --show-error --max-time 30 --request "$method"
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
    --header "Authorization: Bearer $credential"
    --output "$work/response" --write-out '%{http_code}')
  if [[ $# == 5 ]]; then args+=(--header 'Content-Type: application/json' --data "$5"); fi
  status=$(curl "${args[@]}" "$api_base$route") || { echo "GitHub request failed: $route" >&2; exit 1; }
  [[ $status == "$expected" ]] || { echo "GitHub $route: HTTP $status (expected $expected)" >&2; exit 1; }
}
# Verify which App authenticated; its global grants may differ from the
# permissions approved for this installation and are not this audit's scope.
request GET /app "$jwt" 200
jq -en --argjson expected "$app" --slurpfile response "$work/response" '$response[0].id == $expected' >/dev/null || { echo 'App identity mismatch' >&2; exit 1; }
request GET "/repos/$repo/installation" "$jwt" 200
installation=$(jq -er '.id | numbers' "$work/response")
installation_permissions=$(jq -ec '.permissions | objects' "$work/response")
# Explicitly scope this audit token; the installation may include other repos.
scope=$(jq -cn --arg name "${repo#*/}" '{repositories:[$name]}')
request POST "/app/installations/$installation/access_tokens" "$jwt" 201 "$scope"
token=$(jq -er '.token | strings | select(length > 0)' "$work/response")
token_permissions=$(jq -ec '.permissions | objects' "$work/response")
unset jwt signature
expected_permissions=$(jq -c '.permissions' "$policy")
for actual in "$installation_permissions" "$token_permissions"; do
  jq -en --argjson actual "$actual" --argjson expected "$expected_permissions" '$actual == $expected' >/dev/null || { echo 'caller installation or scoped token permissions differ from policy' >&2; exit 1; }
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
jq -en --arg repo "$repo" --argjson actual "$repos" '$actual == [$repo]' >/dev/null || { echo 'scoped token must access only the calling repository' >&2; exit 1; }
printf 'App %s installation %s: permissions match policy; audit token scoped to %s\n' "$app" "$installation" "$repo"
}

eval "$(argc --argc-eval "$0" "$@")"
audit_main "$@"
