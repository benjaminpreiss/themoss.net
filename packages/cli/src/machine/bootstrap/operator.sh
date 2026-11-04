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
    helper=$(dirname "${BASH_SOURCE[0]}")/bootstrap/remote.sh
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
