#!/usr/bin/env bash
# Off-host-only smoke fixture: runs on macOS or Linux inside .#operator.
# Remote Linux commands are mocked; no actual disk, host or Linux builder used.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/machine"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/log"
printf 'synthetic\n' >"$tmp/machine/machine.nix"; chmod 600 "$tmp/machine/machine.nix"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -o && $2 == StrictHostKeyChecking=yes ]] || exit 1
shift 3 # options and target
if [[ $* == *'cat /sys/class/net/'* ]]; then
  echo aa:bb:cc:dd:ee:ff
elif [[ $* == bash\ -s\ --* || $* == tar\ -xf* ]]; then
  echo "remote $*" >>"$MOCK_LOG"
else
  printf '%s\n' x86_64 bios '[{"dev":"eth0"}]' '{"blockdevices":[{"path":"/dev/vda","type":"disk","size":1000,"model":"A","serial":"123"}]}'
fi
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "build $*" >>"$MOCK_LOG"
EOF
cat >"$tmp/bin/nixos-anywhere" <<'EOF'
#!/usr/bin/env bash
echo "ERASE $*" >>"$MOCK_LOG"
EOF
chmod +x "$tmp/bin/"*
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
printf '{}\n' >"$tmp/repo/flake.lock"
printf '{ outputs = _: {}; }\n' >"$tmp/repo/flake.nix"
git -C "$tmp/repo" add .; git -C "$tmp/repo" commit -qm initial
rev=$(git -C "$tmp/repo" rev-parse HEAD)
git init -q --bare "$tmp/origin.git"
git -C "$tmp/repo" remote add origin "$tmp/origin.git"
git -C "$tmp/repo" push -q origin HEAD:main
cli="$root/toolkit/deploy.sh"
bash "$cli" discover root@example /dev/vda "$tmp/record"
bash "$cli" preflight "$tmp/record"
# Build and validate before any disk call; denial must leave no receipt.
printf 'DENY\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$rev" "$tmp/machine" test main "$tmp/receipt" >/dev/null 2>&1 && exit 1
[[ ! -e $tmp/receipt ]] && ! grep -q ERASE "$tmp/log"
printf 'ERASE /dev/vda\n' | bash "$cli" install "$tmp/record" "$tmp/repo" "$rev" "$tmp/machine" test main "$tmp/receipt"
[[ $(jq -r .revision "$tmp/receipt") == "$rev" ]]
bash "$cli" bootstrap "$tmp/receipt" "$tmp/repo" "$tmp/machine" /root/consumer /root/private-machine /var/lib/themoss
[[ $(grep -c ERASE "$tmp/log") == 1 ]]
echo 'Off-host operator smoke passed (mock target)'
