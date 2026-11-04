#!/usr/bin/env bash
# Toolkit fixture entry point: CI (.github/workflows/ci.yml) runs this from
# the repo root; developers can run `bash tests/test.sh` locally. It mocks
# SSH/Nix/installer commands, uses local Git, and calls tests/audit.sh.
# No real target, GitHub credentials, or destructive operation is used.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.test-tmp.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
mkdir -p "$tmp/bin" "$tmp/machine" "$tmp/state" "$tmp/repo"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/log" MOCK_PROBE="$tmp/probe" MOCK_FAIL='' MOCK_DIVERGE=''
printf 'candidate\n' >"$tmp/machine/machine.nix"
chmod 600 "$tmp/machine/machine.nix"
export THEMOSS_TEST_ROOT=1
printf '%s\n' x86_64 >"$tmp/probe"
printf '%s\n' bios >>"$tmp/probe"
printf '%s\n' '[{"dev":"eth0"}]' >>"$tmp/probe"
printf '%s\n' '{"blockdevices":[{"path":"/dev/vda","type":"disk","size":1000,"model":"A","serial":"123"}]}' >>"$tmp/probe"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -o && $2 == StrictHostKeyChecking=yes ]] || exit 77
[[ ${MOCK_HOST_VERIFIED:-1} == 1 ]] || exit 78
shift 2
shift # target
if [[ $* == *'cat /sys/class/net/'* ]]; then echo aa:bb:cc:dd:ee:ff
elif [[ $* == tar\ -xf* && ${MOCK_UPLOAD_FAIL:-0} == 1 ]]; then exit 79
elif [[ $* == 'readlink -f /run/current-system' ]]; then echo "${MOCK_RUNNING_SYSTEM:-/nix/store/synthetic-baseline}"
elif [[ $* == bash\ -s\ --* || $* == tar\ -xf* ]]; then bash -c "$*"
else cat "$MOCK_PROBE"; fi
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$MOCK_LOG"
if [[ ${MOCK_TIP_MOVE:-0} == 1 ]]; then
  git -C "$MOCK_SOURCE" commit --allow-empty -qm 'tip moved during build'
  git -C "$MOCK_SOURCE" push -q origin HEAD:main
fi
[[ $MOCK_FAIL != build ]] || exit 1
if [[ $* == *--print-out-paths* ]]; then echo /nix/store/synthetic-baseline; fi
EOF
cat >"$tmp/bin/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
echo "switch $*" >>"$MOCK_LOG"
[[ ${MOCK_SWITCH_FAIL:-0} != 1 ]]
EOF
cat >"$tmp/bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
echo "ERASE $*" >>"$MOCK_LOG"
EOF
chmod +x "$tmp/bin/"*
cli="$root/packages/cli/bin/machine/deploy.sh"
bash "$cli" discover root@example /dev/vda "$tmp/record"
bash "$cli" preflight "$tmp/record"
for key in arch boot nic mac disk; do
  jq --arg key "$key" 'if $key == "disk" then .disk.size = 999 else .[$key] = "wrong" end' "$tmp/record" >"$tmp/changed"
  chmod 600 "$tmp/changed"
  if bash "$cli" preflight "$tmp/changed" >/dev/null 2>&1; then echo "accepted mismatched $key" >&2; exit 1; fi
done
[[ ! -e $tmp/log ]] || { echo 'preflight made destructive call' >&2; exit 1; }
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
printf '{}\n' >"$tmp/repo/flake.lock"
printf '{ outputs = _: { }; }\n' >"$tmp/repo/flake.nix"
git -C "$tmp/repo" add .; git -C "$tmp/repo" commit -qm initial
first=$(git -C "$tmp/repo" rev-parse HEAD)
# local bare origin gives real fetch/ancestry behavior, with no network.
git init -q --bare "$tmp/origin.git"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
receipt="$tmp/install-receipt.json"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" >/dev/null 2>&1 && exit 1
git -C "$tmp/repo" push -q origin HEAD:main
# Exercise the interactive authoring flow through a synthetic terminal when available.
printf '%s\n\n/dev/vda\n%s\n\nmain\ntest\n%s\n\n\n\n\n\n\n\n' "$tmp/record" "$tmp/repo" "$tmp/machine" | \
  THEMOSS_TEST_INPUT=1 bash "$root/packages/cli/bin/machine/new-operator-manifest.sh" "$tmp/authored.json" >/dev/null
