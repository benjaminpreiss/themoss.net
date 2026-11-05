  apply-reviewed)
    # The reviewed revision and selector are mandatory: never follow a newer
    # tip than the one shown in the plan or silently reinterpret its action.
    [[ $# == 9 ]] || usage
    repo=$1 machine=$2 host=$3 state=$4 requested=$5 expected_current=$6 expected_next=$7 expected_sha=$8 expected_origin=$9
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid target inputs'
    valid_ref "$requested" || fail 'invalid selected reference'
    [[ -n $expected_origin && $(git -C "$repo" remote get-url origin) == "$expected_origin" ]] || fail 'target Git origin changed'
    [[ $requested == branch:* && $expected_current =~ ^[0-9a-f]{40}$ && $expected_next =~ ^[0-9a-f]{40}$ && $expected_sha =~ ^[0-9a-f]{64}$ ]] || fail 'invalid reviewed update'
    locked_state "$state"
    selector "$state"
    [[ $current == "$expected_current" && $selected == "$requested" ]] || fail 'installed baseline or selector changed; make a new plan'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$expected_sha" ]] || fail 'private machine input changed'
    branch=${requested#branch:}
    next=$(branch_tip "$repo" "$branch")
    [[ $next == "$expected_next" ]] || fail 'pushed tip changed; make a new plan'
    git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
    [[ $next != "$current" ]] || { echo "Already at $current"; exit 0; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$next" "$machine" "$tmp"
    build "$tmp" "$host"
    verify_tip "$repo" "$branch" "$next"
    record_switch "$state" "$requested" "$next" "$tmp" "$host"
    echo "SWITCH OK $current -> $next ($requested)"
    ;;
