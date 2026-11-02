#!/usr/bin/env bash
# Run only over SSH with StrictHostKeyChecking=yes, as root. Never install disks.
# Called twice: prepare clears an interrupted upload; finish verifies and
# commits it. The receipt's revision must be the initial known-good revision.
# @describe Internal root-only bootstrap protocol. Never installs disks.
set -euo pipefail
umask 077
fail() { echo "themoss bootstrap: $*" >&2; exit 1; }
bootstrap_remote() {
[[ $# == 7 ]] || fail 'usage: phase repository-url revision checkout machine state branch'
phase=$1 url=$2 rev=$3 repo=$4 machine=$5 state=$6 branch=$7
[[ $rev =~ ^[0-9a-f]{40}$ && $branch =~ ^[a-zA-Z0-9_/-]+$ && $branch != *..* ]] || fail 'invalid revision or branch'
for path in "$repo" "$machine" "$state"; do
  [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *..* && ! -L $path ]] || fail 'unsafe path'
done
[[ $repo != "$state"* && $machine != "$state"* && $repo != "$machine"* && $machine != "$repo"* ]] || fail 'overlapping paths'
[[ $url != -* && $url != *$'\n'* ]] || fail 'invalid origin'
[[ $(id -u) == 0 || ${THEMOSS_TEST_ROOT:-} == 1 ]] || fail 'root required'
mkdir -p -m 700 "$state"
[[ $(stat -c %a "$state") == 700 ]] || fail 'state must be mode 700'
exec 9>"$state/lock"
flock -n 9 || fail 'bootstrap already running'
[[ ! -L $state/revision && ! -L $state/selector && ! -L $state/incoming ]] || fail 'linked state'
[[ ! -e $state/needs-inspection ]] || fail 'switch requires inspection'
if [[ -e $state/selector ]]; then
  [[ -f $state/selector && $(stat -c %a "$state/selector") == 600 && $(<"$state/selector") == "commit:$rev" ]] || fail 'selector differs from installed commit'
fi
# Re-running bootstrap may finish an interrupted attempt, but never replace a
# different known-good revision or an unrelated source checkout.
if [[ -e $state/revision ]]; then
  [[ -f $state/revision && $(<"$state/revision") == "$rev" ]] || fail 'different known-good revision'
fi
if [[ -e $repo ]]; then
  [[ -d $repo && -d $repo/.git && ! -L $repo/.git ]] || fail 'unrelated checkout'
  [[ $(git -C "$repo" remote get-url origin) == "$url" && $(git -C "$repo" rev-parse HEAD) == "$rev" ]] || fail 'checkout does not match installed commit/origin'
fi
# The incoming directory is disposable. The live machine files are not.
if [[ $phase == prepare ]]; then
  mkdir -p -m 700 "$state/incoming"
  # A previous interrupted upload is disposable; already committed files are not.
  rm -f -- "$state/incoming/machine.nix" "$state/incoming/facter.json"
  exit 0
fi
[[ $phase == finish ]] || fail 'unknown phase'
[[ -f $state/incoming/machine.nix && ! -L $state/incoming/machine.nix ]] || fail 'missing machine.nix upload'
for name in machine.nix facter.json; do
  src="$state/incoming/$name"
  if [[ ! -e $src ]]; then
    [[ ! -e $machine/$name && ! -L $machine/$name ]] || fail "unexpected existing $name"
    continue
  fi
  [[ -f $src && ! -L $src ]] || fail 'invalid uploaded file'
  if [[ -e $machine/$name || -L $machine/$name ]]; then
    [[ -f $machine/$name && ! -L $machine/$name ]] && cmp -s "$src" "$machine/$name" || fail "different existing $name"
  fi
done
# Fetch before changing any durable state. A branch may advance after install;
# the installed commit must still be in its ancestry. Checkout the receipt's
# commit, not the latest branch head (which may enable updates too early).
if [[ ! -e $repo ]]; then
  rm -rf -- "$state/checkout.tmp"
  git clone --no-checkout --single-branch --branch "$branch" -- "$url" "$state/checkout.tmp"
  git -C "$state/checkout.tmp" merge-base --is-ancestor "$rev" "origin/$branch" || fail 'installed commit not on fetched branch'
  git -C "$state/checkout.tmp" checkout --detach "$rev"
  chmod 700 "$state/checkout.tmp"
  mkdir -p "$(dirname "$repo")"
  [[ ! -e $repo && ! -L $repo ]] || fail 'checkout appeared during bootstrap'
  mv -- "$state/checkout.tmp" "$repo"
fi
mkdir -p -m 700 "$machine"
[[ $(stat -c %a "$machine") == 700 ]] || fail 'private machine directory must be mode 700'
for name in machine.nix facter.json; do
  [[ -f $state/incoming/$name ]] || continue
  if [[ ! -e $machine/$name ]]; then
    cp -- "$state/incoming/$name" "$machine/$name.tmp"
    chmod 600 "$machine/$name.tmp"
    mv -n -- "$machine/$name.tmp" "$machine/$name"
  fi
done
# Bootstrap defaults to a pin: the timer is active but cannot update until
# an explicit deployment/transition selects a branch.
printf 'commit:%s\n' "$rev" >"$state/selector.tmp"
chmod 600 "$state/selector.tmp"
mv -- "$state/selector.tmp" "$state/selector"
printf '%s\n' "$rev" >"$state/revision.tmp"
chmod 600 "$state/revision.tmp"
mv -- "$state/revision.tmp" "$state/revision"
rm -rf -- "$state/incoming"
printf 'Bootstrapped installed revision %s; timer policy unchanged\n' "$rev"
}

# @cmd Prepare a retryable incoming upload (internal, target-side)
# @arg url! <URL> Consumer Git origin
# @arg rev! <REV> Installed commit
# @arg repo! <PATH> Target checkout
# @arg machine! <PATH> Private machine directory
# @arg state! <PATH> Root-only state
# @arg branch! <BRANCH> Installed branch
prepare() { bootstrap_remote prepare "$@"; }

# @cmd Verify and commit a completed upload (internal, target-side)
# @arg url! <URL> Consumer Git origin
# @arg rev! <REV> Installed commit
# @arg repo! <PATH> Target checkout
# @arg machine! <PATH> Private machine directory
# @arg state! <PATH> Root-only state
# @arg branch! <BRANCH> Installed branch
finish() { bootstrap_remote finish "$@"; }

# ARGC-BUILD {
# This block was generated by argc (https://github.com/sigoden/argc).
# Modifying it manually is not recommended

_argc_run() {
    if [[ "${1:-}" == "___internal___" ]]; then
        _argc_die "error: unsupported ___internal___ command"
    fi
    if [[ "${OS:-}" == "Windows_NT" ]] && [[ -n "${MSYSTEM:-}" ]]; then
        set -o igncr
    fi
    argc__args=("$(basename "$0" .sh)" "$@")
    argc__positionals=()
    _argc_index=1
    _argc_len="${#argc__args[@]}"
    _argc_tools=()
    _argc_parse
    if [ -n "${argc__fn:-}" ]; then
        $argc__fn "${argc__positionals[@]}"
    fi
}

_argc_usage() {
    cat <<-'EOF'
Internal root-only bootstrap protocol. Never installs disks.

USAGE: bootstrap-remote <COMMAND>

COMMANDS:
  prepare  Prepare a retryable incoming upload (internal, target-side)
  finish   Verify and commit a completed upload (internal, target-side)
EOF
    exit
}

_argc_version() {
    echo bootstrap-remote 0.0.0
    exit
}

_argc_parse() {
    local _argc_key _argc_action
    local _argc_subcmds="prepare, finish"
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage
            ;;
        --version | -version | -V)
            _argc_version
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        prepare)
            _argc_index=$((_argc_index + 1))
            _argc_action=_argc_parse_prepare
            break
            ;;
        finish)
            _argc_index=$((_argc_index + 1))
            _argc_action=_argc_parse_finish
            break
            ;;
        help)
            local help_arg="${argc__args[$((_argc_index + 1))]:-}"
            case "$help_arg" in
            prepare)
                _argc_usage_prepare
                ;;
            finish)
                _argc_usage_finish
                ;;
            "")
                _argc_usage
                ;;
            *)
                _argc_die "error: invalid value \`$help_arg\` for \`<command>\`"$'\n'"  [possible values: $_argc_subcmds]"
                ;;
            esac
            ;;
        *)
            _argc_die "error: \`bootstrap-remote\` requires a subcommand but one was not provided"$'\n'"  [subcommands: $_argc_subcmds]"
            ;;
        esac
    done
    if [[ -n "${_argc_action:-}" ]]; then
        $_argc_action
    else
        _argc_usage
    fi
}

