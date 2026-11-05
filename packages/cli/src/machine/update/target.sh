  poll | deploy | apply-transition)
    if [[ $op == poll ]]; then [[ $# == 4 ]] || usage
    elif [[ $op == deploy ]]; then [[ $# == 5 ]] || usage
    else [[ $# == 8 ]] || usage; fi
    repo=$1; shift
    requested=''
    if [[ $op == deploy ]]; then requested=$1; shift; fi
    if [[ $op == apply-transition ]]; then branch=$1; shift; fi
    machine=$1 host=$2 state=$3; shift 3
    [[ -d $repo/.git && ! -L $repo && -d $machine && ! -L $machine && $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid target inputs'
    locked_state "$state"
    selector "$state"
    reviewed=''
    if [[ $op == poll ]]; then
      [[ $selected == branch:* ]] || exit 0
      requested=$selected
    elif [[ $op == apply-transition ]]; then
      reviewed=$1; expected_rev=$2; expected_sha=$3
      requested="branch:$branch"
      valid_ref "$requested" || fail 'invalid branch'
      [[ $expected_rev == "$current" && $expected_sha =~ ^[0-9a-f]{64}$ && $reviewed == "$state/transition-incoming/machine.nix" ]] || fail 'invalid transition baseline'
      [[ -f $reviewed && ! -L $reviewed && -f $machine/machine.nix && ! -L $machine/machine.nix ]] || fail 'missing reviewed/current machine facts'
      [[ $(sha256sum "$machine/machine.nix" | cut -d ' ' -f1) == "$expected_sha" ]] || fail 'machine facts changed since install'
      [[ ! -L $state/transition-incoming && $(stat -c %a "$state/transition-incoming") == 700 ]] || fail 'unsafe reviewed upload'
      echo 'Reviewed transition: explicitly replacing prior baseline (squash/rebase allowed)' >&2
    else
      valid_ref "$requested" || fail 'invalid reference'
    fi
    if [[ $requested == branch:* ]]; then
      branch=${requested#branch:}
      next=$(branch_tip "$repo" "$branch")
      if [[ $op != apply-transition ]]; then
        git -C "$repo" merge-base --is-ancestor "$current" "$next" || fail 'diverged history; use reviewed transition'
      fi
      [[ $next != "$current" || $requested != "$selected" || -n $reviewed ]] || { echo "Already at $next"; exit 0; }
    else
      next=${requested#commit:}
      [[ $(git -C "$repo" cat-file -t "$next") == commit ]] || fail 'commit missing locally'
      [[ $next == "$current" || $selected == "commit:$current" ]] || fail 'new baseline requires reviewed transition'
      [[ $next == "$current" && $selected == "$requested" ]] && exit 0
      if [[ $next != "$current" ]]; then echo 'WARNING: pinning an unmerged commit; a later reviewed branch transition can replace it' >&2; fi
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage_machine=$machine
    if [[ -n $reviewed ]]; then
      mkdir -m 700 "$tmp/private"
      cp -- "$reviewed" "$tmp/private/machine.nix"
      if [[ -f $machine/facter.json && ! -L $machine/facter.json ]]; then cp -- "$machine/facter.json" "$tmp/private/facter.json"; fi
      stage_machine=$tmp/private
    fi
    mkdir -m 700 "$tmp/source"
    stage "$repo" "$next" "$stage_machine" "$tmp/source"
    build "$tmp/source" "$host"
    if [[ $requested == branch:* ]]; then verify_tip "$repo" "$branch" "$next"; fi
    record_switch "$state" "$requested" "$next" "$tmp/source" "$host" "$reviewed" "$machine"
    [[ -z $reviewed ]] || rm -rf -- "$state/transition-incoming"
    echo "SWITCH OK $current -> $next ($requested)"
    ;;
