# @cmd Resume first-boot handoff after independently verifying the new SSH host key
# @arg receipt! <FILE> Off-host installation receipt
# @option --config <FILE> Original private machine configuration; defaults to .moss for the receipt target
machine::bootstrap() {
  local receipt=$argc_receipt config=${argc_config:-} target store
  private_file "$receipt"
  if [[ -z $config ]]; then
    target=$(jq -er .target "$receipt") || fail 'invalid receipt target'
    store=$(moss_target_store "$target") || return
    config="$store/machine.json"
  fi
  config_file "$config"
  local repo machine checkout remote_machine state
  repo=$(jq -r .repo "$config") machine=$(jq -r .machine "$config")
  checkout=$(jq -r .remoteCheckout "$config") remote_machine=$(jq -r .remoteMachine "$config") state=$(jq -r .remoteState "$config")
  [[ $receipt == "$(jq -r .receipt "$config")" ]] || fail 'receipt differs from configuration'
  bash "$deploy" bootstrap "$receipt" "$repo" "$machine" "$checkout" "$remote_machine" "$state"
}
