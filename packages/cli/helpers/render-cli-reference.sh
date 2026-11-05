#!/usr/bin/env bash
# build.sh exports JSON specs from argc-annotated shell sources.
# Render those specs as the Markdown CLI reference; do not hand-edit the result.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
specs=${1:-$root/docs/spec/cli}
printf '# moss machine command reference\n\n'
printf '> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#install-a-machine), not this command list.\n'
jq -j '
    def entry($name):
      "- **`" + $name + "`** (" + (if .required then "required" else "optional" end) + ")" +
      (if (.describe // "") == "" then "" else " — " + .describe end);
    def arguments:
      (.positionals // [] | if length == 0 then "" else
        "\n**Arguments**\n\n" +
        (map(entry(.id | ascii_upcase)) | join("\n")) + "\n" end);
    def options:
      ([.flag_options[]? | select(.long_name != "--help")] | if length == 0 then "" else
        "\n**Options**\n\n" +
        (map(entry(.long_name + ((.notations // []) | map(" <" + . + ">") | join("")))) | join("\n")) + "\n" end);
    def render($path; $level):
      . as $cmd |
      ("\n" + ("#" * $level) + " `" + $path + "`\n\n" + ($cmd.describe // "") + "\n" + arguments + options) +
      ([ $cmd.subcommands[]? | render($path + " " + .name; $level + 1) ] | join(""));
    render("moss"; 2)
  ' "$specs/moss.json"
