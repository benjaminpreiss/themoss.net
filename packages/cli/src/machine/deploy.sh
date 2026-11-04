#!/usr/bin/env bash
# Shared deployment mechanics. Consumer owns the flake, private machine module,
# disk layout, branch policy and update cadence. Requires Bash, jq, git, Nix.
#
# Private machine implementation for moss machine plan/apply/bootstrap and
# target-side polling. Only install calls nixos-anywhere; updates never do.
# @describe Internal machine protocol; use moss machine for operator commands.
set -euo pipefail
export LC_ALL=C
umask 077
fail() { echo "themoss: $*" >&2; exit 1; }
# argc declarations below strictly parse private and target-side calls.
# Public operators never invoke this implementation entry point directly.
usage() { fail 'invalid arguments; run deploy.sh --help'; }

probe() {
  local target=$1
  # Verify the SSH fingerprint out of band before calling us. Never accept-new.
  local raw arch boot routes disks nic mac
  # Collect facts in one SSH session; read the selected NIC's MAC separately
  # after parsing the single default route. Ambiguity is a stop, not a guess.
  raw=$(ssh -o StrictHostKeyChecking=yes "$target" bash -s <<'REMOTE'
set -euo pipefail
uname -m
if [[ -d /sys/firmware/efi ]]; then echo uefi; else echo bios; fi
ip -j route show default
lsblk -J -d -b -o PATH,TYPE,SIZE,MODEL,SERIAL
REMOTE
  )
  arch=$(printf '%s\n' "$raw" | head -n 1)
  boot=$(printf '%s\n' "$raw" | head -n 2 | tail -n 1)
  routes=$(printf '%s\n' "$raw" | head -n 3 | tail -n 1)
  disks=$(printf '%s\n' "$raw" | tail -n +4)
  nic=$(jq -er 'if length == 1 then .[0].dev else error("ambiguous default route") end' <<<"$routes")
  [[ $nic =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'invalid NIC'
  mac=$(ssh -o StrictHostKeyChecking=yes "$target" "cat /sys/class/net/$nic/address")
  jq -n --arg arch "$arch" --arg boot "$boot" --arg nic "$nic" --arg mac "$mac" --argjson block "$disks" \
    '{arch:$arch,boot:$boot,nic:$nic,mac:$mac,disks:[$block.blockdevices[] | select(.type == "disk") | {path,type,size,model,serial}]}'
}
private_record() {
  [[ -f $1 && ! -L $1 ]] || fail 'private record missing or linked'
  [[ $(stat -c %a "$1") == 600 ]] || fail 'private record must be mode 600'
  jq -e '.target and .disk.path and .arch and .boot and .nic and .mac' "$1" >/dev/null || fail 'invalid record'
}
check() {
  local record=$1 actual disk
  private_record "$record"
  # Re-probe rather than trusting the discovery record: devices can change
  # between preparation, build and the final erase confirmation.
  actual=$(probe "$(jq -r .target "$record")")
  jq -e --argjson actual "$actual" '
    . as $r | ($actual | .arch == $r.arch and .boot == $r.boot and .nic == $r.nic and .mac == $r.mac)
    and ([$actual.disks[] | select(.path == $r.disk.path and .type == "disk" and .size == $r.disk.size and .model == $r.disk.model and .serial == $r.disk.serial)] | length == 1)
  ' "$record" >/dev/null || fail 'target architecture, boot, NIC/MAC or whole-disk identity changed'
  disk=$(jq -r .disk.path "$record")
  printf 'Target: %s; arch=%s boot=%s NIC=%s MAC=%s\n' "$(jq -r .target "$record")" "$(jq -r .arch "$record")" "$(jq -r .boot "$record")" "$(jq -r .nic "$record")" "$(jq -r .mac "$record")"
  printf 'WHOLE DISK TO ERASE: %s; size=%s model=%s serial=%s\n' "$disk" "$(jq -r .disk.size "$record")" "$(jq -r .disk.model "$record")" "$(jq -r .disk.serial "$record")"
}
stage() {
  local repo=$1 rev=$2 machine=$3 dest=$4 entry
  [[ -d $machine && ! -L $machine && -f $machine/machine.nix && ! -L $machine/machine.nix ]] || fail 'missing private machine.nix'
  # No local changes, .git, symlinks or credentials enter the stage.
  [[ -z $(git -C "$repo" ls-tree -r "$rev" | grep '^120000 ' || true) ]] || fail 'linked source in commit'
  git -C "$repo" archive --format=tar "$rev" | tar -tf - | while IFS= read -r entry; do
    [[ $entry != /* && $entry != *../* ]] || fail 'unsafe archive path'
  done
  git -C "$repo" archive --format=tar "$rev" | tar -xf - -C "$dest" --no-same-owner
  [[ -f $dest/flake.lock && ! -e $dest/generated ]] || fail 'committed lock required; generated/ must not be committed'
  # Archive may include symlinks; Nix would follow them. Reject all.
  [[ -z $(find "$dest" -type l -print -quit) ]] || fail 'linked source in archive'
  mkdir -m 700 "$dest/generated"
  cp -- "$machine/machine.nix" "$dest/generated/machine.nix"
  if [[ -e $machine/facter.json ]]; then
    [[ -f $machine/facter.json && ! -L $machine/facter.json ]] || fail 'linked facter report'
    cp -- "$machine/facter.json" "$dest/generated/facter.json"
  fi
  # These files MUST be credential-free: Nix store paths are world readable.
}
build() { nix build --no-link --no-write-lock-file "$1#nixosConfigurations.$2.config.system.build.toplevel"; }
valid_ref() {
  if [[ $1 == commit:* ]]; then [[ ${1#commit:} =~ ^[0-9a-f]{40}$ ]]
  elif [[ $1 == branch:* ]]; then
    [[ ${1#branch:} =~ ^[a-zA-Z0-9_/-]+$ && $1 != *..* && $1 != */ && $1 != *//* ]]
    git check-ref-format "refs/heads/${1#branch:}" >/dev/null 2>&1
  else return 1; fi
}
locked_state() {
  [[ -d $1 && ! -L $1 && $(stat -c %a "$1") == 700 ]] || fail 'root-only state directory required'
  [[ $(id -u) == 0 || ${THEMOSS_TEST_ROOT:-} == 1 ]] || fail 'root required'
  [[ $(stat -c %u "$1") == 0 || ${THEMOSS_TEST_ROOT:-} == 1 ]] || fail 'state must be root-owned'
  exec 9>"$1/lock"
  flock -n 9 || fail 'deployment already running'
  [[ ! -e $1/needs-inspection && ! -L $1/needs-inspection ]] || fail 'switch outcome requires operator inspection'
  [[ -f $1/revision && ! -L $1/revision ]] || fail 'missing known-good revision'
  current=$(<"$1/revision")
  [[ $current =~ ^[0-9a-f]{40}$ ]] || fail 'invalid known-good revision'
}
selector() {
  [[ -f $1/selector && ! -L $1/selector && $(stat -c %a "$1/selector") == 600 ]] || fail 'missing root-only selector; bootstrap or adopt only after review'
  [[ $(stat -c %u "$1/selector") == 0 || ${THEMOSS_TEST_ROOT:-} == 1 ]] || fail 'selector must be root-owned'
  selected=$(<"$1/selector")
  valid_ref "$selected" || fail 'invalid selector'
}
branch_tip() {
  local repo=$1 branch=$2 tip
  # A fully qualified refspec prevents FETCH_HEAD from including other branches.
  git -C "$repo" fetch --no-tags origin "refs/heads/$branch"
  tip=$(git -C "$repo" rev-parse FETCH_HEAD)
  [[ $tip =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$tip") == commit ]] || fail 'invalid fetched tip'
  printf '%s\n' "$tip"
}
record_switch() {
  local state=$1 ref=$2 rev=$3
  # Once switching begins, failures (including a partial activation) block
  # further automation until the operator has reconciled the running system.
  printf 'inspect generation and state before recovery\n' >"$state/needs-inspection"
  nixos-rebuild switch --flake "$4#$5" --no-write-lock-file
  if [[ -n ${6:-} ]]; then
    cp -- "$6" "$7/machine.nix.tmp"
    chmod 600 "$7/machine.nix.tmp"
    mv -- "$7/machine.nix.tmp" "$7/machine.nix"
  fi
  printf '%s\n' "$ref" >"$state/selector.tmp"
  printf '%s\n' "$rev" >"$state/revision.tmp"
  chmod 600 "$state/selector.tmp" "$state/revision.tmp"
  mv -f -- "$state/revision.tmp" "$state/revision"
  mv -f -- "$state/selector.tmp" "$state/selector"
  rm -- "$state/needs-inspection"
}
verify_tip() {
  [[ $(git -C "$1" ls-remote --exit-code origin "refs/heads/$2" | cut -f1) == "$3" ]] || fail 'branch tip changed during deployment; retry'
}
_machine_internal() {
local op=$1; shift
case $op in
# @include plan/inputs.sh
# @include plan/update.sh
# @include apply/update.sh
# @include plan/install.sh
# @include plan/observe.sh
# @include apply/install.sh
# @include bootstrap/operator.sh
# @include adopt/operator.sh
# @include transition/operator.sh
# @include transition/prepare.sh
# @include update/target.sh
  *) usage ;;
esac
}

# @cmd Create a private discovery record for one whole disk
# @arg target! <TARGET> Root SSH target
# @arg disk! <DISK> Whole /dev disk
# @arg record! <FILE> New private discovery record
discover() { _machine_internal discover "$@"; }

# @cmd Re-probe and compare the target with its discovery record
# @arg record! <FILE> Private discovery record
preflight() { _machine_internal preflight "$@"; }

# @cmd Build and install an exact pushed revision; erases the selected disk
# @arg record! <FILE> Discovery record
# @arg repo! <DIR> Clean consumer checkout
# @arg rev! <REV> Full pushed commit
# @arg machine! <DIR> Credential-free private inputs
# @arg host! <HOST> NixOS output
# @arg branch! <BRANCH> Pushed branch
# @arg receipt! <FILE> New off-host receipt
# @arg generator <FILE> Report generator, or -
# @arg recovery <DIR> Recovery tree, or -
# @arg pre_erase <FILE> Pre-erase check, or -
install() { _machine_internal install "$@"; }

# @cmd Bootstrap the exact installed revision without erasing disks
# @arg receipt! <FILE> Off-host receipt
# @arg repo! <DIR> Consumer checkout
# @arg machine! <DIR> Original private inputs
# @arg checkout! <PATH> Remote checkout
# @arg remote_machine! <PATH> Remote machine directory
# @arg state! <PATH> Remote root-only state
bootstrap() { _machine_internal bootstrap "$@"; }

# @cmd Internal: adopt a verified existing host without reinstalling
# @arg evidence! <FILE> Operator-verified evidence
# @arg repo! <DIR> Consumer checkout
# @arg machine! <DIR> Original private inputs
# @arg host! <HOST> NixOS output
# @arg checkout! <PATH> Remote checkout
# @arg remote_machine! <PATH> Remote machine directory
# @arg state! <PATH> Remote state
adopt() { _machine_internal adopt "$@"; }

# @cmd Run a reviewed non-destructive candidate transition
# @arg receipt! <FILE> Install receipt
# @arg target! <TARGET> Root SSH target
# @arg checkout! <PATH> Remote checkout
# @arg branch! <BRANCH> Candidate branch
# @arg new_machine! <DIR> Reviewed private machine input
# @arg remote_machine! <PATH> Remote machine directory
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Remote state
transition() { _machine_internal transition "$@"; }

# @cmd Poll the root-owned selector for a new revision (target-side)
# @arg repo! <DIR> Target checkout
# @arg machine! <DIR> Target private machine input
# @arg host! <HOST> NixOS output
# @arg state! <DIR> Root-only state
poll() { _machine_internal poll "$@"; }

# @cmd Switch to an explicitly selected revision (target-side)
# @arg repo! <DIR> Target checkout
# @arg ref! <REF> commit:SHA or branch:NAME
# @arg machine! <DIR> Target private machine input
# @arg host! <HOST> NixOS output
# @arg state! <DIR> Root-only state
deploy() { _machine_internal deploy "$@"; }

# @cmd Internal: validate ephemeral installation inputs
inputs() { :; }

# @cmd Internal: re-probe and check an off-host installation proposal
# @arg file! <FILE> Mode-600 ephemeral input data
inputs::check() { _machine_internal inputs check "$@"; }

# @cmd Internal: revalidate and install from reviewed input data
# @arg file! <FILE> Mode-600 ephemeral input data
inputs::apply() { _machine_internal inputs apply "$@"; }

# @cmd Internal: build and check a reviewed branch update without switching
# @arg repo! <PATH> Target checkout
# @arg machine! <PATH> Target private machine inputs
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Root-only state
# @arg branch! <BRANCH> Selected branch
# @arg rev! <REV> Exact candidate tip
# @arg origin! <URL> Reviewed Git origin
plan-update() { _machine_internal plan-update "$@"; }

# @cmd Internal: switch only the exact reviewed branch update
# @arg repo! <PATH> Target checkout
# @arg machine! <PATH> Target private machine inputs
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Root-only state
# @arg selected! <REF> Reviewed branch selector
# @arg current! <REV> Reviewed installed revision
# @arg next! <REV> Reviewed candidate revision
# @arg sha! <SHA> Reviewed private machine input
# @arg origin! <URL> Reviewed Git origin
apply-reviewed() { _machine_internal apply-reviewed "$@"; }

# @cmd Internal: build and check a fresh install plan without erasing
# @arg record! <FILE> Private observed facts
# @arg repo! <DIR> Clean consumer checkout
# @arg rev! <REV> Exact pushed revision
# @arg machine! <DIR> Private machine inputs
# @arg host! <HOST> NixOS output
# @arg branch! <BRANCH> Pushed branch
# @arg generator! <FILE> Report generator or -
# @arg pre_erase! <FILE> Evaluated check or -
plan-build() { _machine_internal plan-build "$@"; }

# Internal SSH protocol. Exposed to argc for strict parsing, not for operators.
# @cmd Internal: prepare a reviewed transition upload (target-side)
# @arg repo! <PATH> Remote checkout
# @arg machine! <PATH> Remote machine
# @arg state! <PATH> Remote state
# @arg rev! <REV> Installed revision
# @arg sha! <SHA> Installed machine hash
prepare-transition() { _machine_internal prepare-transition "$@"; }

# @cmd Internal: apply a reviewed candidate transition (target-side)
# @arg repo! <PATH> Remote checkout
# @arg branch! <BRANCH> Reviewed branch
# @arg machine! <PATH> Remote machine
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Root-only state
# @arg reviewed! <PATH> Reviewed machine input
# @arg rev! <REV> Installed revision
# @arg sha! <SHA> Installed machine hash
apply-transition() { _machine_internal apply-transition "$@"; }

eval "$(argc --argc-eval "$0" "$@")"
