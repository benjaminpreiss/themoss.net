#!/usr/bin/env bash
# Export the argc command tree, omitting version-dependent empty metadata.
# Non-null author values are preserved; all command and argument data remains.
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: export-spec.sh SOURCE' >&2; exit 1; }
argc --argc-export "$1" | jq 'walk(if type == "object" and .author? == null then del(.author) else . end)'
