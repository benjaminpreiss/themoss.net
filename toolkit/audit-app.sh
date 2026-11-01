#!/usr/bin/env bash
# Read-only audit of one GitHub App installation. Credentials stay outside Nix.
set -euo pipefail
umask 077
[[ $# == 4 ]] || { echo 'usage: audit-app.sh APP_ID INSTALLATION_ID PRIVATE_KEY POLICY_JSON' >&2; exit 2; }
app=$1 installation=$2 key=$3 policy=$4
[[ $app =~ ^[0-9]+$ && $installation =~ ^[0-9]+$ ]] || { echo 'numeric App/installation IDs required' >&2; exit 2; }
[[ -f $key && ! -L $key && -r $key && -f $policy && ! -L $policy ]] || { echo 'missing or linked key/policy' >&2; exit 2; }
for cmd in curl jq openssl base64 date; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
jq -e 'type == "object" and (.repositories | type == "object") and (.permissions | type == "object") and (.repositories | length > 0) and all(.repositories[]; (.minApprovals | type == "number") and (.requiredChecks | type == "array") and (.requiredChecks | length > 0))' "$policy" >/dev/null || { echo 'invalid audit policy' >&2; exit 2; }
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
  status=$(curl -fsS --max-time 30 --request "$method" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "Authorization: Bearer $credential" \
    --output "$work/response" --write-out '%{http_code}' "$api_base$route") || { echo "GitHub request failed: $route" >&2; exit 1; }
  [[ $status == "$expected" ]] || { echo "GitHub $route: HTTP $status (expected $expected)" >&2; exit 1; }
}
request POST "/app/installations/$installation/access_tokens" "$jwt" 201
jq -er '.token | select(type == "string" and length > 0)' "$work/response" >"$work/token"
token=$(<"$work/token")
unset jwt signature
# Compare the actual installation token permissions, not what the caller thinks the App has.
actual_permissions=$(jq -c '.permissions' "$work/response")
expected_permissions=$(jq -c '.permissions' "$policy")
jq -en --argjson actual "$actual_permissions" --argjson expected "$expected_permissions" '$actual == $expected' >/dev/null || { echo 'App installation permissions differ from policy (including unexpected grants)' >&2; exit 1; }
repos='[]'; page=1
while :; do
  request GET "/installation/repositories?per_page=100&page=$page" "$token" 200
  count=$(jq -er '.repositories | arrays | length' "$work/response")
  repos=$(jq -cn --argjson old "$repos" --slurpfile new "$work/response" '$old + [$new[0].repositories[].full_name]')
  ((count < 100)) && break
  ((page+=1)); ((page <= 50)) || { echo 'repository pagination limit' >&2; exit 1; }
done
# No unexpected repository may silently enter the installation.
jq -en --argjson found "$repos" --slurpfile p "$policy" '($found | sort) == ($p[0].repositories | keys | sort)' >/dev/null || { echo 'installation repository list differs from policy' >&2; exit 1; }
for repo in $(jq -r '.[]' <<<"$repos"); do
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'invalid repo name' >&2; exit 1; }
  request GET "/repos/$repo" "$token" 200
  branch=$(jq -er '.default_branch | select(type == "string" and length > 0)' "$work/response")
  encoded=$(jq -rn --arg v "$branch" '$v|@uri')
  request GET "/repos/$repo/rules/branches/$encoded?per_page=100" "$token" 200
  jq -e 'type == "array" and length < 100' "$work/response" >/dev/null || { echo "$repo: effective rules incomplete" >&2; exit 1; }
  cp "$work/response" "$work/effective"
  # Fetch all applicable repository and parent rulesets, including bypass actors.
  sets='[]'; page=1
  while :; do
    request GET "/repos/$repo/rulesets?includes_parents=true&per_page=100&page=$page" "$token" 200
    count=$(jq -er 'arrays | length' "$work/response")
    sets=$(jq -cn --argjson a "$sets" --slurpfile b "$work/response" '$a + $b[0]')
    ((count < 100)) && break
    ((page+=1)); ((page <= 50)) || { echo "$repo: ruleset pagination limit" >&2; exit 1; }
  done
  details='[]'
  while IFS= read -r id; do
    request GET "/repos/$repo/rulesets/$id?includes_parents=true" "$token" 200
    jq -e 'type == "object" and (.rules | type == "array") and (.bypass_actors | type == "array")' "$work/response" >/dev/null || { echo "$repo: hidden ruleset details/bypass actors" >&2; exit 1; }
    details=$(jq -cn --argjson a "$details" --slurpfile b "$work/response" '$a + [$b[0]]')
  done < <(jq -er '.[].id | numbers' <<<"$sets")
  [[ $(jq 'length' <<<"$sets") == "$(jq 'length' <<<"$details")" ]] || { echo "$repo: missing ruleset details" >&2; exit 1; }
  if ! jq -e --arg repo "$repo" --argjson app "$app" --argjson rules "$details" --slurpfile effective "$work/effective" -f "${THEMOSS_AUDIT_POLICY_JQ:-$(dirname "$0")/audit-policy.jq}" "$policy" >/dev/null; then
    echo "$repo: ruleset policy failed (PR, checks, protection or App bypass)" >&2; exit 1
  fi
  echo "$repo: ruleset policy PASS"
done
unset token
printf 'App %s installation %s: PASS (%s repositories)\n' "$app" "$installation" "$(jq length <<<"$repos")"
