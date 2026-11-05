#!/usr/bin/env bash
# Operator interface. bin/machine/ is private implementation, not a public namespace.
# Keep off-host configuration and plans out of the Nix store.
# @describe Initialize local storage and plan reviewed changes to a themoss machine
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
  moss_private_path "$1"
}
config_file() {
  private_file "$1"
  jq -e '
    type == "object" and .version == 1 and
    ((keys - ["version","repo","revision","branch","output","machine","receipt","remoteCheckout","remoteMachine","remoteState","reportGenerator","recoveryDir","preEraseCheck","disk"]) == []) and
    ([.repo,.revision,.branch,.output,.machine,.receipt,.remoteCheckout,.remoteMachine,.remoteState] | all(type == "string" and length > 0)) and
    ([.reportGenerator // "-",.recoveryDir // "-",.preEraseCheck // "-"] | all(type == "string" and length > 0)) and
    (if has("disk") then (.disk | type == "string" and test("^/dev/[A-Za-z0-9_./-]+$") and (contains("..") | not)) else true end)
  ' "$1" >/dev/null || fail 'invalid private machine configuration'
  local repo machine receipt recovery
  repo=$(jq -r .repo "$1") machine=$(jq -r .machine "$1")
  [[ $repo == /* && -d $repo && ! -L $repo && $(realpath -m "$repo") == "$(realpath "$repo")" ]] || fail 'invalid checkout'
  [[ $machine == /* && $machine != *..* && -d $machine && ! -L $machine && -f $machine/machine.nix && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine input'
  [[ $(realpath -m "$machine") == "$(realpath "$machine")" ]] || fail 'linked private machine path'
  moss_private_path "$machine/machine.nix"
  moss_private_path "$machine/facter.json"
  receipt=$(jq -r .receipt "$1")
  moss_private_path "$receipt"
  recovery=$(jq -r '.recoveryDir // ""' "$1")
  if [[ -n $recovery ]]; then moss_private_dir "$recovery"; fi
}
# Never evaluate operator JSON as shell. This is a private adapter to the
# existing strict toolkit validator; the generated inputs is ephemeral.
private_input() {
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

# @include machine/helpers/store.sh
# @include init/cli.sh
# @include machine/plan/configure.sh
# @include machine/plan/cli.sh

# @include machine/apply/cli.sh

# @include machine/bootstrap/cli.sh

eval "$(argc --argc-eval "$0" "$@")"
