#!/usr/bin/env bash
# Run only over SSH with StrictHostKeyChecking=yes, as root. Never install disks.
# Called twice: prepare clears an interrupted upload; finish verifies and
# commits it. The receipt's revision must be the initial known-good revision.
set -euo pipefail
umask 077
fail() { echo "themoss bootstrap: $*" >&2; exit 1; }
[[ $# == 7 ]] || fail 'usage: phase repository-url revision checkout machine state branch'
phase=$1 url=$2 rev=$3 repo=$4 machine=$5 state=$6 branch=$7
[[ $rev =~ ^[0-9a-f]{40}$ && $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid revision or branch'
for path in "$repo" "$machine" "$state"; do
  [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* && ! -L $path ]] || fail 'unsafe path'
done
[[ $repo != "$state"* && $machine != "$state"* && $repo != "$machine"* && $machine != "$repo"* ]] || fail 'overlapping paths'
[[ $url != -* && $url != *$'\n'* ]] || fail 'invalid origin'
[[ $(id -u) == 0 || ${THEMOSS_TEST_ROOT:-} == 1 ]] || fail 'root required'
mkdir -p -m 700 "$state"
[[ $(stat -c %a "$state") == 700 ]] || fail 'state must be mode 700'
exec 9>"$state/bootstrap.lock"
flock -n 9 || fail 'bootstrap already running'
[[ ! -L $state/revision && ! -L $state/incoming ]] || fail 'linked state'
# Re-running bootstrap may finish an interrupted attempt, but never replace a
# different known-good revision or an unrelated source checkout.
if [[ -e $state/revision ]]; then
  [[ -f $state/revision && $(<"$state/revision") == "$rev" ]] || fail 'different known-good revision'
fi
if [[ -e $repo ]]; then
  [[ -d $repo && -d $repo/.git && ! -L $repo/.git ]] || fail 'unrelated checkout'
  [[ $(git -C "$repo" remote get-url origin) == "$url" && $(git -C "$repo" rev-parse HEAD) == "$rev" ]] || fail 'checkout does not match installed commit/origin'
fi
# The incoming directory is disposable. The live machine files are not.
if [[ $phase == prepare ]]; then
  mkdir -p -m 700 "$state/incoming"
  # A previous interrupted upload is disposable; already committed files are not.
  rm -f -- "$state/incoming/machine.nix" "$state/incoming/facter.json"
  exit 0
fi
[[ $phase == finish ]] || fail 'unknown phase'
[[ -f $state/incoming/machine.nix && ! -L $state/incoming/machine.nix ]] || fail 'missing machine.nix upload'
for name in machine.nix facter.json; do
  src="$state/incoming/$name"
  if [[ ! -e $src ]]; then
    [[ ! -e $machine/$name && ! -L $machine/$name ]] || fail "unexpected existing $name"
    continue
  fi
  [[ -f $src && ! -L $src ]] || fail 'invalid uploaded file'
  if [[ -e $machine/$name || -L $machine/$name ]]; then
    [[ -f $machine/$name && ! -L $machine/$name ]] && cmp -s "$src" "$machine/$name" || fail "different existing $name"
  fi
done
# Fetch before changing any durable state. A branch may advance after install;
# the installed commit must still be in its ancestry. Checkout the receipt's
# commit, not the latest branch head (which may enable updates too early).
if [[ ! -e $repo ]]; then
  rm -rf -- "$state/checkout.tmp"
  git clone --no-checkout --single-branch --branch "$branch" -- "$url" "$state/checkout.tmp"
  git -C "$state/checkout.tmp" merge-base --is-ancestor "$rev" "origin/$branch" || fail 'installed commit not on fetched branch'
  git -C "$state/checkout.tmp" checkout --detach "$rev"
  chmod 700 "$state/checkout.tmp"
  mkdir -p "$(dirname "$repo")"
  [[ ! -e $repo && ! -L $repo ]] || fail 'checkout appeared during bootstrap'
  mv -- "$state/checkout.tmp" "$repo"
fi
mkdir -p -m 700 "$machine"
[[ $(stat -c %a "$machine") == 700 ]] || fail 'private machine directory must be mode 700'
for name in machine.nix facter.json; do
  [[ -f $state/incoming/$name ]] || continue
  if [[ ! -e $machine/$name ]]; then
    cp -- "$state/incoming/$name" "$machine/$name.tmp"
    chmod 600 "$machine/$name.tmp"
    mv -n -- "$machine/$name.tmp" "$machine/$name"
  fi
done
# Timer authorization belongs to the consumer's NixOS configuration. Commit
# the revision last so a failed upload or clone cannot appear bootstrapped. Interrupted attempts can be retried with identical inputs.
printf '%s\n' "$rev" >"$state/revision.tmp"
chmod 600 "$state/revision.tmp"
mv -- "$state/revision.tmp" "$state/revision"
rm -rf -- "$state/incoming"
printf 'Bootstrapped installed revision %s; timer policy unchanged\n' "$rev"
