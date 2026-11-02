#!/usr/bin/env bash
# Shared deployment mechanics. Consumer owns the flake, private machine module,
# disk layout, branch policy and update cadence. Requires Bash, jq, git, Nix.
#
# Operator flow: discover -> preflight -> install -> verify NEW SSH host key ->
# bootstrap -> validate host -> optionally transition to a reviewed branch.
# Only install calls nixos-anywhere. Update and transition never partition disks.
set -euo pipefail
export LC_ALL=C
umask 077
fail() { echo "themoss: $*" >&2; exit 1; }
usage() { fail 'usage: deploy.sh discover TARGET DISK RECORD | preflight RECORD | install RECORD REPO REV MACHINE_DIR HOST BRANCH RECEIPT | bootstrap RECEIPT REPO MACHINE_DIR REMOTE_CHECKOUT REMOTE_MACHINE REMOTE_STATE | poll REPO MACHINE_DIR HOST STATE_DIR | deploy REPO REF MACHINE_DIR HOST STATE_DIR | transition RECEIPT TARGET REMOTE_CHECKOUT BRANCH NEW_MACHINE_DIR REMOTE_MACHINE HOST REMOTE_STATE | migrate STATE_DIR REF'; }
[[ $# -ge 1 ]] || usage
op=$1; shift

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
  [[ -f $1/selector && ! -L $1/selector && $(stat -c %a "$1/selector") == 600 ]] || fail 'missing root-only selector; migrate explicitly'
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
case $op in
  discover)
    [[ $# == 3 ]] || usage
    target=$1 disk=$2 record=$3
    [[ $disk == /dev/* ]] || fail 'expected a whole /dev disk'
    [[ ! -e $record && ! -L $record ]] || fail 'refusing to replace record'
    actual=$(probe "$target")
    selected=$(jq -ec --arg disk "$disk" '[.disks[] | select(.path == $disk and .type == "disk")] | if length == 1 then .[0] else error("disk not unique whole disk") end' <<<"$actual")
    jq -n --arg target "$target" --argjson p "$actual" --argjson disk "$selected" '{target:$target,arch:$p.arch,boot:$p.boot,nic:$p.nic,mac:$p.mac,disk:$disk}' >"$record"
    echo "Private machine record created: $record (verify with provider console)"
    ;;
  preflight)
    [[ $# == 1 ]] || usage
    check "$1"
    ;;
  install)
    [[ $# == 7 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6 receipt=$7
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'refusing to replace install receipt'
    [[ -d $(dirname "$receipt") && ! -L $(dirname "$receipt") ]] || fail 'invalid receipt directory'
    # A clean checkout prevents an operator from mistaking uncommitted edits
    # for the committed OS that will actually be installed.
    [[ -z $(git -C "$repo" status --porcelain) ]] || fail 'commit/review local changes before install'
    [[ $rev =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'install requires a pinned full commit'
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ $(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) == "$rev" ]] || fail 'install commit must be pushed as exact branch head'
    check "$record"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    build "$tmp" "$host"
    disk=$(jq -r .disk.path "$record")
    read -r -p "Type ERASE $disk to install on $(jq -r .target "$record"): " answer || fail 'confirmation denied'
    [[ $answer == "ERASE $disk" ]] || fail 'confirmation denied'
    check "$record" # target may have changed while building
    verify_tip "$repo" "$branch" "$rev" # pushed tip may have moved during build
    # Destructive boundary: no other command below can reach this installer.
    nixos-anywhere --flake "$tmp#$host" --target-host "$(jq -r .target "$record")"
    # Only a successful installer can produce the off-host install receipt.
    # Keep it separate from the Nix store; private files must still be secret-free.
    url=$(git -C "$repo" remote get-url origin)
    sha=$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)
    facter_sha=''
    if [[ -f $machine/facter.json ]]; then facter_sha=$(sha256sum "$machine/facter.json" | cut -d ' ' -f1); fi
    jq -n --arg target "$(jq -r .target "$record")" --arg rev "$rev" --arg branch "$branch" --arg url "$url" --arg sha "$sha" --arg facter "$facter_sha" \
      '{target:$target,revision:$rev,branch:$branch,origin:$url,machineSha256:$sha,facterSha256:$facter}' >"$receipt.tmp"
    chmod 600 "$receipt.tmp"
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'receipt appeared during install'
    mv -n -- "$receipt.tmp" "$receipt"
    echo "Install receipt: $receipt (back up off-host; do not reinstall to repair bootstrap)"
    ;;
  bootstrap)
    [[ $# == 6 ]] || usage
    receipt=$1 repo=$2 machine=$3 checkout=$4 remote_machine=$5 state=$6
    [[ -f $receipt && ! -L $receipt && $(stat -c %a "$receipt") == 600 ]] || fail 'missing or unsafe install receipt'
    # The receipt is the off-host handoff from install. It binds the target,
    # origin and private inputs to the commit actually passed to the installer.
    target=$(jq -er .target "$receipt")
    rev=$(jq -er .revision "$receipt")
    branch=$(jq -er .branch "$receipt")
    expected_url=$(jq -er .origin "$receipt")
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'bootstrap requires root SSH target'
    for path in "$checkout" "$remote_machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    [[ $rev =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'invalid installed commit'
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && ! -L $machine ]] || fail 'missing private machine.nix'
    [[ $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'machine.nix must be mode 600'
    [[ $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$(jq -er .machineSha256 "$receipt")" ]] || fail 'machine.nix differs from installed input'
    facter_sha=$(jq -er .facterSha256 "$receipt")
    if [[ -n $facter_sha ]]; then
      [[ -f $machine/facter.json && ! -L $machine/facter.json && $(sha256sum "$machine/facter.json" | cut -d ' ' -f1) == "$facter_sha" ]] || fail 'facter report differs from installed input'
    else
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'unexpected facter report'
    fi
    url=$(git -C "$repo" remote get-url origin)
    [[ -n $url && $url == "$expected_url" ]] || fail 'origin differs from install receipt'
    helper=$(dirname "${BASH_SOURCE[0]}")/bootstrap-remote.sh
    remote_args=''
    for arg in "$url" "$rev" "$checkout" "$remote_machine" "$state" "$branch"; do
      printf -v quoted '%q' "$arg"
      remote_args+=" $quoted"
    done
    # Prepare and finish share a root-only incoming directory. Upload happens
    # between them, so a dropped connection leaves a retryable partial upload.
    ssh -o StrictHostKeyChecking=yes "$target" "bash -s -- prepare$remote_args" <"$helper"
    files=(machine.nix)
    if [[ -e $machine/facter.json || -L $machine/facter.json ]]; then
      [[ -f $machine/facter.json && ! -L $machine/facter.json ]] || fail 'invalid facter report'
      files+=(facter.json)
    fi
    tar -C "$machine" -cf - "${files[@]}" | ssh -o StrictHostKeyChecking=yes "$target" "tar -xf - -C $state/incoming --no-same-owner"
    ssh -o StrictHostKeyChecking=yes "$target" "bash -s -- finish$remote_args" <"$helper"
    ;;
  transition)
    [[ $# == 8 ]] || usage
    receipt=$1 target=$2 repo=$3 branch=$4 new_machine=$5 machine=$6 host=$7 state=$8
    [[ -f $receipt && ! -L $receipt && $(stat -c %a "$receipt") == 600 ]] || fail 'missing install receipt'
    [[ $target == "$(jq -er .target "$receipt")" && $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'target differs from receipt'
    for path in "$repo" "$machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid branch or host'
    [[ -f $new_machine/machine.nix && ! -L $new_machine/machine.nix && $(stat -c %a "$new_machine/machine.nix") == 600 ]] || fail 'missing reviewed machine.nix'
    rev=$(jq -er .revision "$receipt")
    sha=$(jq -er .machineSha256 "$receipt")
    [[ $rev =~ ^[0-9a-f]{40}$ && $sha =~ ^[0-9a-f]{64}$ ]] || fail 'invalid receipt'
    # Send the new consumer-owned machine file as a proposal, not live state.
    # The target has no toolkit checkout: transmit the same update implementation.
    ssh -o StrictHostKeyChecking=yes "$target" "bash -s -- prepare-transition $repo $machine $state $rev $sha" <"${BASH_SOURCE[0]}"
    tar -C "$new_machine" -cf - machine.nix | ssh -o StrictHostKeyChecking=yes "$target" "tar -xf - -C $state/transition-incoming --no-same-owner"
    ssh -o StrictHostKeyChecking=yes "$target" "bash -s -- apply-transition $repo $branch $machine $host $state $state/transition-incoming/machine.nix $rev $sha" <"${BASH_SOURCE[0]}"
    ;;
  prepare-transition)
    # Target-side gate before uploading a reviewed private file. If state or
    # current facts have drifted since install, require operator inspection.
    [[ $# == 5 ]] || usage
    repo=$1 machine=$2 state=$3 rev=$4 sha=$5
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && -d $state && ! -L $state ]] || fail 'missing target checkout/private state'
    [[ $rev =~ ^[0-9a-f]{40}$ && $sha =~ ^[0-9a-f]{64}$ ]] || fail 'invalid receipt'
    locked_state "$state"
    selector "$state"
    [[ $current == "$rev" ]] || fail 'baseline no longer installed'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$sha" ]] || fail 'machine facts differ from installed input'
    [[ ! -L $state/transition-incoming ]] || fail 'linked upload directory'
    mkdir -p -m 700 "$state/transition-incoming"
    rm -f -- "$state/transition-incoming/machine.nix"
    ;;
  migrate)
    [[ $# == 2 ]] || usage
    state=$1 ref=$2
    locked_state "$state"
    [[ ! -e $state/selector && ! -L $state/selector ]] || fail 'selector already exists'
    valid_ref "$ref" || fail 'invalid selector'
    # Migration cannot assert an unverified branch baseline. Start pinned;
    # use a reviewed transition to authorize branch tracking.
    [[ $ref == "commit:$current" ]] || fail 'migrate only to installed commit pin'
    printf '%s\n' "$ref" >"$state/selector"
    chmod 600 "$state/selector"
    ;;
  poll | deploy | apply-transition)
    if [[ $op == poll ]]; then [[ $# == 4 ]] || usage
    elif [[ $op == deploy ]]; then [[ $# == 5 ]] || usage
    else [[ $# == 8 ]] || usage; fi
    repo=$1; shift
    requested=''
    if [[ $op == deploy ]]; then requested=$1; shift; fi
    if [[ $op == apply-transition ]]; then branch=$1; shift; fi
    machine=$1 host=$2 state=$3; shift 3
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid target inputs'
    locked_state "$state"
    selector "$state"
    reviewed=''
    if [[ $op == poll ]]; then
      [[ $selected == branch:* ]] || exit 0
      requested=$selected
    elif [[ $op == apply-transition ]]; then
      reviewed=$1; expected_rev=$2; expected_sha=$3
      requested="branch:$branch"
      valid_ref "$requested" || fail 'invalid branch'
      [[ $expected_rev == "$current" && $expected_sha =~ ^[0-9a-f]{64}$ && $reviewed == "$state/transition-incoming/machine.nix" ]] || fail 'invalid transition baseline'
      [[ -f $reviewed && ! -L $reviewed && -f $machine/machine.nix && ! -L $machine/machine.nix ]] || fail 'missing reviewed/current machine facts'
      [[ $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$expected_sha" ]] || fail 'machine facts changed since install'
      [[ ! -L $state/transition-incoming && $(stat -c %a "$state/transition-incoming") == 700 ]] || fail 'unsafe reviewed upload'
      echo 'Reviewed transition: explicitly replacing prior baseline (squash/rebase allowed)' >&2
    else
      valid_ref "$requested" || fail 'invalid reference'
    fi
    if [[ $requested == branch:* ]]; then
      branch=${requested#branch:}
      next=$(branch_tip "$repo" "$branch")
      if [[ $op != apply-transition ]]; then
        git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
      fi
      [[ $next != "$current" || $requested != "$selected" || -n $reviewed ]] || { echo "Already at $next"; exit 0; }
    else
      next=${requested#commit:}
      [[ $(git -C "$repo" cat-file -t "$next") == commit ]] || fail 'commit missing locally'
      [[ $next == "$current" || $selected == "commit:$current" ]] || fail 'new baseline requires reviewed transition'
      [[ $next == "$current" && $selected == "$requested" ]] && exit 0
      if [[ $next != "$current" ]]; then echo 'WARNING: pinning an unmerged commit; a later reviewed branch transition can replace it' >&2; fi
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage_machine=$machine
    if [[ -n $reviewed ]]; then
      mkdir -m 700 "$tmp/private"
      cp -- "$reviewed" "$tmp/private/machine.nix"
      if [[ -f $machine/facter.json && ! -L $machine/facter.json ]]; then cp -- "$machine/facter.json" "$tmp/private/facter.json"; fi
      stage_machine=$tmp/private
    fi
    mkdir -m 700 "$tmp/source"
    stage "$repo" "$next" "$stage_machine" "$tmp/source"
    build "$tmp/source" "$host"
    if [[ $requested == branch:* ]]; then verify_tip "$repo" "$branch" "$next"; fi
    record_switch "$state" "$requested" "$next" "$tmp/source" "$host" "$reviewed" "$machine"
    [[ -z $reviewed ]] || rm -rf -- "$state/transition-incoming"
    echo "SWITCH OK $current -> $next ($requested)"
    ;;
  *) usage ;;
esac
