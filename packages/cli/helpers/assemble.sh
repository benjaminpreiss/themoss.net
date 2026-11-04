#!/usr/bin/env bash
# Expand command-source fragments into one argc input. The installed bin/
# scripts must stay standalone: the target has no source tree or argc runtime.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: assemble.sh SOURCE DESTINATION' >&2; exit 1; }
source=$1 dest=$2
base=$(cd "$(dirname "$source")" && pwd -P)
[[ -f $source && ! -L $source ]] || { echo 'invalid argc source' >&2; exit 1; }
[[ $(realpath -m "$dest") != "$(realpath -m "$source")" ]] || { echo 'source and destination must differ' >&2; exit 1; }
: >"$dest"
while IFS= read -r line || [[ -n $line ]]; do
  if [[ $line == '# @include '* ]]; then
    relative=${line#'# @include '}
    [[ $relative =~ ^[a-zA-Z0-9_./-]+$ && $relative != /* && $relative != *..* ]] || { echo 'unsafe source fragment' >&2; exit 1; }
    fragment=$base/$relative
    [[ -f $fragment && ! -L $fragment ]] || { echo "missing source fragment: $relative" >&2; exit 1; }
    # Fragments are text, not shell-sourced at runtime. Reject recursive
    # includes so assembly order and the audited standalone output stay clear.
    if grep -q '^# @include ' "$fragment"; then echo "nested include: $relative" >&2; exit 1; fi
    while IFS= read -r part || [[ -n $part ]]; do printf '%s\n' "$part"; done <"$fragment" >>"$dest"
  else
    printf '%s\n' "$line" >>"$dest"
  fi
done <"$source"
