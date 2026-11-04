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
  local config target disk tmp record inputs machine repo facter
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
  record=$tmp/record.json inputs=$tmp/inputs.json
  jq .observed "$plan" >"$record"; chmod 600 "$record"
  private_input "$config" "$target" "$disk" "$record" "$inputs"
  bash "$deploy" inputs check "$inputs"
  echo "Applying reviewed INSTALL plan to $target: erase $disk after typed confirmation" >&2
  # The existing installer repeats the build, consumer check, target probe and
  # branch-tip check. Report generation occurred during plan, never here.
  jq 'del(.reportGenerator)' "$inputs" >"$tmp/install.json"
  chmod 600 "$tmp/install.json"
  bash "$deploy" inputs apply "$tmp/install.json"
}
