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
