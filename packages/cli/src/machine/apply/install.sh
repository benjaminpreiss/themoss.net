  install)
    [[ $# -ge 7 && $# -le 10 ]] || usage
    record=$1 repo=$2 rev=$3 machine=$4 host=$5 branch=$6 receipt=$7
    generator=${8:--} recovery=${9:--} pre_erase=${10:--}
    [[ $host =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid host output'
    for hook in "$generator" "$pre_erase"; do
      [[ $hook == - || ( -f $hook && ! -L $hook && -x $hook ) ]] || fail 'hook must be an executable regular file'
    done
    if [[ $recovery != - ]]; then
      [[ -d $recovery && ! -L $recovery ]] || fail 'missing recovery directory'
      [[ -z $(find "$recovery" -type l -print -quit) ]] || fail 'linked recovery file'
    fi
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'refusing to replace install receipt'
    [[ -d $(dirname "$receipt") && ! -L $(dirname "$receipt") ]] || fail 'invalid receipt directory'
    # A clean checkout prevents an operator from mistaking uncommitted edits
    # for the committed OS that will actually be installed.
    [[ -z $(git -C "$repo" status --porcelain) ]] || fail 'commit/review local changes before install'
    [[ $rev =~ ^[0-9a-f]{40}$ && $(git -C "$repo" cat-file -t "$rev") == commit ]] || fail 'install requires a pinned full commit'
    [[ $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid branch'
    [[ $(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) == "$rev" ]] || fail 'install commit must be pushed as exact branch head'
    check "$record"
    if [[ $generator != - ]]; then
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'refusing to replace hardware report'
      # The generator is consumer-owned. It receives the verified SSH target
      # and a private output path; it must not write into the Nix store.
      report=$(mktemp "$machine/.facter.XXXXXXXX")
      rm -- "$report"
      "$generator" "$(jq -r .target "$record")" "$report"
      [[ -f $report && ! -L $report ]] || fail 'generator did not produce a regular report'
      jq -e . "$report" >/dev/null || fail 'invalid hardware report'
      [[ ! -e $machine/facter.json && ! -L $machine/facter.json ]] || fail 'hardware report appeared during generation'
      chmod 600 "$report"
      mv -n -- "$report" "$machine/facter.json"
    fi
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    stage "$repo" "$rev" "$machine" "$tmp"
    build "$tmp" "$host"
    if [[ $pre_erase != - ]]; then "$pre_erase" "$tmp" "$host" "$record"; fi
    disk=$(jq -r .disk.path "$record")
    read -r -p "Type ERASE $disk to install on $(jq -r .target "$record"): " answer || fail 'confirmation denied'
    [[ $answer == "ERASE $disk" ]] || fail 'confirmation denied'
    check "$record" # target may have changed while building
    verify_tip "$repo" "$branch" "$rev" # pushed tip may have moved during build
    # Destructive boundary: no other command below can reach this installer.
    anywhere=(--flake "$tmp#$host" --target-host "$(jq -r .target "$record")")
    if [[ $recovery != - ]]; then anywhere+=(--extra-files "$recovery"); fi
    nixos-anywhere "${anywhere[@]}"
    # Only a successful installer can produce the off-host install receipt.
    # Keep it separate from the Nix store; private files must still be secret-free.
    url=$(git -C "$repo" remote get-url origin)
    sha=$(sha256sum "$machine/machine.nix" | cut -d ' ' -f1)
    facter_sha=''
    if [[ -f $machine/facter.json ]]; then facter_sha=$(sha256sum "$machine/facter.json" | cut -d ' ' -f1); fi
    jq -n --arg target "$(jq -r .target "$record")" --arg rev "$rev" --arg branch "$branch" --arg url "$url" --arg sha "$sha" --arg facter "$facter_sha" \
      '{target:$target,revision:$rev,branch:$branch,origin:$url,machineSha256:$sha,facterSha256:$facter}' >"$receipt.tmp"
    chmod 600 "$receipt.tmp"
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'receipt appeared during install'
    mv -n -- "$receipt.tmp" "$receipt"
    echo "Install receipt: $receipt (back up off-host; do not reinstall to repair bootstrap)"
    ;;
