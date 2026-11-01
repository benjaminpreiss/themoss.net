#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "$root/.test-tmp.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
mkdir -p "$tmp/bin" "$tmp/machine" "$tmp/state" "$tmp/repo"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/log" MOCK_PROBE="$tmp/probe" MOCK_FAIL='' MOCK_DIVERGE=''
printf 'candidate\n' >"$tmp/machine/machine.nix"
printf '%s\n' x86_64 >"$tmp/probe"
printf '%s\n' bios >>"$tmp/probe"
printf '%s\n' '[{"dev":"eth0"}]' >>"$tmp/probe"
printf '%s\n' '{"blockdevices":[{"path":"/dev/vda","type":"disk","size":1000,"model":"A","serial":"123"}]}' >>"$tmp/probe"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ ${*: -1} == *'cat /sys/class/net/'* ]]; then echo aa:bb:cc:dd:ee:ff; else cat "$MOCK_PROBE"; fi
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
cli="$root/toolkit/deploy.sh"
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
printf 'no\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$first" "$tmp/machine" test > /dev/null 2>&1 && { echo 'confirmation bypass' >&2; exit 1; }
! grep -q ERASE "$tmp/log"
# local bare origin gives real fetch/ancestry behavior, with no network.
git init -q --bare "$tmp/origin.git"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
git -C "$tmp/repo" push -q origin HEAD:main
printf 'change\n' >"$tmp/repo/version"
git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm next
git -C "$tmp/repo" push -q origin HEAD:main
printf '%s\n' "$first" >"$tmp/state/revision"
MOCK_FAIL=build bash "$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'build failed open' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$first" ]]
! grep -q switch "$tmp/log"
bash "$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state"
grep -q switch "$tmp/log"
! grep -q ERASE "$tmp/log"
second=$(<"$tmp/state/revision")
[[ $second != "$first" ]]
rm "$tmp/machine/machine.nix"
printf 'change2\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm third; git -C "$tmp/repo" push -q origin HEAD:main
bash "$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'missing config passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# Force a divergent origin (never accepted as a fast-forward).
printf 'candidate\n' >"$tmp/machine/machine.nix"
git -C "$tmp/repo" reset -q --hard "$first"
printf 'other branch\n' >"$tmp/repo/version"; git -C "$tmp/repo" add version; git -C "$tmp/repo" commit -qm diverged
git -C "$tmp/repo" push -q --force origin HEAD:main
bash "$cli" update "$tmp/repo" main "$tmp/machine" test "$tmp/state" >/dev/null 2>&1 && { echo 'divergence passed' >&2; exit 1; }
[[ $(<"$tmp/state/revision") == "$second" ]]
# Both consumer policies parse, and the candidate relay's timer starts disabled.
if command -v nix-instantiate >/dev/null; then
  for file in "$root"/examples/*.nix "$root"/toolkit/{update,audit}.nix; do nix-instantiate --parse "$file" >/dev/null; done
fi
grep -q 'timer = false' "$root/examples/agentic.nix"
grep -q 'timer = false' "$root/examples/thepeer.nix"
! grep -q 'update --repo' "$root/toolkit/update.nix" || { echo 'module/CLI argument mismatch' >&2; exit 1; }
bash "$root/tests/audit.sh"
echo 'Bash fixture checks passed'
