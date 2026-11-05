#!/usr/bin/env bash
# Toolkit fixture entry point: CI (.github/workflows/ci.yml) builds the CLI
# and runs this from the repo root. Locally, build moss with Cargo first (or
# set MOSS_BIN to a Nix-built binary). Mocks SSH/Nix/installer commands, uses
# local Git, and calls tests/audit.sh.
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
if [[ $* == *'--version'* && -n ${MOCK_REMOTE_VERSION:-} ]]; then echo "$MOCK_REMOTE_VERSION"; exit 0; fi
if [[ $* == *'/sys/class/net/'* ]]; then echo aa:bb:cc:dd:ee:ff
elif [[ $* == tar\ -xf* && ${MOCK_UPLOAD_FAIL:-0} == 1 ]]; then exit 79
elif [[ $* == *'--version'* || $* == *bootstrap-remote* || $* == *prepare-transition* || $* == *update* || $* == tar\ -xf* ]]; then
  command=${*//\/run\/current-system\/sw\/bin\/moss/$MOCK_MOSS_BIN}
  bash -c "$command"
else cat "$MOCK_PROBE"; fi
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$MOCK_LOG"
[[ $MOCK_FAIL != build ]]
EOF
cat >"$tmp/bin/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
echo "switch $*" >>"$MOCK_LOG"
EOF
cat >"$tmp/bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
echo "ERASE $*" >>"$MOCK_LOG"
EOF
chmod +x "$tmp/bin/"*
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$root/.target}
cli=${MOSS_BIN:-$CARGO_TARGET_DIR/debug/moss}
if [[ -z ${MOSS_BIN:-} ]]; then
  (cd "$root" && cargo build --locked --quiet && cargo test --locked --quiet)
fi
export MOCK_MOSS_BIN="$cli"
"$cli" discover root@example /dev/vda "$tmp/record"
"$cli" preflight "$tmp/record"
for key in arch boot nic mac disk; do
  jq --arg key "$key" 'if $key == "disk" then .disk.size = 999 else .[$key] = "wrong" end' "$tmp/record" >"$tmp/changed"
  chmod 600 "$tmp/changed"
  if "$cli" preflight "$tmp/changed" >/dev/null 2>&1; then echo "accepted mismatched $key" >&2; exit 1; fi
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
printf 'ERASE /dev/vda\n' | "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" >/dev/null 2>&1 && exit 1
git -C "$tmp/repo" push -q origin HEAD:main
printf 'no\n' | "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" > /dev/null 2>&1 && { echo 'confirmation bypass' >&2; exit 1; }
[[ ! -e $receipt ]]
! grep -q ERASE "$tmp/log"
printf 'ERASE /dev/vda\n' | "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt"
[[ $(jq -r .revision "$receipt") == "$first" && $(stat -c %a "$receipt") == 600 ]]
if printf 'ERASE /dev/vda\n' | "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test main "$receipt" >/dev/null 2>&1; then echo 'replaced receipt' >&2; exit 1; fi
[[ $(grep -c ERASE "$tmp/log") == 1 ]]
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "unexpected timer call $*" >>"$MOCK_LOG"
exit 86 # candidate has no updater timer unit
EOF
chmod +x "$tmp/bin/systemctl"
bootstrap() { "$cli" bootstrap "$receipt" "$tmp/repo" "$tmp/machine" "$tmp/remote/repo" "$tmp/remote/machine" "$tmp/remote/state"; }
export MOCK_HOST_VERIFIED=0
if bootstrap >/dev/null 2>&1; then echo 'accepted unverified host key' >&2; exit 1; fi
export MOCK_HOST_VERIFIED=1 MOCK_REMOTE_VERSION='moss 0.0.0'
if bootstrap >/dev/null 2>&1; then echo 'accepted mismatched target CLI' >&2; exit 1; fi
[[ ! -e $tmp/remote/state/revision ]]
unset MOCK_REMOTE_VERSION
export MOCK_UPLOAD_FAIL=1
if bootstrap >/dev/null 2>&1; then echo 'accepted incomplete upload' >&2; exit 1; fi
[[ ! -e $tmp/remote/state/revision ]]
export MOCK_UPLOAD_FAIL=0
bootstrap
[[ $(<"$tmp/remote/state/revision") == "$first" ]]
[[ $(git -C "$tmp/remote/repo" rev-parse HEAD) == "$first" ]]
! grep -q 'unexpected timer call' "$tmp/log"
bootstrap # idempotent retry
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
transition() { "$cli" transition "$receipt" root@example "$tmp/remote/repo" main "$tmp/reviewed" "$tmp/remote/machine" test "$tmp/remote/state"; }
MOCK_FAIL=build transition >/dev/null 2>&1 && { echo 'transition build failed open' >&2; exit 1; }
[[ $(<"$tmp/remote/state/revision") == "$first" && $(<"$tmp/remote/machine/machine.nix") == candidate ]]
next=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" checkout -q --orphan rewrite
printf 'rewrite\n' >"$tmp/repo/version"
git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm rewritten
git -C "$tmp/repo" push -q --force origin HEAD:main
if transition >/dev/null 2>&1; then echo 'transition accepted divergent history' >&2; exit 1; fi
[[ $(<"$tmp/remote/state/revision") == "$first" && $(<"$tmp/remote/machine/machine.nix") == candidate ]]
git -C "$tmp/repo" reset -q --hard "$next"
git -C "$tmp/repo" push -q --force origin HEAD:main
transition
[[ $(<"$tmp/remote/state/revision") == $(git -C "$tmp/repo" rev-parse HEAD) ]]
[[ $(<"$tmp/remote/machine/machine.nix") == production ]]
! grep -q 'unexpected timer call' "$tmp/log"
[[ $(grep -c ERASE "$tmp/log") == 1 ]]
: >"$tmp/log"
printf '%s\n' "$first" >"$tmp/state/revision"
MOCK_FAIL=build "$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'build failed open' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$first" ]]
! grep -q switch "$tmp/log"
"$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state"
grep -q switch "$tmp/log"
! grep -q ERASE "$tmp/log"
second=$(<"$tmp/state/revision")
[[ $second != "$first" ]]
rm "$tmp/machine/machine.nix"
printf 'change2\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm third; git -C "$tmp/repo" push -q origin HEAD:main
"$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'missing config passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# Force a divergent origin (never accepted as a fast-forward).
printf 'candidate\n' >"$tmp/machine/machine.nix"
git -C "$tmp/repo" reset -q --hard "$first"
printf 'other branch\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm diverged
git -C "$tmp/repo" push -q --force origin HEAD:main
"$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'divergence passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# Both consumer policies parse, and the candidate relay's timer starts disabled.
if command -v nix-instantiate >/dev/null; then
  for file in "$root"/examples/*.nix "$root"/toolkit/update.nix; do nix-instantiate --parse "$file" >/dev/null; done
fi
grep -q 'timer = false' "$root/examples/agentic.nix"
grep -q 'timer = false' "$root/examples/thepeer.nix"
grep -q 'moss update' "$root/toolkit/update.nix" || { echo 'module/CLI argument mismatch' >&2; exit 1; }
"$cli" generate-docs "$tmp/generated-cli.md"
diff -u "$root/docs/cli.md" "$tmp/generated-cli.md"
bash "$root/tests/audit.sh"
echo 'Rust CLI fixture and generated documentation checks passed'
