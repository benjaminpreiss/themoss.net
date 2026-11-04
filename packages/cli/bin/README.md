# Generated executables — do not edit

`moss` is built from `../src/moss.sh`; `machine/*.sh` are built from `../src/machine/*.sh` by `bash packages/cli/regenerate.sh`. argc embeds its parser, so these scripts run without argc installed. Keep them committed and versioned with their source; `bash tests/argc.sh` compares byte-for-byte builds and generated JSON/Markdown.

Only `moss` is a public operator command. The machine scripts are implementation/target-side protocol, not supported shell or browser entry points.
