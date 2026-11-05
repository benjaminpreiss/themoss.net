  plan-build)
    # Internal non-destructive evaluated check. The operator CLI owns the
    # reviewed plan; the installer repeats these gates before erase.
    [[ $# == 8 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6 generator=$7 pre_erase=$8
    [[ $host =~ ^[a-zA-Z0-9_-]+$ && $rev =~ ^[0-9a-f]{40}$ ]] || fail 'invalid output or revision'
    valid_ref "branch:$branch" || fail 'invalid branch'
    [[ -z $(git -C "$repo" status --porcelain) ]] || fail 'commit/review local changes before planning'
    [[ $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'missing pinned commit'
    verify_tip "$repo" "$branch" "$rev"
    check "$record"
    for hook in "$generator" "$pre_erase"; do
      [[ $hook == - || ( -f $hook && ! -L $hook && -x $hook ) ]] || fail 'hook must be an executable regular file'
    done
    if [[ $generator != - ]]; then
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'refusing to replace hardware report'
      report=$(mktemp "$machine/.facter.XXXXXXXX")
      rm -- "$report"
      trap 'rm -f -- "$report"' EXIT
      "$generator" "$(jq -r .target "$record")" "$report"
      [[ -f $report && ! -L $report ]] || fail 'generator did not produce a regular report'
      jq -e . "$report" >/dev/null || fail 'invalid hardware report'
      chmod 600 "$report"
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'hardware report appeared during generation'
      mv -n -- "$report" "$machine/facter.json"
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    build "$tmp" "$host"
    if [[ $pre_erase != - ]]; then "$pre_erase" "$tmp" "$host" "$record"; fi
    verify_tip "$repo" "$branch" "$rev"
    echo 'Evaluated build and consumer pre-erase check passed; review the reported target and disk before install.'
    ;;
