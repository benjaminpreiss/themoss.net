  inputs)
    [[ $# == 2 ]] || usage
    task=$1 inputs=$2
    [[ $task == check || $task == apply ]] || usage
    [[ -f $inputs && ! -L $inputs && $(stat -c %a "$inputs") == 600 ]] || fail 'inputs must be a mode-600 regular file (not a link)'
    [[ $(realpath -m "$inputs") == "$(realpath "$inputs")" ]] || fail 'linked inputs path'
    # Off-host state must never be committed or staged in the consumer source.
    jq -e '
      type == "object" and (.version == 1) and
      ((keys - ["version","target","disk","record","repo","revision","branch","output","machine","receipt","remoteCheckout","remoteMachine","remoteState","reportGenerator","recoveryDir","preEraseCheck"]) == []) and
      ([.target,.disk,.record,.repo,.revision,.branch,.output,.machine,.receipt,.remoteCheckout,.remoteMachine,.remoteState] | all(type == "string" and length > 0)) and
      (. as $m | ["reportGenerator","recoveryDir","preEraseCheck"] | all(. as $key | ($m | has($key) | not) or ($m[$key] | type == "string" and length > 0)))
    ' "$inputs" >/dev/null || fail 'invalid inputs schema'
    # Private off-host inputs must stay outside the consumer commit.
    repo=$(jq -r .repo "$inputs")
    [[ -d $repo && ! -L $repo && $(realpath -m "$repo") == "$(realpath "$repo")" ]] || fail 'invalid checkout'
    inputs_abs=$(realpath "$inputs")
    repo_abs=$(realpath "$repo")
    if [[ $inputs_abs == "$repo_abs/"* ]]; then
      relative=${inputs_abs#"$repo_abs/"}
      git -C "$repo" check-ignore -q -- "$relative" || fail 'inputs inside checkout must be Git-ignored'
      [[ -z $(git -C "$repo" ls-files -- "$relative") ]] || fail 'tracked inputs'
    fi
    target=$(jq -r .target "$inputs") disk=$(jq -r .disk "$inputs")
    record=$(jq -r .record "$inputs") rev=$(jq -r .revision "$inputs")
    branch=$(jq -r .branch "$inputs") output=$(jq -r .output "$inputs")
    machine=$(jq -r .machine "$inputs") receipt=$(jq -r .receipt "$inputs")
    checkout=$(jq -r .remoteCheckout "$inputs")
    remote_machine=$(jq -r .remoteMachine "$inputs") state=$(jq -r .remoteState "$inputs")
    generator=$(jq -r '.reportGenerator // "-"' "$inputs")
    recovery=$(jq -r '.recoveryDir // "-"' "$inputs")
    pre_erase=$(jq -r '.preEraseCheck // "-"' "$inputs")
    [[ $target =~ ^root@[a-zA-Z0-9_.:-]+$ && $disk =~ ^/dev/[a-zA-Z0-9_./-]+$ && $disk != *..* ]] || fail 'invalid target or disk'
    [[ $rev =~ ^[0-9a-f]{40}$ && $output =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'invalid revision or output'
    valid_ref "branch:$branch" || fail 'invalid branch'
    for path in "$record" "$machine" "$receipt"; do
      [[ $path == /* && $path != *..* ]] || fail 'private paths must be absolute without traversal'
    done
    for path in "$checkout" "$remote_machine" "$state"; do
      [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* ]] || fail 'unsafe remote path'
    done
    private_record "$record"
    [[ $target == "$(jq -r .target "$record")" && $disk == "$(jq -r .disk.path "$record")" ]] || fail 'inputs differs from discovery record'
    [[ -f $machine/machine.nix && ! -L $machine && ! -L $machine/machine.nix && $(stat -c %a "$machine/machine.nix") == 600 ]] || fail 'unsafe private machine.nix'
    [[ ! -e $receipt && ! -L $receipt ]] || fail 'install receipt already exists; never reinstall to repair bootstrap'
      [[ $repo == /* && $machine == /* ]] || fail 'checkout and machine paths must be absolute'
      [[ $(git -C "$repo" ls-remote --exit-code origin "refs/heads/$branch" | cut -f1) == "$rev" ]] || fail 'revision differs from pushed branch tip'
      bash "${BASH_SOURCE[0]}" preflight "$record"
      printf 'Reviewed install plan: pushed revision=%s branch=%s output=%s\n' "$rev" "$branch" "$output"
      printf 'Paths: repo=%s machine=%s receipt=%s remote checkout=%s machine=%s state=%s\n' "$repo" "$machine" "$receipt" "$checkout" "$remote_machine" "$state"
      printf 'Consumer checks: report=%s recovery=%s pre-erase=%s\n' "$generator" "$recovery" "$pre_erase"
      [[ $task == check ]] && exit 0
      bash "${BASH_SOURCE[0]}" install "$record" "$repo" "$rev" "$machine" "$output" "$branch" "$receipt" "$generator" "$recovery" "$pre_erase"
    ;;
