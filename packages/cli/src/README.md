# Editable CLI source

Edit `moss.sh` to change public commands and argc annotations. `machine/` holds the installer, updater and remote protocol implementation; `machine/update.nix` imports its generated standalone deploy script. Do not add target-side protocol verbs to the public `moss machine` tree.

Run `bash packages/cli/regenerate.sh` at the repository root, then `bash tests/argc.sh` and `bash tests/test.sh`. The script under `bin/` is generated from this source, not a second implementation.
