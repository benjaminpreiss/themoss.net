  plan-update)
    # Target-side planning: only an already installed, branch-tracking host.
    [[ $# == 7 ]] || usage
    repo=$1 machine=$2 host=$3 state=$4 branch=$5 expected=$6 expected_origin=$7
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ && $expected =~ ^[0-9a-f]{40}$ ]] || fail 'invalid update inputs'
    valid_ref "branch:$branch" || fail 'invalid update branch'
    [[ -n $expected_origin && $(git -C "$repo" remote get-url origin) == "$expected_origin" ]] || fail 'target Git origin changed'
    locked_state "$state"
    selector "$state"
    [[ $selected == "branch:$branch" ]] || fail 'selected branch differs; transition requires separate operator review'
    next=$(branch_tip "$repo" "$branch")
    [[ $next == "$expected" ]] || fail 'candidate differs from pushed branch tip'
    git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
    [[ -f $machine/machine.nix && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine input'
    sha=$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$next" "$machine" "$tmp"
    build "$tmp" "$host"
    verify_tip "$repo" "$branch" "$next"
    jq -n --arg current "$current" --arg selected "$selected" --arg next "$next" --arg sha "$sha" \
      '{current:$current,selected:$selected,next:$next,machineSha256:$sha}'
    ;;
