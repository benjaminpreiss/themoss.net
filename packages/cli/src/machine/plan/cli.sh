# @cmd Inspect the target and build a non-destructive reviewed installation plan
# @arg target! <ROOT@HOST> Known rescue SSH target (verify host key independently)
# @option --config <FILE> Existing private configuration; omit for guided creation
# @option --disk <DISK> Optional explicit whole disk; otherwise detect and select during guided install
# @option --output <FILE> New private plan file; defaults to .moss for this target
machine::plan() {
  local config=${argc_config:-} target=$argc_target disk=${argc_disk:-} output=${argc_output:-} store=''
  [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'invalid SSH target'
  if [[ -z $config || -z $output ]]; then
    store=$(moss_target_store "$target") || return
    moss_prepare_store "$store"
    if [[ -z $config ]]; then config="$store/machine.json"; fi
    if [[ -z $output ]]; then output=$(moss_new_plan_path "$store"); fi
  fi
  [[ $output == /* && $output != *..* && ! -e $output && ! -L $output && -d $(dirname "$output") && ! -L $(dirname "$output") ]] || fail 'choose a new absolute private plan path'
  if [[ ! -e $config && ! -L $config && -z ${argc_config:-} ]]; then
    configure_for_plan "$config" "$target" "$disk"
    disk=$CONFIG_DISK
  fi
  config_file "$config"
  if [[ -n $store ]]; then
    [[ $(jq -r .repo "$config") == "$(moss_repo_root)" ]] || fail 'default .moss storage must belong to the consumer checkout'
  fi
  local tmp record inputs repo rev machine host branch generator check sha facter origin receipt checkout remote_machine state expected config_disk
  repo=$(jq -r .repo "$config") rev=$(jq -r .revision "$config")
  machine=$(jq -r .machine "$config") host=$(jq -r .output "$config")
  branch=$(jq -r .branch "$config") receipt=$(jq -r .receipt "$config")
  origin=$(git -C "$repo" remote get-url origin)
  if [[ -e $receipt || -L $receipt ]]; then
    [[ -z $disk ]] || fail 'installed receipt exists; never reformat to repair or update'
    private_file "$receipt"
    [[ $target == "$(jq -er .target "$receipt")" && $origin == "$(jq -er .origin "$receipt")" ]] || fail 'receipt target or origin changed'
    checkout=$(jq -r .remoteCheckout "$config") remote_machine=$(jq -r .remoteMachine "$config") state=$(jq -r .remoteState "$config")
    for path in "$checkout" "$remote_machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'invalid target path'
    done
    [[ $host =~ ^[a-zA-Z0-9_-]+$ && $rev =~ ^[0-9a-f]{40}$ && $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid update reference'
    expected=$(remote_call "$target" plan-update "$checkout" "$remote_machine" "$host" "$state" "$branch" "$rev" "$origin")
    jq -e --arg rev "$rev" --arg sha "$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)" --arg selected "branch:$branch" \
      '.next == $rev and .machineSha256 == $sha and .selected == $selected' <<<"$expected" >/dev/null || fail 'update differs from reviewed inputs; transition requires separate review'
    tmp=$(mktemp -d "$(dirname "$output")/.moss-plan.XXXXXXXX")
    trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
    jq -n --arg config "$(realpath "$config")" --arg configSha256 "$(sha256sum "$config" | cut -d ' ' -f1)" \
      --arg target "$target" --arg origin "$origin" --argjson expected "$expected" \
      '{version:1,type:"update",config:$config,configSha256:$configSha256,target:$target,origin:$origin,expected:$expected}' >"$tmp/plan.json"
    chmod 600 "$tmp/plan.json"
    [[ ! -e $output && ! -L $output ]] || fail 'plan appeared during evaluation'
    ln -- "$tmp/plan.json" "$output" || fail 'cannot publish plan'
    if [[ -n $store ]]; then moss_publish_latest "$store" "$output"; fi
    echo "Reviewed update plan: $target $(jq -r .current <<<"$expected") -> $rev (no disk action). Saved $output"
    return
  fi
  config_disk=$(jq -r '.disk // ""' "$config")
  [[ -z $disk || -z $config_disk || $disk == "$config_disk" ]] || fail 'selected disk differs from reviewed configuration'
  disk=${disk:-$config_disk}
  [[ $disk =~ ^/dev/[a-zA-Z0-9_./-]+$ && $disk != *..* ]] || fail 'fresh install requires a reviewed whole /dev disk'
  tmp=$(mktemp -d "$(dirname "$output")/.moss-plan.XXXXXXXX")
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  record=$tmp/record.json inputs=$tmp/inputs.json
  bash "$deploy" discover "$target" "$disk" "$record"
  private_input "$config" "$target" "$disk" "$record" "$inputs"
  bash "$deploy" inputs check "$inputs"
  generator=$(jq -r '.reportGenerator // "-"' "$config")
  check=$(jq -r '.preEraseCheck // "-"' "$config")
  bash "$deploy" plan-build "$record" "$repo" "$rev" "$machine" "$host" "$branch" "$generator" "$check"
  sha=$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)
  facter=''
  if [[ -e $machine/facter.json ]]; then facter=$(sha256sum "$machine/facter.json" | cut -d ' ' -f1); fi
  jq -n --arg config "$(realpath "$config")" --arg configSha256 "$(sha256sum "$config" | cut -d ' ' -f1)" \
    --arg target "$target" --arg disk "$disk" --arg machineSha256 "$sha" --arg facterSha256 "$facter" \
    --arg origin "$origin" --argjson observed "$(jq -c . "$record")" \
    '{version:1,type:"install",config:$config,configSha256:$configSha256,target:$target,disk:$disk,observed:$observed,machineSha256:$machineSha256,facterSha256:$facterSha256,origin:$origin}' >"$tmp/plan.json"
  chmod 600 "$tmp/plan.json"
  [[ ! -e $output && ! -L $output ]] || fail 'plan appeared during evaluation'
  ln -- "$tmp/plan.json" "$output" || fail 'cannot publish plan'
  if [[ -n $store ]]; then moss_publish_latest "$store" "$output"; fi
  echo "Installation plan saved: $output (review before applying; not an authorization to erase)"
}
