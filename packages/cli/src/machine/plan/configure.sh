# Private guided authoring for a new off-host desired configuration. The
# public command remains `plan`; selection is a proposal, never erase consent.
configure_ask() {
  local label=$1 default=${2:-} answer
  if [[ -n $default ]]; then printf '%s [%s]: ' "$label" "$default" >&2
  else printf '%s: ' "$label" >&2; fi
  IFS= read -r answer || fail 'configuration cancelled'
  CONFIG_ANSWER=${answer:-$default}
  [[ -n $CONFIG_ANSWER ]] || fail "$label cannot be empty"
}
configure_optional() {
  local answer
  printf '%s (blank to omit): ' "$1" >&2
  IFS= read -r answer || fail 'configuration cancelled'
  CONFIG_ANSWER=$answer
}
configure_for_plan() {
  local file=$1 target=$2 requested_disk=$3 base repo rev branch host machine receipt checkout remote_machine state generator recovery check tmp answer tip disks count disk selection
  [[ -t 0 || ${MOSS_TEST_INPUT:-} == 1 ]] || fail 'without --config, plan requires an interactive terminal'
  [[ $file == /* && $file != *..* && ! -e $file && ! -L $file ]] || fail 'choose a new absolute off-host configuration path or pass --config'
  base=$(dirname "$file")
  [[ -d $base && ! -L $base ]] || fail 'configuration directory missing or linked'
  printf 'Create %s (mode 600, off-host). No disk action occurs while answering.\n' "$file" >&2
  printf 'Do not enter secrets: machine.nix and facter.json may enter the Nix store.\n' >&2
  configure_ask 'Consumer Git checkout (absolute path)' "$(pwd -P)"; repo=$CONFIG_ANSWER
  [[ $repo == /* && -d $repo && ! -L $repo ]] || fail 'invalid consumer checkout'
  [[ $file != "$repo/"* ]] || fail 'create configuration outside the consumer checkout'
  rev=$(git -C "$repo" rev-parse --verify HEAD) || fail 'consumer checkout has no commit'
  configure_ask 'Full pushed commit' "$rev"; rev=$CONFIG_ANSWER
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || fail 'expected a full commit SHA'
  branch=$(git -C "$repo" branch --show-current)
  configure_ask 'Pushed branch' "$branch"; branch=$CONFIG_ANSWER
  [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
  tip=$(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) || fail 'pushed branch not found'
  [[ $tip == "$rev" ]] || fail 'revision differs from pushed branch tip'
  configure_ask 'NixOS host output' "$(basename "$repo")"; host=$CONFIG_ANSWER
  [[ $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid NixOS host output'
  configure_ask 'Private machine directory with credential-free machine.nix' "$base/machine"; machine=$CONFIG_ANSWER
  configure_ask 'Off-host install receipt' "$base/install-receipt.json"; receipt=$CONFIG_ANSWER
  configure_ask 'Remote checkout' "/root/$(basename "$repo")"; checkout=$CONFIG_ANSWER
  configure_ask 'Remote private machine directory' /root/private-machine; remote_machine=$CONFIG_ANSWER
  configure_ask 'Remote root-owned state directory' /var/lib/themoss; state=$CONFIG_ANSWER
  configure_optional 'Consumer report generator executable'; generator=$CONFIG_ANSWER
  configure_optional 'Consumer recovery tree (never staged in Nix)'; recovery=$CONFIG_ANSWER
  configure_optional 'Consumer evaluated pre-erase check executable'; check=$CONFIG_ANSWER
  disk=''
  if [[ -e $receipt || -L $receipt ]]; then
    [[ -z $requested_disk ]] || fail 'installed receipt exists; never select a disk for an update'
  else
    disks=$(bash "$deploy" list-disks "$target") || fail 'cannot list whole disks on target'
    count=$(jq -r 'length' <<<"$disks")
    ((count > 0)) || fail 'target reported no whole disks'
    printf 'Whole disks detected on %s:\n' "$target" >&2
    jq -r 'to_entries[] | "  \(.key + 1). \(.value.path) size=\(.value.size) model=\(.value.model // "unknown") serial=\(.value.serial // "unknown")"' <<<"$disks" >&2
    if [[ -n $requested_disk ]]; then
      [[ $(jq --arg disk "$requested_disk" '[.[] | select(.path == $disk)] | length' <<<"$disks") == 1 ]] || fail '--disk is not a unique whole disk on target'
      disk=$requested_disk
    elif ((count == 1)); then
      disk=$(jq -r '.[0].path' <<<"$disks")
      printf 'Only one whole disk; proposing %s (NOT authorization to erase).\n' "$disk" >&2
    else
      printf 'Select whole disk [1-%s] (no default): ' "$count" >&2
      IFS= read -r selection || fail 'disk selection cancelled'
      [[ $selection =~ ^[1-9][0-9]*$ ]] || fail 'invalid disk selection'
      ((selection >= 1 && selection <= count)) || fail 'disk selection out of range'
      disk=$(jq -r --argjson index "$((selection - 1))" '.[$index].path' <<<"$disks")
    fi
    [[ $disk =~ ^/dev/[a-zA-Z0-9_./-]+$ && $disk != *..* ]] || fail 'unsafe whole-disk path'
  fi
  CONFIG_DISK=$disk
  tmp=$(mktemp "$base/.moss-config.XXXXXXXX")
  trap "rm -f -- $(printf '%q' "$tmp")" EXIT
  jq -n --arg repo "$repo" --arg revision "$rev" --arg branch "$branch" \
    --arg output "$host" --arg machine "$machine" --arg receipt "$receipt" \
    --arg checkout "$checkout" --arg remote_machine "$remote_machine" --arg state "$state" \
    --arg generator "$generator" --arg recovery "$recovery" --arg check "$check" --arg disk "$disk" '
    {version:1,repo:$repo,revision:$revision,branch:$branch,output:$output,
     machine:$machine,receipt:$receipt,remoteCheckout:$checkout,
     remoteMachine:$remote_machine,remoteState:$state}
    + (if $generator == "" then {} else {reportGenerator:$generator} end)
    + (if $recovery == "" then {} else {recoveryDir:$recovery} end)
    + (if $check == "" then {} else {preEraseCheck:$check} end)
    + (if $disk == "" then {} else {disk:$disk} end)
  ' >"$tmp"
  chmod 600 "$tmp"
  config_file "$tmp"
  printf 'Review the private configuration below before saving:\n' >&2
  jq . "$tmp" >&2
  printf 'Save this configuration? [y/N] ' >&2
  IFS= read -r answer || fail 'configuration cancelled'
  [[ $answer == y || $answer == Y ]] || fail 'configuration not saved'
  [[ ! -e $file && ! -L $file ]] || fail 'configuration appeared during authoring'
  ln -- "$tmp" "$file" || fail 'cannot publish configuration without overwriting'
  rm -f -- "$tmp"
  trap - EXIT
  printf 'Created %s (mode 600); plan will now re-probe the selected target.\n' "$file" >&2
}
