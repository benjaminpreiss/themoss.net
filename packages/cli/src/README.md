# Editable CLI source

Edit `moss.sh` for shared public helpers and `machine/plan/cli.sh`, `machine/apply/cli.sh`, and `machine/bootstrap/cli.sh` for public commands. `machine/` also holds the installer, updater and remote protocol implementation; see its README. Do not add target-side protocol verbs to the public `moss machine` tree.

`# @include` markers are expanded by `packages/cli/assemble.sh` **at generation time**, not sourced from the target at runtime. Run `bash packages/cli/regenerate.sh` at the repository root, then `bash tests/argc.sh` and `bash tests/test.sh`. `bin/` contains standalone generated executables, not second implementations.
