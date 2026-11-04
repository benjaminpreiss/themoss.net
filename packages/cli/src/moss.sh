#!/usr/bin/env bash
# Operator interface. bin/machine/ is private implementation, not a public namespace.
# Keep off-host configuration and plans out of the Nix store.
# @describe Plan and apply reviewed changes to a themoss machine
set -euo pipefail
umask 077
fail() { echo "moss: $*" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
while [[ $root != / && ! -f $root/bin/machine/deploy.sh ]]; do root=$(dirname "$root"); done
[[ -f $root/bin/machine/deploy.sh ]] || fail 'the pinned CLI implementation is missing'
deploy=$root/bin/machine/deploy.sh
private_file() {
  [[ $1 == /* && $1 != *..* && -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]] || fail "expected absolute mode-600 private file: $1"
  [[ $(realpath -m "$1") == "$(realpath "$1")" ]] || fail 'linked private path'
}
config_file() {
  private_file "$1"
  jq -e '
    type == "object" and .version == 1 and
    ((keys - ["version","repo","revision","branch","output","machine","receipt","remoteCheckout","remoteMachine","remoteState","reportGenerator","recoveryDir","preEraseCheck"]) == []) and
    ([.repo,.revision,.branch,.output,.machine,.receipt,.remoteCheckout,.remoteMachine,.remoteState] | all(type == "string" and length > 0)) and
    ([.reportGenerator // "-",.recoveryDir // "-",.preEraseCheck // "-"] | all(type == "string" and length > 0))
  ' "$1" >/dev/null || fail 'invalid private machine configuration'
  local repo path relative machine
  repo=$(jq -r .repo "$1") machine=$(jq -r .machine "$1")
  [[ $repo == /* && -d $repo && ! -L $repo && $(realpath -m "$repo") == "$(realpath "$repo")" ]] || fail 'invalid checkout'
  [[ $machine == /* && $machine != *..* && -d $machine && ! -L $machine && -f $machine/machine.nix && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine input'
  [[ $(realpath -m "$machine") == "$(realpath "$machine")" ]] || fail 'linked private machine path'
  path=$(realpath "$1")
  if [[ $path == "$repo/"* ]]; then
    relative=${path#"$repo/"}
    git -C "$repo" check-ignore -q -- "$relative" || fail 'private configuration in checkout must be Git-ignored'
    [[ -z $(git -C "$repo" ls-files -- "$relative") ]] || fail 'tracked private configuration'
  fi
}
# Never evaluate operator JSON as shell. This is a private adapter to the
# existing strict toolkit validator; the generated manifest is ephemeral.
legacy_input() {
  local config=$1 target=$2 disk=$3 record=$4 destination=$5
  jq -n --argjson c "$(jq -c . "$config")" --arg target "$target" --arg disk "$disk" --arg record "$record" \
    '$c + {target:$target,disk:$disk,record:$record}' >"$destination"
  chmod 600 "$destination"
}
remote_call() {
  local target=$1 task=$2 arg quoted cmd="bash -s -- $2"
  shift 2
  for arg in "$@"; do printf -v quoted '%q' "$arg"; cmd+=" $quoted"; done
  ssh -o StrictHostKeyChecking=yes "$target" "$cmd" <"$deploy"
}
# @cmd Operate on a machine
machine() { :; }

# @cmd Inspect the target and build a non-destructive reviewed installation plan
# @arg target! <ROOT@HOST> Known rescue SSH target (verify host key independently)
# @option --config! <FILE> Private off-host desired configuration
# @option --disk <DISK> Explicit whole /dev disk for a fresh install; omit for an installed host
# @option --output! <FILE> New private plan file
machine::plan() {
  local config=$argc_config target=$argc_target disk=${argc_disk:-} output=$argc_output
  [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'invalid SSH target'
  [[ $output == /* && $output != *..* && ! -e $output && ! -L $output && -d $(dirname "$output") && ! -L $(dirname "$output") ]] || fail 'choose a new absolute private plan path'
  config_file "$config"
  local tmp record manifest repo rev machine host branch generator check sha facter origin receipt checkout remote_machine state expected
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
    echo "Reviewed update plan: $target $(jq -r .current <<<"$expected") -> $rev (no disk action). Saved $output"
    return
  fi
  [[ $disk =~ ^/dev/[a-zA-Z0-9_./-]+$ && $disk != *..* ]] || fail 'fresh install requires an explicitly chosen whole /dev disk'
  tmp=$(mktemp -d "$(dirname "$output")/.moss-plan.XXXXXXXX")
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  record=$tmp/record.json manifest=$tmp/inputs.json
  bash "$deploy" discover "$target" "$disk" "$record"
  legacy_input "$config" "$target" "$disk" "$record" "$manifest"
  bash "$deploy" manifest plan "$manifest"
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
  echo "Installation plan saved: $output (review before applying; not an authorization to erase)"
}

# @cmd Revalidate and apply a reviewed plan; installation erases the selected disk
# @arg plan! <FILE> Private typed plan produced by machine plan
machine::apply() {
  local plan=$argc_plan
  private_file "$plan"
  if [[ $(jq -er '.type' "$plan") == update ]]; then
    jq -e 'type == "object" and .version == 1 and .type == "update" and
      ((keys - ["version","type","config","configSha256","target","origin","expected"]) == []) and
      ([.config,.configSha256,.target,.origin] | all(type == "string" and length > 0)) and
      (.expected | type == "object" and ((keys - ["current","selected","next","machineSha256"]) == []) and
        ([.current,.selected,.next,.machineSha256] | all(type == "string" and length > 0)))
    ' "$plan" >/dev/null || fail 'invalid update plan'
    local config target repo receipt origin checkout machine state host branch expected_current expected_next expected_sha
    config=$(jq -r .config "$plan") target=$(jq -r .target "$plan")
    config_file "$config"
    [[ $(sha256sum "$config" | cut -d ' ' -f1) == "$(jq -r .configSha256 "$plan")" ]] || fail 'configuration changed; make a new plan'
    repo=$(jq -r .repo "$config") receipt=$(jq -r .receipt "$config")
    private_file "$receipt"
    origin=$(git -C "$repo" remote get-url origin)
    [[ $target == "$(jq -er .target "$receipt")" && $origin == "$(jq -r .origin "$plan")" && $origin == "$(jq -er .origin "$receipt")" ]] || fail 'target or Git origin changed'
    checkout=$(jq -r .remoteCheckout "$config") machine=$(jq -r .remoteMachine "$config")
    state=$(jq -r .remoteState "$config") host=$(jq -r .output "$config") branch=$(jq -r .branch "$config")
    for path in "$checkout" "$machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'invalid target path'
    done
    expected_current=$(jq -r .expected.current "$plan") expected_next=$(jq -r .expected.next "$plan")
    expected_sha=$(jq -r .expected.machineSha256 "$plan")
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ && $host =~ ^[a-zA-Z0-9_-]+$ && $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* && $expected_next == "$(jq -r .revision "$config")" && $(jq -r .expected.selected "$plan") == "branch:$branch" ]] || fail 'update plan differs from selected branch or revision'
    [[ -f $(jq -r .machine "$config")/machine.nix && $(sha256sum "$(jq -r .machine "$config")/machine.nix" | cut -d ' ' -f1) == "$expected_sha" ]] || fail 'machine input changed; use a reviewed transition'
    echo "Applying reviewed UPDATE $target: $expected_current -> $expected_next (never erases disks)" >&2
    remote_call "$target" apply-reviewed "$checkout" "$machine" "$host" "$state" "branch:$branch" "$expected_current" "$expected_next" "$expected_sha" "$origin"
    return
  fi
  jq -e 'type == "object" and .version == 1 and .type == "install" and
    ((keys - ["version","type","config","configSha256","target","disk","observed","machineSha256","facterSha256","origin"]) == []) and
    ([.config,.configSha256,.target,.disk,.machineSha256,.origin] | all(type == "string" and length > 0)) and
    (.facterSha256 | type == "string") and (.observed | type == "object")' "$plan" >/dev/null || fail 'unknown or invalid plan type; no action taken'
  local config target disk tmp record manifest machine repo facter
  config=$(jq -r .config "$plan") target=$(jq -r .target "$plan") disk=$(jq -r .disk "$plan")
  config_file "$config"
  [[ $(sha256sum "$config" | cut -d ' ' -f1) == "$(jq -r .configSha256 "$plan")" ]] || fail 'configuration changed; make a new plan'
  repo=$(jq -r .repo "$config") machine=$(jq -r .machine "$config")
  [[ $(git -C "$repo" remote get-url origin) == "$(jq -r .origin "$plan")" ]] || fail 'Git origin changed; make a new plan'
  [[ $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$(jq -r .machineSha256 "$plan")" ]] || fail 'machine input changed; make a new plan'
  facter=$(jq -r .facterSha256 "$plan")
  if [[ -n $facter ]]; then
    [[ -f $machine/facter.json && ! -L $machine/facter.json && $(sha256sum "$machine/facter.json" | cut -d ' ' -f1) == "$facter" ]] || fail 'hardware report changed; make a new plan'
  else
    [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'hardware report changed; make a new plan'
  fi
  [[ $target == "$(jq -r .observed.target "$plan")" && $disk == "$(jq -r .observed.disk.path "$plan")" ]] || fail 'plan target or disk differs from recorded facts'
  tmp=$(mktemp -d "$(dirname "$plan")/.moss-apply.XXXXXXXX")
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  record=$tmp/record.json manifest=$tmp/inputs.json
  jq .observed "$plan" >"$record"; chmod 600 "$record"
  legacy_input "$config" "$target" "$disk" "$record" "$manifest"
  bash "$deploy" manifest plan "$manifest"
  echo "Applying reviewed INSTALL plan to $target: erase $disk after typed confirmation" >&2
  # The existing installer repeats the build, consumer check, target probe and
  # branch-tip check. Report generation occurred during plan, never here.
  jq 'del(.reportGenerator)' "$manifest" >"$tmp/install.json"
  chmod 600 "$tmp/install.json"
  bash "$deploy" manifest install "$tmp/install.json"
}

# @cmd Resume first-boot handoff after independently verifying the new SSH host key
# @arg receipt! <FILE> Off-host installation receipt
# @option --config! <FILE> Original private machine configuration
machine::bootstrap() {
  local receipt=$argc_receipt config=$argc_config
  private_file "$receipt"; config_file "$config"
  local repo machine checkout remote_machine state
  repo=$(jq -r .repo "$config") machine=$(jq -r .machine "$config")
  checkout=$(jq -r .remoteCheckout "$config") remote_machine=$(jq -r .remoteMachine "$config") state=$(jq -r .remoteState "$config")
  [[ $receipt == "$(jq -r .receipt "$config")" ]] || fail 'receipt differs from configuration'
  bash "$deploy" bootstrap "$receipt" "$repo" "$machine" "$checkout" "$remote_machine" "$state"
}

eval "$(argc --argc-eval "$0" "$@")"