[[ $(stat -c %a "$tmp/authored.json") == 600 ]]
jq -e --arg rev "$first" '.disk == "/dev/vda" and .revision == $rev and .output == "test"' "$tmp/authored.json" >/dev/null
bash "$cli" manifest plan "$tmp/authored.json" >/dev/null
! bash "$root/packages/cli/bin/machine/new-operator-manifest.sh" "$tmp/authored.json" </dev/null >/dev/null 2>&1
# Two synthetic consumer policies share the manifest schema, not application fields.
for consumer in relay agentic; do
  manifest="$tmp/$consumer.json"
  jq -n --arg target root@example --arg disk /dev/vda --arg record "$tmp/record" \
    --arg repo "$tmp/repo" --arg revision "$first" --arg machine "$tmp/machine" \
    --arg receipt "$tmp/$consumer-receipt" --arg base "$tmp/$consumer-remote" \
    '{version:1,target:$target,disk:$disk,record:$record,repo:$repo,revision:$revision,
      branch:"main",output:"test",machine:$machine,receipt:$receipt,
      remoteCheckout:($base+"/repo"),remoteMachine:($base+"/machine"),remoteState:($base+"/state")}' >"$manifest"
  chmod 600 "$manifest"
  bash "$cli" manifest plan "$manifest" | grep -q 'pushed revision='
  jq '.disk = "/dev/sda"' "$manifest" >"$tmp/bad.json"; chmod 600 "$tmp/bad.json"
  ! bash "$cli" manifest install "$tmp/bad.json" </dev/null >/dev/null 2>&1
  jq '.target = "root@other"' "$manifest" >"$tmp/bad.json"
  ! bash "$cli" manifest install "$tmp/bad.json" </dev/null >/dev/null 2>&1
  jq '.remoteState = "/tmp/../oops"' "$manifest" >"$tmp/bad.json"
  ! bash "$cli" manifest install "$tmp/bad.json" </dev/null >/dev/null 2>&1
  printf 'no\n' | bash "$cli" manifest install "$manifest" >/dev/null 2>&1 && exit 1
  printf 'ERASE /dev/vda\n' | bash "$cli" manifest install "$manifest"
  export MOCK_UPLOAD_FAIL=1
  ! bash "$cli" manifest bootstrap "$manifest" >/dev/null 2>&1
  [[ ! -e $tmp/$consumer-remote/state/revision ]]
  export MOCK_UPLOAD_FAIL=0
  bash "$cli" manifest bootstrap "$manifest"
  bash "$cli" manifest bootstrap "$manifest"
  jq '.target = "root@other"' "$manifest" >"$tmp/bad.json"
  ! bash "$cli" manifest bootstrap "$tmp/bad.json" >/dev/null 2>&1