_argc_usage_prepare() {
    cat <<-'EOF'
Prepare a retryable incoming upload (internal, target-side)

USAGE: bootstrap-remote prepare <URL> <REV> <PATH> <PATH> <PATH> <BRANCH>

ARGS:
  <URL>     Consumer Git origin
  <REV>     Installed commit
  <PATH>    Target checkout
  <PATH>    Private machine directory
  <PATH>    Root-only state
  <BRANCH>  Installed branch
EOF
    exit
}

_argc_parse_prepare() {
    local _argc_key _argc_action
    local _argc_subcmds=""
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage_prepare
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        *)
            argc__positionals+=("$_argc_item")
            _argc_index=$((_argc_index + 1))
            ;;
        esac
    done
    if [[ -n "${_argc_action:-}" ]]; then
        $_argc_action
    else
        argc__fn=prepare
        if [[ "${argc__positionals[0]:-}" == "help" ]] && [[ "${#argc__positionals[@]}" -eq 1 ]]; then
            _argc_usage_prepare
        fi
        _argc_match_positionals 0 0 0 0 0 0
        local values_index values_size
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[0]:-}"
        if [[ -n "$values_index" ]]; then
            argc_url="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<URL>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[1]:-}"
        if [[ -n "$values_index" ]]; then
            argc_rev="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<REV>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[2]:-}"
        if [[ -n "$values_index" ]]; then
            argc_repo="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[3]:-}"
        if [[ -n "$values_index" ]]; then
            argc_machine="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[4]:-}"
        if [[ -n "$values_index" ]]; then
            argc_state="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[5]:-}"
        if [[ -n "$values_index" ]]; then
            argc_branch="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<BRANCH>\` were not provided"
        fi
    fi
}

