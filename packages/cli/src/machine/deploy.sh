#!/usr/bin/env bash
# Shared deployment mechanics. Consumer owns the flake, private machine module,
# disk layout, branch policy and update cadence. Requires Bash, jq, git, Nix.
#
# Operator flow: discover -> preflight -> install -> verify NEW SSH host key ->
# bootstrap -> validate host -> optionally transition to a reviewed branch.
# Only install calls nixos-anywhere. Update and transition never partition disks.
# @describe Shared deployment toolkit; only install erases a disk.
set -euo pipefail
export LC_ALL=C
umask 077
fail() { echo "themoss: $*" >&2; exit 1; }
# argc declarations below are the command contract. Keep the positional
# implementation gates below for existing pinned consumers and remote calls.
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
_legacy() {
local op=$1; shift
case $op in
  manifest)
    [[ $# == 2 ]] || usage
    task=$1 manifest=$2
    [[ $task == plan || $task == install || $task == bootstrap || $task == transition ]] || usage
    [[ -f $manifest && ! -L $manifest && $(stat -c %a "$manifest") == 600 ]] || fail 'manifest must be a mode-600 regular file (not a link)'
    [[ $(realpath -m "$manifest") == "$(realpath "$manifest")" ]] || fail 'linked manifest path'
    # Off-host state must never be committed or staged in the consumer source.
    jq -e '
      type == "object" and (.version == 1) and
      ((keys - ["version","target","disk","record","repo","revision","branch","output","machine","receipt","remoteCheckout","remoteMachine","remoteState","reportGenerator","recoveryDir","preEraseCheck","newMachine","candidateBranch"]) == []) and
      ([.target,.disk,.record,.repo,.revision,.branch,.output,.machine,.receipt,.remoteCheckout,.remoteMachine,.remoteState] | all(type == "string" and length > 0)) and
      (. as $m | ["reportGenerator","recoveryDir","preEraseCheck","newMachine","candidateBranch"] | all(. as $key | ($m | has($key) | not) or ($m[$key] | type == "string" and length > 0)))
    ' "$manifest" >/dev/null || fail 'invalid manifest schema'
    # Do not accept a tracked or unignored manifest inside the consumer checkout.
    repo=$(jq -r .repo "$manifest")
    [[ -d $repo && ! -L $repo && $(realpath -m "$repo") == "$(realpath "$repo")" ]] || fail 'invalid checkout'
    manifest_abs=$(realpath "$manifest")
    repo_abs=$(realpath "$repo")
    if [[ $manifest_abs == "$repo_abs/"* ]]; then
      relative=${manifest_abs#"$repo_abs/"}
      git -C "$repo" check-ignore -q -- "$relative" || fail 'manifest inside checkout must be Git-ignored'
      [[ -z $(git -C "$repo" ls-files -- "$relative") ]] || fail 'tracked manifest'
    fi
    target=$(jq -r .target "$manifest") disk=$(jq -r .disk "$manifest")
    record=$(jq -r .record "$manifest") rev=$(jq -r .revision "$manifest")
    branch=$(jq -r .branch "$manifest") output=$(jq -r .output "$manifest")
    machine=$(jq -r .machine "$manifest") receipt=$(jq -r .receipt "$manifest")
    checkout=$(jq -r .remoteCheckout "$manifest")
    remote_machine=$(jq -r .remoteMachine "$manifest") state=$(jq -r .remoteState "$manifest")
    generator=$(jq -r '.reportGenerator // "-"' "$manifest")
    recovery=$(jq -r '.recoveryDir // "-"' "$manifest")
    pre_erase=$(jq -r '.preEraseCheck // "-"' "$manifest")
    new_machine=$(jq -r '.newMachine // ""' "$manifest")
    candidate=$(jq -r '.candidateBranch // ""' "$manifest")
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ && $disk =~ ^/dev/[a-zA-Z0-9_./-]+$ && $disk != *..* ]] || fail 'invalid target or disk'
    [[ $rev =~ ^[0-9a-f]{40}$ && $output =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid revision or output'
    valid_ref "branch:$branch" || fail 'invalid branch'
    for path in "$record" "$machine" "$receipt"; do
      [[ $path == /* && $path != *..* ]] || fail 'private paths must be absolute without traversal'
    done
    for path in "$checkout" "$remote_machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    private_record "$record"
    [[ $target == "$(jq -r .target "$record")" && $disk == "$(jq -r .disk.path "$record")" ]] || fail 'manifest differs from discovery record'
    [[ -f $machine/machine.nix && ! -L $machine && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine.nix'
    if [[ $task == plan || $task == install ]]; then
      [[ ! -e $receipt && ! -L $receipt ]] || fail 'install receipt already exists; never reinstall to repair bootstrap'
      [[ $repo == /* && $machine == /* ]] || fail 'checkout and machine paths must be absolute'
      [[ $(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) == "$rev" ]] || fail 'revision differs from pushed branch tip'
      bash "${BASH_SOURCE[0]}" preflight "$record"
      printf 'Reviewed install plan: pushed revision=%s branch=%s output=%s\n' "$rev" "$branch" "$output"
      printf 'Paths: repo=%s machine=%s receipt=%s remote checkout=%s machine=%s state=%s\n' "$repo" "$machine" "$receipt" "$checkout" "$remote_machine" "$state"
      printf 'Consumer checks: report=%s recovery=%s pre-erase=%s\n' "$generator" "$recovery" "$pre_erase"
      [[ $task == plan ]] && exit 0
      bash "${BASH_SOURCE[0]}" install "$record" "$repo" "$rev" "$machine" "$output" "$branch" "$receipt" "$generator" "$recovery" "$pre_erase"
    else
      [[ -f $receipt && ! -L $receipt && $(stat -c %a "$receipt") == 600 ]] || fail 'missing private receipt'
      [[ $target == "$(jq -er .target "$receipt")" && $rev == "$(jq -er .revision "$receipt")" && $branch == "$(jq -er .branch "$receipt")" ]] || fail 'manifest differs from install receipt'
      [[ $(git -C "$repo" remote get-url origin) == "$(jq -er .origin "$receipt")" ]] || fail 'origin differs from install receipt'
      case $task in
        bootstrap) bash "${BASH_SOURCE[0]}" bootstrap "$receipt" "$repo" "$machine" "$checkout" "$remote_machine" "$state" ;;
        transition)
          [[ -n $new_machine && $new_machine == /* && $new_machine != *..* ]] || fail 'transition needs an absolute newMachine path'
          # The installed branch is a baseline; the requested candidate branch
          # may change, but target, revision and original machine may not.
          valid_ref "branch:$candidate" || fail 'transition needs a valid candidateBranch'
          printf 'Reviewed transition: target=%s baseline=%s candidate=%s output=%s newMachine=%s remote=%s\n' "$target" "$rev" "$candidate" "$output" "$new_machine" "$state"
          bash "${BASH_SOURCE[0]}" transition "$receipt" "$target" "$checkout" "$candidate" "$new_machine" "$remote_machine" "$output" "$state" ;;
      esac
    fi
    ;;
  plan-update)
    # Target-side planning: only an already installed, branch-tracking host.
    [[ $# == 7 ]] || usage
    repo=$1 machine=$2 host=$3 state=$4 branch=$5 expected=$6 expected_origin=$7
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ && $expected =~ ^[0-9a-f]{40}$ ]] || fail 'invalid update inputs'
    valid_ref "branch:$branch" || fail 'invalid update branch'
    [[ -n $expected_origin && $(git -C "$repo" remote get-url origin) == "$expected_origin" ]] || fail 'target Git origin changed'
    locked_state "$state"
    selector "$state"
    [[ $selected == "branch:$branch" ]] || fail 'selected branch differs; transition requires separate operator review'
    next=$(branch_tip "$repo" "$branch")
    [[ $next == "$expected" ]] || fail 'candidate differs from pushed branch tip'
    git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine input'
    sha=$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$next" "$machine" "$tmp"
    build "$tmp" "$host"
    verify_tip "$repo" "$branch" "$next"
    jq -n --arg current "$current" --arg selected "$selected" --arg next "$next" --arg sha "$sha" \
      '{current:$current,selected:$selected,next:$next,machineSha256:$sha}'
    ;;
  apply-reviewed)
    # The reviewed revision and selector are mandatory: never follow a newer
    # tip than the one shown in the plan or silently reinterpret its action.
    [[ $# == 9 ]] || usage
    repo=$1 machine=$2 host=$3 state=$4 requested=$5 expected_current=$6 expected_next=$7 expected_sha=$8 expected_origin=$9
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid target inputs'
    valid_ref "$requested" || fail 'invalid selected reference'
    [[ -n $expected_origin && $(git -C "$repo" remote get-url origin) == "$expected_origin" ]] || fail 'target Git origin changed'
    [[ $requested == branch:* && $expected_current =~ ^[0-9a-f]{40}$ && $expected_next =~ ^[0-9a-f]{40}$ && $expected_sha =~ ^[0-9a-f]{64}$ ]] || fail 'invalid reviewed update'
    locked_state "$state"
    selector "$state"
    [[ $current == "$expected_current" && $selected == "$requested" ]] || fail 'installed baseline or selector changed; make a new plan'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$expected_sha" ]] || fail 'private machine input changed'
    branch=${requested#branch:}
    next=$(branch_tip "$repo" "$branch")
    [[ $next == "$expected_next" ]] || fail 'pushed tip changed; make a new plan'
    git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
    [[ $next != "$current" ]] || { echo "Already at $current"; exit 0; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$next" "$machine" "$tmp"
    build "$tmp" "$host"
    verify_tip "$repo" "$branch" "$next"
    record_switch "$state" "$requested" "$next" "$tmp" "$host"
    echo "SWITCH OK $current -> $next ($requested)"
    ;;
  plan-build)
    # Internal non-destructive evaluated check. The operator CLI owns the
    # reviewed plan; the legacy install path repeats these gates before erase.
    [[ $# == 8 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6 generator=$7 pre_erase=$8
    [[ $host =~ ^[a-zA-Z0-9_-]+$ && $rev =~ ^[0-9a-f]{40}$ ]] || fail 'invalid output or revision'
    valid_ref "branch:$branch" || fail 'invalid branch'
    [[ -z $(git -C "$repo" status --porcelain) ]] || fail 'commit/review local changes before planning'
    [[ $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'missing pinned commit'
    verify_tip "$repo" "$branch" "$rev"
    check "$record"
    for hook in "$generator" "$pre_erase"; do
      [[ $hook == - || ( -f $hook && ! -L $hook && -x $hook ) ]] || fail 'hook must be an executable regular file'
    done
    if [[ $generator != - ]]; then
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'refusing to replace hardware report'
      report=$(mktemp "$machine/.facter.XXXXXXXX")
      rm -- "$report"
      trap 'rm -f -- "$report"' EXIT
      "$generator" "$(jq -r .target "$record")" "$report"
      [[ -f $report && ! -L $report ]] || fail 'generator did not produce a regular report'
      jq -e . "$report" >/dev/null || fail 'invalid hardware report'
      chmod 600 "$report"
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'hardware report appeared during generation'
      mv -n -- "$report" "$machine/facter.json"
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    build "$tmp" "$host"
    if [[ $pre_erase != - ]]; then "$pre_erase" "$tmp" "$host" "$record"; fi
    verify_tip "$repo" "$branch" "$rev"
    echo 'Evaluated build and consumer pre-erase check passed; review the reported target and disk before install.'
    ;;
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
    [[ $# -ge 7 && $# -le 10 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6 receipt=$7
    generator=${8:--} recovery=${9:--} pre_erase=${10:--}
    [[ $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid host output'
    for hook in "$generator" "$pre_erase"; do
      [[ $hook == - || ( -f $hook && ! -L $hook && -x $hook ) ]] || fail 'hook must be an executable regular file'
    done
    if [[ $recovery != - ]]; then
      [[ -d $recovery && ! -L $recovery ]] || fail 'missing recovery directory'
      [[ -z $(find "$recovery" -type l -print -quit) ]] || fail 'linked recovery file'
    fi
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'refusing to replace install receipt'
    [[ -d $(dirname "$receipt") && ! -L $(dirname "$receipt") ]] || fail 'invalid receipt directory'
    # A clean checkout prevents an operator from mistaking uncommitted edits
    # for the committed OS that will actually be installed.
    [[ -z $(git -C "$repo" status --porcelain) ]] || fail 'commit/review local changes before install'
    [[ $rev =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'install requires a pinned full commit'
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ $(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) == "$rev" ]] || fail 'install commit must be pushed as exact branch head'
    check "$record"
    if [[ $generator != - ]]; then
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'refusing to replace hardware report'
      # The generator is consumer-owned. It receives the verified SSH target
      # and a private output path; it must not write into the Nix store.
      report=$(mktemp "$machine/.facter.XXXXXXXX")
      rm -- "$report"
      "$generator" "$(jq -r .target "$record")" "$report"
      [[ -f $report && ! -L $report ]] || fail 'generator did not produce a regular report'
      jq -e . "$report" >/dev/null || fail 'invalid hardware report'
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'hardware report appeared during generation'
      chmod 600 "$report"
      mv -n -- "$report" "$machine/facter.json"
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    build "$tmp" "$host"
    if [[ $pre_erase != - ]]; then "$pre_erase" "$tmp" "$host" "$record"; fi
    disk=$(jq -r .disk.path "$record")
    read -r -p "Type ERASE $disk to install on $(jq -r .target "$record"): " answer || fail 'confirmation denied'
    [[ $answer == "ERASE $disk" ]] || fail 'confirmation denied'
    check "$record" # target may have changed while building
    verify_tip "$repo" "$branch" "$rev" # pushed tip may have moved during build
    # Destructive boundary: no other command below can reach this installer.
    anywhere=(--flake "$tmp#$host" --target-host "$(jq -r .target "$record")")
    if [[ $recovery != - ]]; then anywhere+=(--extra-files "$recovery"); fi
    nixos-anywhere "${anywhere[@]}"
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
  adopt)
    # Operator-supplied evidence is NOT an install receipt. Verify the running
    # system against a build of the pinned revision before touching target state.
    [[ $# == 7 ]] || usage
    evidence=$1 repo=$2 machine=$3 host=$4 checkout=$5 remote_machine=$6 state=$7
    [[ -f $evidence && ! -L $evidence && $(stat -c %a "$evidence") == 600 ]] || fail 'missing private evidence'
    [[ $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid host'
    jq -e '.verifiedBy | type == "string" and length > 0' "$evidence" >/dev/null || fail 'operator verification required'
    target=$(jq -er .target "$evidence")
    rev=$(jq -er .revision "$evidence")
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ && $rev =~ ^[0-9a-f]{40}$ ]] || fail 'invalid target or revision'
    [[ $(git -C "$repo" remote get-url origin) == "$(jq -er .origin "$evidence")" ]] || fail 'origin differs from evidence'
    [[ $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'missing verified commit'
    # Reuse bootstrap's hash and path validation, but only after comparing the
    # actual running closure with the proposed baseline. No disk call here.
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'missing private machine facts'
    [[ $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$(jq -er .machineSha256 "$evidence")" ]] || fail 'changed machine facts'
    facter_sha=$(jq -er .facterSha256 "$evidence")
    if [[ -n $facter_sha ]]; then
      [[ -f $machine/facter.json && ! -L $machine/facter.json && $(sha256sum "$machine/facter.json" | cut -d ' ' -f1) == "$facter_sha" ]] || fail 'changed hardware report'
    else
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'unexpected hardware report'
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    expected=$(nix build --no-link --no-write-lock-file --print-out-paths "$tmp#nixosConfigurations.$host.config.system.build.toplevel")
    [[ $expected == "$(jq -er .runningSystem "$evidence")" && $expected == /nix/store/* ]] || fail 'evidence does not match evaluated system'
    actual=$(ssh -o StrictHostKeyChecking=yes "$target" 'readlink -f /run/current-system')
    [[ $actual == "$expected" ]] || fail 'running system differs from verified baseline'
    bash "${BASH_SOURCE[0]}" bootstrap "$evidence" "$repo" "$machine" "$checkout" "$remote_machine" "$state"
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
}

# @cmd Create a private discovery record for one whole disk
# @arg target! <TARGET> Root SSH target
# @arg disk! <DISK> Whole /dev disk
# @arg record! <FILE> New private discovery record
discover() { _legacy discover "$@"; }

# @cmd Re-probe and compare the target with its discovery record
# @arg record! <FILE> Private discovery record
preflight() { _legacy preflight "$@"; }

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
install() { _legacy install "$@"; }

# @cmd Bootstrap the exact installed revision without erasing disks
# @arg receipt! <FILE> Off-host receipt
# @arg repo! <DIR> Consumer checkout
# @arg machine! <DIR> Original private inputs
# @arg checkout! <PATH> Remote checkout
# @arg remote_machine! <PATH> Remote machine directory
# @arg state! <PATH> Remote root-only state
bootstrap() { _legacy bootstrap "$@"; }

# @cmd Adopt a verified legacy host without reinstalling
# @arg evidence! <FILE> Operator-verified evidence
# @arg repo! <DIR> Consumer checkout
# @arg machine! <DIR> Original private inputs
# @arg host! <HOST> NixOS output
# @arg checkout! <PATH> Remote checkout
# @arg remote_machine! <PATH> Remote machine directory
# @arg state! <PATH> Remote state
adopt() { _legacy adopt "$@"; }

# @cmd Run a reviewed non-destructive candidate transition
# @arg receipt! <FILE> Install receipt
# @arg target! <TARGET> Root SSH target
# @arg checkout! <PATH> Remote checkout
# @arg branch! <BRANCH> Candidate branch
# @arg new_machine! <DIR> Reviewed private machine input
# @arg remote_machine! <PATH> Remote machine directory
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Remote state
transition() { _legacy transition "$@"; }

# @cmd Poll the root-owned selector for a new revision (target-side)
# @arg repo! <DIR> Target checkout
# @arg machine! <DIR> Target private machine input
# @arg host! <HOST> NixOS output
# @arg state! <DIR> Root-only state
poll() { _legacy poll "$@"; }

# @cmd Switch to an explicitly selected revision (target-side)
# @arg repo! <DIR> Target checkout
# @arg ref! <REF> commit:SHA or branch:NAME
# @arg machine! <DIR> Target private machine input
# @arg host! <HOST> NixOS output
# @arg state! <DIR> Root-only state
deploy() { _legacy deploy "$@"; }

# @cmd Pin an existing installed revision in root-owned state
# @arg state! <DIR> Root-only state
# @arg ref! <REF> Installed commit pin
migrate() { _legacy migrate "$@"; }

# @cmd Operate on a private off-host JSON manifest
manifest() { :; }

# @cmd Review target, whole disk and exact pushed tip without installing
# @arg file! <FILE> Mode-600 private manifest
manifest::plan() { _legacy manifest plan "$@"; }

# @cmd Build and install from a reviewed manifest; erases the selected disk
# @arg file! <FILE> Mode-600 private manifest
manifest::install() { _legacy manifest install "$@"; }

# @cmd Resume non-destructive bootstrap from a private manifest
# @arg file! <FILE> Mode-600 private manifest
manifest::bootstrap() { _legacy manifest bootstrap "$@"; }

# @cmd Apply a reviewed non-destructive transition
# @arg file! <FILE> Mode-600 private manifest
manifest::transition() { _legacy manifest transition "$@"; }

# @cmd Internal: build and check a reviewed branch update without switching
# @arg repo! <PATH> Target checkout
# @arg machine! <PATH> Target private machine inputs
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Root-only state
# @arg branch! <BRANCH> Selected branch
# @arg rev! <REV> Exact candidate tip
# @arg origin! <URL> Reviewed Git origin
plan-update() { _legacy plan-update "$@"; }

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
apply-reviewed() { _legacy apply-reviewed "$@"; }

# @cmd Internal: build and check a fresh install plan without erasing
# @arg record! <FILE> Private observed facts
# @arg repo! <DIR> Clean consumer checkout
# @arg rev! <REV> Exact pushed revision
# @arg machine! <DIR> Private machine inputs
# @arg host! <HOST> NixOS output
# @arg branch! <BRANCH> Pushed branch
# @arg generator! <FILE> Report generator or -
# @arg pre_erase! <FILE> Evaluated check or -
plan-build() { _legacy plan-build "$@"; }

# Internal SSH protocol. Exposed to argc for strict parsing, not for operators.
# @cmd Internal: prepare a reviewed transition upload (target-side)
# @arg repo! <PATH> Remote checkout
# @arg machine! <PATH> Remote machine
# @arg state! <PATH> Remote state
# @arg rev! <REV> Installed revision
# @arg sha! <SHA> Installed machine hash
prepare-transition() { _legacy prepare-transition "$@"; }

# @cmd Internal: apply a reviewed candidate transition (target-side)
# @arg repo! <PATH> Remote checkout
# @arg branch! <BRANCH> Reviewed branch
# @arg machine! <PATH> Remote machine
# @arg host! <HOST> NixOS output
# @arg state! <PATH> Root-only state
# @arg reviewed! <PATH> Reviewed machine input
# @arg rev! <REV> Installed revision
# @arg sha! <SHA> Installed machine hash
apply-transition() { _legacy apply-transition "$@"; }

eval "$(argc --argc-eval "$0" "$@")"