done
printf 'no\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" > /dev/null 2>&1 && { echo 'confirmation bypass' >&2; exit 1; }
[[ ! -e $receipt ]]
! grep -q ERASE "$tmp/log"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt"
[[ $(jq -r .revision "$receipt") == "$first" && $(stat -c %a "$receipt") == 600 ]]
if printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" >/dev/null 2>&1; then echo 'replaced receipt' >&2; exit 1; fi
[[ $(grep -c ERASE "$tmp/log") == 3 ]]
# Consumer-owned report generator, pre-erase evaluated check and separate
# recovery tree. No recovery material may enter the staged Nix flake.
mkdir "$tmp/generated" "$tmp/recovery"
printf 'private key\n' >"$tmp/recovery/secret"
cat >"$tmp/generator" <<'EOF'
#!/usr/bin/env bash
[[ $1 == root@example ]] || exit 1
printf '{"hardware":"synthetic"}\n' >"$2"
EOF
cat >"$tmp/check" <<'EOF'
#!/usr/bin/env bash
[[ -f $1/generated/facter.json && $2 == test && -f $3 ]] || exit 1
[[ ! -e $1/secret ]] || exit 1
printf 'evaluated %s\n' "$1" >>"$MOCK_LOG"
EOF
chmod +x "$tmp/generator" "$tmp/check"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/empty" test main "$tmp/report-receipt" "$tmp/generator" "$tmp/recovery" "$tmp/check" >/dev/null 2>&1 && exit 1 # missing machine facts
cp "$tmp/machine/machine.nix" "$tmp/generated/machine.nix"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/generated" test main "$tmp/report-receipt" "$tmp/generator" "$tmp/recovery" "$tmp/check"
[[ $(jq -r .facterSha256 "$tmp/report-receipt") == "$(sha256sum "$tmp/generated/facter.json" | cut -d ' ' -f1)" ]]
grep -q -- '--extra-files' "$tmp/log"
if printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/generated" test main "$tmp/report-receipt2" "$tmp/generator" >/dev/null 2>&1; then echo 'overwrote report' >&2; exit 1; fi
[[ $(grep -c ERASE "$tmp/log") == 4 ]]
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/reject-check"; chmod +x "$tmp/reject-check"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/generated" test main "$tmp/rejected-receipt" - - "$tmp/reject-check" >/dev/null 2>&1 && { echo 'pre-erase validation bypassed' >&2; exit 1; }
[[ $(grep -c ERASE "$tmp/log") == 4 && ! -e $tmp/rejected-receipt ]]
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "unexpected timer call $*" >>"$MOCK_LOG"
exit 86 # candidate has no updater timer unit
EOF
chmod +x "$tmp/bin/systemctl"
bootstrap() { bash "$cli" bootstrap "$receipt" "$tmp/repo" "$tmp/machine" "$tmp/remote/repo" "$tmp/remote/machine" "$tmp/remote/state"; }
export MOCK_HOST_VERIFIED=0
if bootstrap >/dev/null 2>&1; then echo 'accepted unverified host key' >&2; exit 1; fi
export MOCK_HOST_VERIFIED=1 MOCK_UPLOAD_FAIL=1
if bootstrap >/dev/null 2>&1; then echo 'accepted incomplete upload' >&2; exit 1; fi
[[ ! -e $tmp/remote/state/revision ]]
export MOCK_UPLOAD_FAIL=0
bootstrap
[[ $(<"$tmp/remote/state/revision") == "$first" ]]
[[ $(git -C "$tmp/remote/repo" rev-parse HEAD) == "$first" ]]
! grep -q 'unexpected timer call' "$tmp/log"
bootstrap # idempotent retry
report_bootstrap() { bash "$cli" bootstrap "$tmp/report-receipt" "$tmp/repo" "$tmp/generated" "$tmp/report-remote/repo" "$tmp/report-remote/machine" "$tmp/report-remote/state"; }
report_bootstrap
[[ $(<"$tmp/report-remote/machine/facter.json") == '{"hardware":"synthetic"}' ]]
printf '{"hardware":"changed"}\n' >"$tmp/generated/facter.json"
report_bootstrap >/dev/null 2>&1 && { echo 'accepted changed hardware report' >&2; exit 1; }
printf '{"hardware":"synthetic"}\n' >"$tmp/generated/facter.json"
# Interrupted upload and incomplete state recover without changing the commit.
rm "$tmp/remote/state/revision" "$tmp/remote/machine/machine.nix"
mkdir -p "$tmp/remote/state/incoming"
printf 'partial\n' >"$tmp/remote/state/incoming/machine.nix"
bootstrap
[[ $(<"$tmp/remote/state/revision") == "$first" ]]
[[ $(<"$tmp/remote/machine/machine.nix") == candidate ]]
printf 'wrong\n' >"$tmp/remote/machine/machine.nix"
if bootstrap >/dev/null 2>&1; then echo 'overwrote private file' >&2; exit 1; fi
printf 'candidate\n' >"$tmp/remote/machine/machine.nix"
printf '%040d\n' 0 >"$tmp/remote/state/revision"
if bootstrap >/dev/null 2>&1; then echo 'overwrote unrelated revision' >&2; exit 1; fi
printf '%s\n' "$first" >"$tmp/remote/state/revision"
git -C "$tmp/remote/repo" remote set-url origin "$tmp/origin.git/other"
if bootstrap >/dev/null 2>&1; then echo 'accepted unrelated checkout' >&2; exit 1; fi
git -C "$tmp/remote/repo" remote set-url origin "$tmp/origin.git"
printf 'different\n' >"$tmp/machine/machine.nix"
if bootstrap >/dev/null 2>&1; then echo 'accepted changed installed machine facts' >&2; exit 1; fi
printf 'candidate\n' >"$tmp/machine/machine.nix"
printf 'change\n' >"$tmp/repo/version"
git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm next
git -C "$tmp/repo" push -q origin HEAD:main
mkdir "$tmp/reviewed"
printf 'production\n' >"$tmp/reviewed/machine.nix"; chmod 600 "$tmp/reviewed/machine.nix"
transition() { bash "$cli" transition "$receipt" root@example "$tmp/remote/repo" main "$tmp/reviewed" "$tmp/remote/machine" test "$tmp/remote/state"; }
MOCK_FAIL=build transition >/dev/null 2>&1 && { echo 'transition build failed open' >&2; exit 1; }
[[ $(<"$tmp/remote/state/revision") == "$first" && $(<"$tmp/remote/machine/machine.nix") == candidate ]]
next=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" checkout -q --orphan rewrite
printf 'rewrite\n' >"$tmp/repo/version"
git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm rewritten
git -C "$tmp/repo" push -q --force origin HEAD:main
# An explicit reviewed transition may rebaseline a squash/rebase without Disko.
transition
[[ $(<"$tmp/remote/state/revision") == $(git -C "$tmp/repo" rev-parse HEAD) ]]
[[ $(<"$tmp/remote/machine/machine.nix") == production ]]
[[ $(<"$tmp/remote/state/selector") == branch:main ]]
! grep -q 'unexpected timer call' "$tmp/log"
[[ $(grep -c ERASE "$tmp/log") == 4 ]]
git -C "$tmp/repo" reset -q --hard "$next"
git -C "$tmp/repo" push -q --force origin HEAD:main
: >"$tmp/log"
chmod 700 "$tmp/state"
printf '%s\n' "$first" >"$tmp/state/revision"
printf 'commit:%s\n' "$first" >"$tmp/state/selector"; chmod 600 "$tmp/state/selector"
: >"$tmp/log"
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state"
[[ ! -s $tmp/log ]]
printf 'branch:main\n' >"$tmp/state/selector" # fixture simulates reviewed selection
MOCK_FAIL=build bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'build failed open' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$first" ]]
! grep -q switch "$tmp/log"
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state"
grep -q switch "$tmp/log"
! grep -q ERASE "$tmp/log"
second=$(<"$tmp/state/revision")
[[ $second != "$first" ]]
[[ $(<"$tmp/generated/facter.json") == '{"hardware":"synthetic"}' ]]
[[ $(<"$tmp/generated/machine.nix") == candidate ]]
rm "$tmp/machine/machine.nix"
printf 'change2\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm third; git -C "$tmp/repo" push -q origin HEAD:main
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'missing config passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# A changed pushed tip between fetch and switch must not be installed.
printf 'candidate\n' >"$tmp/machine/machine.nix"
export MOCK_SOURCE="$tmp/repo" MOCK_TIP_MOVE=1
printf 'branch:main\n' >"$tmp/state/selector"
printf 'change3\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm fourth; git -C "$tmp/repo" push -q origin HEAD:main
if bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1; then echo 'accepted moving tip' >&2; exit 1; fi
[[ $(<"$tmp/state/revision") == "$second" && ! -e $tmp/state/needs-inspection ]]
export MOCK_TIP_MOVE=0
# Only the selected branch is polled, regardless of pushes to main.
git -C "$tmp/repo" push -q origin "$second":refs/heads/candidate
printf 'branch:candidate\n' >"$tmp/state/selector"
: >"$tmp/log"
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state"
[[ ! -s $tmp/log && $(<"$tmp/state/revision") == "$second" ]]
# Locks serialize manual deployments and polling, even when no build is needed.
exec 8>"$tmp/state/lock"; flock -n 8
if bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1; then echo 'concurrent poll passed' >&2; exit 1; fi
if bash "$cli" deploy "$tmp/repo" "commit:$second" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1; then echo 'concurrent deploy passed' >&2; exit 1; fi
flock -u 8
# A failed switch does not change state and blocks further automation.
printf 'branch:main\n' >"$tmp/state/selector"
MOCK_SWITCH_FAIL=1 bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'failed switch passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" && $(<"$tmp/state/selector") == branch:main && -e $tmp/state/needs-inspection ]]
if bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1; then echo 'uncertain switch retried' >&2; exit 1; fi
rm "$tmp/state/needs-inspection" # fixture simulates operator recovery
# Force a divergent origin (never accepted as a fast-forward).
printf 'candidate\n' >"$tmp/machine/machine.nix"; chmod 600 "$tmp/machine/machine.nix"
git -C "$tmp/repo" reset -q --hard "$first"
printf 'other branch\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm diverged
git -C "$tmp/repo" push -q --force origin HEAD:main
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'divergence passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# Legacy adoption: verified closure and private hashes, no install receipt.
# An incomplete upload must not authorize polling (no revision file).
jq -n --arg target root@example --arg rev "$first" --arg branch main --arg url "$tmp/origin.git" --arg sha "$(sha256sum "$tmp/machine/machine.nix" | cut -d ' ' -f1)" \
  '{target:$target,revision:$rev,branch:$branch,origin:$url,machineSha256:$sha,facterSha256:"",verifiedBy:"operator via console",runningSystem:"/nix/store/synthetic-baseline"}' >"$tmp/evidence"
