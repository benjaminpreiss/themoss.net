#!/usr/bin/env bash
# Shared deployment mechanics. Consumer owns the flake, private machine module,
# disk layout, branch policy and update cadence. Requires Bash, jq, git, Nix.
set -euo pipefail
export LC_ALL=C
umask 077
fail() { echo "themoss: $*" >&2; exit 1; }
usage() { fail 'usage: deploy.sh discover TARGET DISK RECORD | preflight RECORD | install RECORD REPO REV MACHINE_DIR HOST BRANCH | bootstrap TARGET REPO REV MACHINE_DIR REMOTE_CHECKOUT REMOTE_MACHINE REMOTE_STATE BRANCH | update REPO BRANCH MACHINE_DIR HOST STATE_DIR | transition TARGET REMOTE_CHECKOUT BRANCH REMOTE_MACHINE HOST REMOTE_STATE'; }
[[ $# -ge 1 ]] || usage
op=$1; shift

probe() {
  local target=$1
  # Verify the SSH fingerprint out of band before calling us. Never accept-new.
  local raw arch boot routes disks nic mac
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
    [[ $# == 6 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6
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
    nixos-anywhere --flake "$tmp#$host" --target-host "$(jq -r .target "$record")"
    ;;
  bootstrap)
    [[ $# == 8 ]] || usage
    target=$1 repo=$2 rev=$3 machine=$4 checkout=$5 remote_machine=$6 state=$7 branch=$8
    [[ $target == root@* && $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'bootstrap requires root SSH target'
    for path in "$checkout" "$remote_machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    [[ $rev =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'invalid installed commit'
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && ! -L $machine ]] || fail 'missing private machine.nix'
    [[ $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'machine.nix must be mode 600'
    url=$(git -C "$repo" remote get-url origin)
    [[ -n $url ]] || fail 'missing origin'
    helper=$(dirname "${BASH_SOURCE[0]}")/bootstrap-remote.sh
    remote_args=''
    for arg in "$url" "$rev" "$checkout" "$remote_machine" "$state" "$branch"; do
      printf -v quoted '%q' "$arg"
      remote_args+=" $quoted"
    done
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
    [[ $# == 6 ]] || usage
    target=$1 repo=$2 branch=$3 machine=$4 host=$5 state=$6
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ ]] || fail 'transition requires verified root SSH target'
    for path in "$repo" "$machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid branch or host'
    # Explicit non-destructive switch to the reviewed branch. The updater's
    # ancestry check rejects a rewritten main; never rebaseline implicitly.
    exec ssh -o StrictHostKeyChecking=yes "$target" "bash -s -- update $repo $branch $machine $host $state" <"${BASH_SOURCE[0]}"
    ;;
  update)
    [[ $# == 5 ]] || usage
    repo=$1 branch=$2 machine=$3 host=$4 state=$5
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ ! -L $state ]] || fail 'linked state'
    mkdir -p -m 700 "$state"
    exec 9>"$state/lock"
    flock -n 9 || fail 'update already running'
    [[ -f $state/revision && ! -L $state/revision ]] || fail 'missing known-good revision'
    current=$(<"$state/revision")
    [[ $current =~ ^[0-9a-f]{40}$ ]] || fail 'invalid known-good revision'
    git -C "$repo" fetch --no-tags origin "refs/heads/$branch"
    next=$(git -C "$repo" rev-parse FETCH_HEAD)
    git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history'
    if [[ $next == "$current" ]]; then echo "Already at $next"; exit 0; fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$next" "$machine" "$tmp"
    build "$tmp" "$host"
    nixos-rebuild switch --flake "$tmp#$host" --no-write-lock-file
    printf '%s\n' "$next" >"$state/revision.tmp"
    mv -f -- "$state/revision.tmp" "$state/revision"
    echo "UPDATE OK $current -> $next"
    ;;
  *) usage ;;
esac
