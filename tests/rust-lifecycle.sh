#!/usr/bin/env bash
# Mocked end-to-end Rust CLI install, bootstrap and reviewed update. No host or disk touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cli=${MOSS_RUST_BIN:?build the Rust moss binary and set MOSS_RUST_BIN}
[[ $cli == /* && -x $cli ]] || { echo 'expected absolute executable binary' >&2; exit 1; }
tmp=$(mktemp -d "$root/packages/cli/rust/.tmp/rust-fixture.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export TMPDIR="$tmp" PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/log" MOCK_BIN="$cli" THEMOSS_TEST_ROOT=1 MOCK_PROBE="$tmp/probe"
printf '%s\n' x86_64 bios '[{"dev":"eth0"}]' '{"blockdevices":[{"path":"/dev/vda","type":"disk","size":1000,"model":"A","serial":"123"}]}' >"$MOCK_PROBE"
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/machine" "$tmp/remote" "$tmp/recovery"
printf 'recovery material (never enter Nix stage)\n' >"$tmp/recovery/secret"
cat >"$tmp/bin/generator" <<'EOF'
#!/usr/bin/env bash
[[ $1 == root@example ]] || exit 1
printf '{"hardware":"synthetic"}\n' >"$2"
EOF
cat >"$tmp/bin/checked" <<'EOF'
#!/usr/bin/env bash
[[ -f $1/generated/facter.json && $2 == test && -f $3 && ! -e $1/secret ]] || exit 1
echo 'evaluated consumer pre-erase check' >>"$MOCK_LOG"
EOF
printf 'credential-free machine\n' >"$tmp/machine/machine.nix"
chmod 600 "$tmp/machine/machine.nix"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -o && $2 == StrictHostKeyChecking=yes ]] || exit 77
shift 3
command=$*
if [[ $command == *'cat /sys/class/net/'* ]]; then echo aa:bb:cc:dd:ee:ff
elif [[ $command == 'bash -s' ]]; then
  cat >/dev/null
  cat "$MOCK_PROBE"
elif [[ $command == *'tar -xf -'* ]]; then
  [[ ${MOCK_UPLOAD_FAIL:-0} != 1 ]] || exit 79
  bash -c "$command"
elif [[ $command == *'/run/current-system/sw/bin/moss'* ]]; then
  command=${command//\/run\/current-system\/sw\/bin\/moss/$MOCK_BIN}
  bash -c "$command"
else echo "unexpected SSH: $command" >&2; exit 76; fi
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "build $*" >>"$MOCK_LOG"
[[ ${MOCK_FAIL:-} != build ]] || exit 1
EOF
cat >"$tmp/bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
echo "ERASE $*" >>"$MOCK_LOG"
EOF
cat >"$tmp/bin/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
echo "switch $*" >>"$MOCK_LOG"
[[ ${MOCK_FAIL:-} != switch ]]
EOF
chmod +x "$tmp/bin/"*
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
printf '{}\n' >"$tmp/repo/flake.lock"
printf '{ outputs = _: {}; }\n' >"$tmp/repo/flake.nix"
printf '.moss/\n' >"$tmp/repo/.gitignore"
git -C "$tmp/repo" add . && git -C "$tmp/repo" commit -qm initial
rev=$(git -C "$tmp/repo" rev-parse HEAD)
git init -q --bare "$tmp/origin.git"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
git -C "$tmp/repo" push -q origin HEAD:main
(cd "$tmp/repo" && "$cli" init)
store="$tmp/repo/.moss/root@example"
mkdir -m 700 "$store" "$store/plans"
config="$store/machine.json"
receipt="$store/install-receipt.json"
jq -n --arg repo "$tmp/repo" --arg revision "$rev" --arg machine "$tmp/machine" --arg receipt "$receipt" \
  --arg checkout "$tmp/remote/repo" --arg private "$tmp/remote/machine" --arg state "$tmp/remote/state" \
  --arg generator "$tmp/bin/generator" --arg check "$tmp/bin/checked" --arg recovery "$tmp/recovery" \
  '{version:1,repo:$repo,revision:$revision,branch:"main",output:"test",machine:$machine,receipt:$receipt,
    remoteCheckout:$checkout,remoteMachine:$private,remoteState:$state,disk:"/dev/vda",
    reportGenerator:$generator,preEraseCheck:$check,recoveryDir:$recovery}' >"$config"
chmod 600 "$config"
(cd "$tmp/repo" && "$cli" machine plan root@example --config "$config" --output "$store/plans/install.json")
[[ $(jq -r .type "$store/plans/install.json") == install ]]
! grep -q ERASE "$tmp/log"
jq '.observed.disk.size = 999' "$store/plans/install.json" >"$store/plans/changed-disk.json"
chmod 600 "$store/plans/changed-disk.json"
(cd "$tmp/repo" && printf 'ERASE /dev/vda\n' | "$cli" machine apply --plan "$store/plans/changed-disk.json") && exit 1
[[ ! -e $receipt ]] && ! grep -q ERASE "$tmp/log"
chmod 644 "$store/plans/install.json"
(cd "$tmp/repo" && "$cli" machine apply --plan "$store/plans/install.json" </dev/null) && exit 1
chmod 600 "$store/plans/install.json"
(cd "$tmp/repo" && MOCK_FAIL=build printf 'ERASE /dev/vda\n' | MOCK_FAIL=build "$cli" machine apply --plan "$store/plans/install.json") && exit 1
[[ ! -e $receipt ]] && ! grep -q ERASE "$tmp/log"
(cd "$tmp/repo" && printf 'NO\n' | "$cli" machine apply --plan "$store/plans/install.json") && { echo 'confirmation bypass' >&2; exit 1; }
[[ ! -e $receipt ]] && ! grep -q ERASE "$tmp/log"
(cd "$tmp/repo" && printf 'ERASE /dev/vda\n' | "$cli" machine apply --plan "$store/plans/install.json")
[[ $(jq -r .revision "$receipt") == "$rev" && $(grep -c ERASE "$tmp/log") == 1 ]]
[[ $(jq -r .facterSha256 "$receipt") == "$(sha256sum "$tmp/machine/facter.json" | cut -d ' ' -f1)" ]]
grep -q -- '--extra-files' "$tmp/log"
grep -q -- 'evaluated consumer pre-erase check' "$tmp/log"
(cd "$tmp/repo" && MOCK_UPLOAD_FAIL=1 "$cli" machine bootstrap "$receipt") && exit 1
[[ ! -e $tmp/remote/state/revision ]]
(cd "$tmp/repo" && "$cli" machine bootstrap "$receipt")
[[ $(<"$tmp/remote/state/revision") == "$rev" && $(<"$tmp/remote/state/selector") == "commit:$rev" ]]
(cd "$tmp/repo" && "$cli" machine bootstrap "$receipt")
# Branch tracking is a separately reviewed root-owned decision.
printf 'update\n' >>"$tmp/repo/flake.nix"
git -C "$tmp/repo" add . && git -C "$tmp/repo" commit -qm update
git -C "$tmp/repo" push -q origin HEAD:main
next=$(git -C "$tmp/repo" rev-parse HEAD)
jq --arg rev "$next" '.revision=$rev | del(.disk)' "$config" >"$tmp/config-next"
chmod 600 "$tmp/config-next"
cp "$tmp/config-next" "$config"
(cd "$tmp/repo" && "$cli" machine plan root@example --config "$config" --output "$store/plans/premature.json") && exit 1
[[ ! -e $store/plans/premature.json ]]
printf 'branch:main\n' >"$tmp/remote/state/selector"
chmod 600 "$tmp/remote/state/selector"
(cd "$tmp/repo" && "$cli" machine plan root@example --config "$config" --output "$store/plans/update.json")
[[ $(jq -r .type "$store/plans/update.json") == update ]]
(cd "$tmp/repo" && MOCK_FAIL=switch "$cli" machine apply --plan "$store/plans/update.json") && exit 1
[[ $(<"$tmp/remote/state/revision") == "$rev" && -f $tmp/remote/state/needs-inspection ]]
(cd "$tmp/repo" && "$cli" machine apply --plan "$store/plans/update.json") && exit 1
[[ $(grep -c ERASE "$tmp/log") == 1 && $(grep -c switch "$tmp/log") == 1 ]]
# Simulated operator reconciliation after inspection of running system/generations.
rm "$tmp/remote/state/needs-inspection"
(cd "$tmp/repo" && "$cli" machine apply --plan "$store/plans/update.json")
[[ $(<"$tmp/remote/state/revision") == "$next" && $(grep -c ERASE "$tmp/log") == 1 && $(grep -c switch "$tmp/log") == 2 ]]
# Guided first-use setup and latest-plan selection are also Rust behavior.
printf '%s\n' '' '' main test "$tmp/machine" '' "$tmp/remote/other/repo" "$tmp/remote/other/machine" "$tmp/remote/other/state" '' '' '' y | \
  (cd "$tmp/repo" && MOSS_TEST_INPUT=1 "$cli" machine plan root@other)
other="$tmp/repo/.moss/root@other"
[[ $(stat -c %a "$other/machine.json") == 600 && -L $other/latest ]]
[[ $(jq -r .type "$(readlink -- "$other/latest")") == install ]]
mv "$other/latest" "$other/latest.saved"
ln -s /dev/null "$other/latest"
(cd "$tmp/repo" && "$cli" machine apply --target root@other </dev/null) && exit 1
rm "$other/latest"; mv "$other/latest.saved" "$other/latest"
(cd "$tmp/repo" && printf 'NO\n' | "$cli" machine apply --target root@other) && exit 1
[[ $(grep -c ERASE "$tmp/log") == 1 ]]
(cd "$tmp/repo" && printf 'ERASE /dev/vda\n' | "$cli" machine apply --target root@other)
(cd "$tmp/repo" && "$cli" machine bootstrap "$other/install-receipt.json")
# An explicitly reviewed transition may replace a prior baseline, unlike
# automatic branch polling. It still builds before switch and never erases.
git -C "$tmp/repo" branch candidate "$rev"
git -C "$tmp/repo" push -q origin candidate
mkdir -m 700 "$tmp/new-machine"
printf 'reviewed replacement\n' >"$tmp/new-machine/machine.nix"
chmod 600 "$tmp/new-machine/machine.nix"
(cd "$tmp/repo" && "$cli" internal transition "$other/install-receipt.json" root@other \
  "$tmp/remote/other/repo" candidate "$tmp/new-machine" "$tmp/remote/other/machine" test "$tmp/remote/other/state")
[[ $(<"$tmp/remote/other/state/revision") == "$rev" && $(<"$tmp/remote/other/state/selector") == 'branch:candidate' ]]
[[ $(<"$tmp/remote/other/machine/machine.nix") == 'reviewed replacement' && $(grep -c ERASE "$tmp/log") == 2 ]]
# Ambiguous disk inventory requires a numbered choice, never a default.
printf '%s\n' x86_64 bios '[{"dev":"eth0"}]' \
  '{"blockdevices":[{"path":"/dev/vda","type":"disk","size":1000,"model":"A","serial":"123"},{"path":"/dev/vdb","type":"disk","size":2000,"model":"B","serial":"456"}]}' >"$MOCK_PROBE"
printf '%s\n' '' '' main test "$tmp/machine" '' '' '' '' '' '' '' 0 | \
  (cd "$tmp/repo" && MOSS_TEST_INPUT=1 "$cli" machine plan root@no-choice) && exit 1
[[ ! -e $tmp/repo/.moss/root@no-choice/machine.json ]]
printf '%s\n' '' '' main test "$tmp/machine" '' '' '' '' '' '' '' 2 y | \
  (cd "$tmp/repo" && MOSS_TEST_INPUT=1 "$cli" machine plan root@multiple)
[[ $(jq -r .disk "$tmp/repo/.moss/root@multiple/machine.json") == /dev/vdb ]]
[[ $(grep -c ERASE "$tmp/log") == 2 ]]
printf 'poll candidate\n' >>"$tmp/repo/flake.nix"
git -C "$tmp/repo" add . && git -C "$tmp/repo" commit -qm poll
git -C "$tmp/repo" push -q origin HEAD:main
poll_next=$(git -C "$tmp/repo" rev-parse HEAD)
"$cli" internal poll "$tmp/remote/repo" "$tmp/remote/machine" test "$tmp/remote/state"
[[ $(<"$tmp/remote/state/revision") == "$poll_next" && $(grep -c ERASE "$tmp/log") == 2 ]]
echo 'Rust lifecycle fixture passed (mocked target, disk and Nix)'
