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
