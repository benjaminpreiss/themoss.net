# Editable CLI source

- `moss.sh` holds the public dispatcher and shared validation. Public command bodies live in `machine/plan/cli.sh`, `machine/apply/cli.sh` and `machine/bootstrap/cli.sh`.
- [`machine/`](machine/README.md) also contains private install, update and target-side protocol code. **Do not expose target protocol verbs as public `moss machine` commands.**

`# @include` fragments are expanded by `packages/cli/helpers/assemble.sh` **at build time**, not sourced on the target. From the repository root, run `bash packages/cli/build.sh`, then `bash tests/argc.sh` and `bash tests/test.sh`. The committed [`bin/`](../bin/README.md) scripts are generated artifacts, not separate implementations.
