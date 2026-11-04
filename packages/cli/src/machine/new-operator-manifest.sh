#!/usr/bin/env bash
# Interactive, off-host manifest authoring only. Never invokes the installer.
# @describe Interactively author a private off-host operator manifest; never installs.
# @arg output! <FILE> New absolute private JSON path
set -euo pipefail
umask 077
fail() { echo "themoss manifest: $*" >&2; exit 1; }
manifest_main() {
[[ $# == 1 ]] || fail 'usage: new-operator-manifest.sh /absolute/private/operator.json'
output=$1
[[ $output == /* && $output != *..* && ! -e $output && ! -L $output ]] || fail 'choose a new absolute manifest path (no traversal or symlinks)'
[[ -d $(dirname "$output") && ! -L $(dirname "$output") ]] || fail 'manifest parent directory missing or linked'
[[ -t 0 || ${THEMOSS_TEST_INPUT:-} == 1 ]] || fail 'run interactively on a terminal'
command -v jq >/dev/null || fail 'jq required'
ask() {
  local label=$1 default=${2:-} reply
  if [[ -n $default ]]; then printf '%s [%s]: ' "$label" "$default" >&2
  else printf '%s: ' "$label" >&2; fi
  IFS= read -r reply || fail 'input cancelled'
  REPLY=${reply:-$default}
  [[ -n $REPLY ]] || fail "$label cannot be empty"
}
optional() {
  local label=$1 reply
  printf '%s (blank to omit): ' "$label" >&2
  IFS= read -r reply || fail 'input cancelled'
  REPLY=$reply
}
base=$(dirname "$output")
echo 'This file stays off-host. Do not enter secrets or store-bound credentials.' >&2
ask 'Existing mode-600 discovery record (absolute path)' "$base/record.json"; record=$REPLY
[[ $record == /* && $record != *..* && -f $record && ! -L $record && $(stat -c %a "$record") == 600 ]] || fail 'invalid discovery record'
record_target=$(jq -er '.target | select(type == "string")' "$record") || fail 'invalid record target'
record_disk=$(jq -er '.disk.path | select(type == "string")' "$record") || fail 'invalid record disk'
ask 'SSH target (must match record)' "$record_target"; target=$REPLY
[[ $target == "$record_target" ]] || fail 'target differs from discovery record'
printf 'Record selects whole disk %s. Verify with provider console.\n' "$record_disk" >&2
ask 'TYPE whole disk path (no default)'; disk=$REPLY
[[ $disk == "$record_disk" ]] || fail 'disk differs from discovery record'
ask 'Consumer Git checkout (absolute path)' "$(pwd -P)"; repo=$REPLY
[[ $repo == /* && -d $repo && ! -L $repo ]] || fail 'invalid checkout'
head=$(git -C "$repo" rev-parse --verify HEAD) || fail 'checkout has no commit'
ask 'Full pushed commit to install' "$head"; revision=$REPLY
[[ $revision =~ ^[0-9a-f]{40}$ ]] || fail 'expected full commit SHA'
current_branch=$(git -C "$repo" branch --show-current)
ask 'Pushed branch' "$current_branch"; branch=$REPLY
ask 'NixOS host output'; host_output=$REPLY
ask 'Private machine directory (credential-free machine.nix)' "$base/machine"; machine=$REPLY
ask 'New off-host install receipt path' "$base/install-receipt.json"; receipt=$REPLY
ask 'Remote checkout' /root/consumer; checkout=$REPLY
ask 'Remote private machine directory' /root/private-machine; remote_machine=$REPLY
ask 'Remote root-owned state directory' /var/lib/themoss; state=$REPLY
optional 'Consumer report generator executable'; generator=$REPLY
optional 'Consumer recovery tree (never staged in Nix)'; recovery=$REPLY
optional 'Consumer pre-erase evaluated-config check executable'; pre_erase=$REPLY
# Values are data, never evaluated as shell or embedded in a command string.
tmp=$(mktemp "${output}.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg target "$target" --arg disk "$disk" --arg record "$record" \
  --arg repo "$repo" --arg revision "$revision" --arg branch "$branch" \
  --arg output "$host_output" --arg machine "$machine" --arg receipt "$receipt" \
  --arg checkout "$checkout" --arg remote_machine "$remote_machine" --arg state "$state" \
  --arg generator "$generator" --arg recovery "$recovery" --arg pre_erase "$pre_erase" '
  {version:1, target:$target, disk:$disk, record:$record, repo:$repo, revision:$revision,
   branch:$branch, output:$output, machine:$machine, receipt:$receipt,
   remoteCheckout:$checkout, remoteMachine:$remote_machine, remoteState:$state}
  + (if $generator == "" then {} else {reportGenerator:$generator} end)
  + (if $recovery == "" then {} else {recoveryDir:$recovery} end)
  + (if $pre_erase == "" then {} else {preEraseCheck:$pre_erase} end)
' >"$tmp"
chmod 600 "$tmp"
[[ ! -e $output && ! -L $output ]] || fail 'manifest appeared while authoring'
# Hard-link based publication refuses an existing destination even if it races.
ln -- "$tmp" "$output" || fail 'could not safely publish manifest'
echo "Created $output (mode 600). Review it, then run: bash packages/cli/bin/machine/deploy.sh manifest plan '$output'" >&2
}

eval "$(argc --argc-eval "$0" "$@")"
manifest_main "$@"
