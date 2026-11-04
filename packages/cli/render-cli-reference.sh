#!/usr/bin/env bash
# Render the argc-exported JSON command trees; do not hand-edit the result.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
specs=${1:-$root/docs/cli-spec}
printf '# moss machine command reference\n\n'
printf '> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [deployment runbook](deployment.md), not this command list.\n'
for name in moss; do
  jq -j --arg file "$name.sh" '
    def arguments:
      (.positionals // [] | if length == 0 then "" else
        "\n| Argument | Required | Description |\n| --- | --- | --- |\n" +
        (map("| `" + (.id | ascii_upcase) + "` | " + (if .required then "yes" else "no" end) + " | " + (.describe // "") + " |") | join("\n")) + "\n" end);
    def render($path; $level):
      . as $cmd |
      ("\n" + ("#" * $level) + " `" + $path + "`\n\n" + ($cmd.describe // "") + "\n" + arguments) +
      ([ $cmd.subcommands[]? | render($path + " " + .name; $level + 1) ] | join(""));
    render("bash packages/cli/" + $file; 2)
  ' "$specs/$name.json"
done