_argc_usage_finish() {
    cat <<-'EOF'
Verify and commit a completed upload (internal, target-side)

USAGE: bootstrap-remote finish <URL> <REV> <PATH> <PATH> <PATH> <BRANCH>

ARGS:
  <URL>     Consumer Git origin
  <REV>     Installed commit
  <PATH>    Target checkout
  <PATH>    Private machine directory
  <PATH>    Root-only state
  <BRANCH>  Installed branch
EOF
    exit
}

_argc_parse_finish() {
    local _argc_key _argc_action
    local _argc_subcmds=""
    while [[ $_argc_index -lt $_argc_len ]]; do
        _argc_item="${argc__args[_argc_index]}"
        _argc_key="${_argc_item%%=*}"
        case "$_argc_key" in
        --help | -help | -h)
            _argc_usage_finish
            ;;
        --)
            _argc_dash="${#argc__positionals[@]}"
            argc__positionals+=("${argc__args[@]:$((_argc_index + 1))}")
            _argc_index=$_argc_len
            break
            ;;
        *)
            argc__positionals+=("$_argc_item")
            _argc_index=$((_argc_index + 1))
            ;;
        esac
    done
    if [[ -n "${_argc_action:-}" ]]; then
        $_argc_action
    else
        argc__fn=finish
        if [[ "${argc__positionals[0]:-}" == "help" ]] && [[ "${#argc__positionals[@]}" -eq 1 ]]; then
            _argc_usage_finish
        fi
        _argc_match_positionals 0 0 0 0 0 0
        local values_index values_size
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[0]:-}"
        if [[ -n "$values_index" ]]; then
            argc_url="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<URL>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[1]:-}"
        if [[ -n "$values_index" ]]; then
            argc_rev="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<REV>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[2]:-}"
        if [[ -n "$values_index" ]]; then
            argc_repo="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[3]:-}"
        if [[ -n "$values_index" ]]; then
            argc_machine="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[4]:-}"
        if [[ -n "$values_index" ]]; then
            argc_state="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<PATH>\` were not provided"
        fi
        IFS=: read -r values_index values_size <<<"${_argc_match_positionals_values[5]:-}"
        if [[ -n "$values_index" ]]; then
            argc_branch="${argc__positionals[values_index]}"
        else
            _argc_die "error: the required environments \`<BRANCH>\` were not provided"
        fi
    fi
}

_argc_match_positionals() {
    _argc_match_positionals_values=()
    _argc_match_positionals_len=0
    local params=("$@")
    local args_len="${#argc__positionals[@]}"
    if [[ $args_len -eq 0 ]]; then
        return
    fi
    local params_len=$# arg_index=0 param_index=0
    while [[ $param_index -lt $params_len && $arg_index -lt $args_len ]]; do
        local takes=0
        if [[ "${params[param_index]}" -eq 1 ]]; then
            if [[ $param_index -eq 0 ]] &&
                [[ ${_argc_dash:-} -gt 0 ]] &&
                [[ $params_len -eq 2 ]] &&
                [[ "${params[$((param_index + 1))]}" -eq 1 ]] \
                ; then
                takes=${_argc_dash:-}
            else
                local arg_diff=$((args_len - arg_index)) param_diff=$((params_len - param_index))
                if [[ $arg_diff -gt $param_diff ]]; then
                    takes=$((arg_diff - param_diff + 1))
                else
                    takes=1
                fi
            fi
        else
            takes=1
        fi
        _argc_match_positionals_values+=("$arg_index:$takes")
        arg_index=$((arg_index + takes))
        param_index=$((param_index + 1))
    done
    if [[ $arg_index -lt $args_len ]]; then
        _argc_match_positionals_values+=("$arg_index:$((args_len - arg_index))")
    fi
    _argc_match_positionals_len=${#_argc_match_positionals_values[@]}
    if [[ $params_len -gt 0 ]] && [[ $_argc_match_positionals_len -gt $params_len ]]; then
        local index="${_argc_match_positionals_values[params_len]%%:*}"
        _argc_die "error: unexpected argument \`${argc__positionals[index]}\` found"
    fi
}

_argc_die() {
    if [[ $# -eq 0 ]]; then
        cat
    else
        echo "$*" >&2
    fi
    exit 1
}

_argc_run "$@"

# ARGC-BUILD }
