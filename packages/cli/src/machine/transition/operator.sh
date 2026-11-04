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
