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

# @include machine/plan/cli.sh

# @include machine/apply/cli.sh

# @include machine/bootstrap/cli.sh

eval "$(argc --argc-eval "$0" "$@")"