chmod 600 "$tmp/evidence"
adopt() { bash "$cli" adopt "$tmp/evidence" "$tmp/repo" "$tmp/machine" test "$tmp/legacy/repo" "$tmp/legacy/machine" "$tmp/legacy/state"; }
MOCK_RUNNING_SYSTEM=/nix/store/changed adopt >/dev/null 2>&1 && { echo 'adopted wrong running system' >&2; exit 1; }
[[ ! -e $tmp/legacy/state/revision ]]
MOCK_UPLOAD_FAIL=1 adopt >/dev/null 2>&1 && { echo 'adopted incomplete upload' >&2; exit 1; }
[[ ! -e $tmp/legacy/state/revision ]]
bash "$cli" poll "$tmp/repo" "$tmp/machine" test "$tmp/legacy/state" >/dev/null 2>&1 && { echo 'poll accepted incomplete adoption' >&2; exit 1; }
# The original commit is still reachable in the test origin's branch only if
# restored; do not claim a rewritten branch is a verified legacy baseline.
git -C "$tmp/repo" push -q --force origin "$first":main
adopt
[[ $(<"$tmp/legacy/state/revision") == "$first" ]]
[[ $(<"$tmp/legacy/state/selector") == "commit:$first" ]]
: >"$tmp/log"
bash "$cli" poll "$tmp/legacy/repo" "$tmp/legacy/machine" test "$tmp/legacy/state"
[[ ! -s $tmp/log ]]
adopt # retry
printf 'unrelated\n' >"$tmp/legacy/machine/facter.json"
adopt >/dev/null 2>&1 && { echo 'adopt kept unexpected report' >&2; exit 1; }
rm "$tmp/legacy/machine/facter.json"
printf 'wrong\n' >"$tmp/legacy/machine/machine.nix"
adopt >/dev/null 2>&1 && { echo 'adopt overwrote original facts' >&2; exit 1; }
printf 'candidate\n' >"$tmp/legacy/machine/machine.nix"
printf 'wrong\n' >"$tmp/machine/machine.nix"
adopt >/dev/null 2>&1 && { echo 'adopt accepted changed evidence' >&2; exit 1; }
printf 'candidate\n' >"$tmp/machine/machine.nix"
printf '%040d\n' 0 >"$tmp/legacy/state/revision"
adopt >/dev/null 2>&1 && { echo 'adopt replaced conflicting revision' >&2; exit 1; }
! grep -q ERASE "$tmp/log"
# Both consumer policies parse, and the candidate relay's timer starts disabled.
if command -v nix-instantiate >/dev/null; then
  for file in "$root"/examples/*.nix "$root"/packages/cli/src/machine/update.nix; do nix-instantiate --parse "$file" >/dev/null; done
fi
! grep -q 'timer = false' "$root/examples/agentic.nix"
! grep -q 'timer = false' "$root/examples/thepeer.nix"
! grep -q 'update --repo' "$root/packages/cli/src/machine/update.nix" || { echo 'module/CLI argument mismatch' >&2; exit 1; }
# Public CLI: the private configuration declares source/policy once; plan
# captures live facts and evaluates before publishing. Applying repeats all
# time-sensitive checks and never treats the plan as erase authorization.
public_cli="$root/packages/cli/bin/moss"
config="$tmp/public-config.json"
plan="$tmp/public-plan.json"
public_receipt="$tmp/public-receipt.json"
jq -n --arg repo "$tmp/repo" --arg rev "$first" --arg machine "$tmp/machine" \
  --arg receipt "$public_receipt" --arg remote "$tmp/public-remote" \
  '{version:1,repo:$repo,revision:$rev,branch:"main",output:"test",machine:$machine,
   receipt:$receipt,remoteCheckout:($remote+"/repo"),remoteMachine:($remote+"/machine"),remoteState:($remote+"/state")}' >"$config"
chmod 600 "$config"
: >"$tmp/log"
bash "$public_cli" machine plan root@example --config "$config" --disk /dev/vda --output "$plan"
[[ $(stat -c %a "$plan") == 600 ]]
jq -e '.type == "install" and .observed.disk.path == "/dev/vda" and .machineSha256 != ""' "$plan" >/dev/null
! grep -q ERASE "$tmp/log"
! bash "$public_cli" machine plan root@example --config "$config" --disk /dev/sda --output "$tmp/invalid-plan" >/dev/null 2>&1
! bash "$public_cli" machine plan root@example --config "$config" --disk /dev/vda --output "$plan" >/dev/null 2>&1
printf 'wrong\n' | bash "$public_cli" machine apply "$plan" >/dev/null 2>&1 && { echo 'public apply bypassed confirmation' >&2; exit 1; }
[[ ! -e $public_receipt ]] && ! grep -q ERASE "$tmp/log"
cp "$config" "$tmp/config-copy"; printf ' \n' >>"$config"
! bash "$public_cli" machine apply "$plan" </dev/null >/dev/null 2>&1
mv "$tmp/config-copy" "$config"; chmod 600 "$config"
[[ ! -e $public_receipt ]]
printf 'ERASE /dev/vda\n' | bash "$public_cli" machine apply "$plan" >/dev/null
[[ -f $public_receipt && $(stat -c %a "$public_receipt") == 600 ]]
! bash "$public_cli" machine apply "$plan" </dev/null >/dev/null 2>&1
# The post-install handoff has its own host-key trust boundary and is retryable.
MOCK_HOST_VERIFIED=0 bash "$public_cli" machine bootstrap "$public_receipt" --config "$config" >/dev/null 2>&1 && exit 1
MOCK_HOST_VERIFIED=1 bash "$public_cli" machine bootstrap "$public_receipt" --config "$config"
bash "$public_cli" machine bootstrap "$public_receipt" --config "$config"
# A separately reviewed transition changes the initial commit pin to branch
# tracking. Planning must never silently make that policy choice itself.
bash "$cli" transition "$public_receipt" root@example "$tmp/public-remote/repo" main "$tmp/machine" "$tmp/public-remote/machine" test "$tmp/public-remote/state" >/dev/null
# Same plan/apply interface: an installed branch-tracking host yields an
# update plan; its executor must never call the disk installer.
printf 'next\n' >"$tmp/repo/next"; git -C "$tmp/repo" add next; git -C "$tmp/repo" commit -qm next
update_rev=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" push -q origin HEAD:main
jq --arg rev "$update_rev" '.revision = $rev' "$config" >"$tmp/new-config"
mv "$tmp/new-config" "$config"; chmod 600 "$config"
update_plan="$tmp/update-plan.json"
bash "$public_cli" machine plan root@example --config "$config" --output "$update_plan"
jq -e --arg next "$update_rev" '.type == "update" and .expected.next == $next' "$update_plan" >/dev/null
# Tip movement after planning must not silently deploy the newer commit.
git -C "$tmp/repo" commit --allow-empty -qm 'moved after review'
git -C "$tmp/repo" push -q origin HEAD:main
: >"$tmp/log"
! bash "$public_cli" machine apply "$update_plan" >/dev/null 2>&1
[[ $(<"$tmp/public-remote/state/revision") == "$first" ]]
! grep -q 'switch\|ERASE' "$tmp/log"
git -C "$tmp/repo" push -q --force origin "$update_rev":main
bash "$public_cli" machine apply "$update_plan"
[[ $(<"$tmp/public-remote/state/revision") == "$update_rev" ]]
! grep -q ERASE "$tmp/log"
! bash "$public_cli" machine apply "$update_plan" >/dev/null 2>&1
bash "$root/tests/audit.sh"
echo 'Bash fixture checks passed'
