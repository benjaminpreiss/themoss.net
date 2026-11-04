# `moss` CLI

The public entry point is [`bin/moss`](bin/moss). Its `moss machine` command plans and applies reviewed NixOS installs or updates and bootstraps new installations. **Repair (`fix`) is planned, not shipped.** See the [machine guide](src/machine/README.md) for installation, commands, disk safety and recovery; see the [generated CLI reference](../../docs/cli-reference.md) for flags and arguments.

## Source and build

Edit [`src/`](src/README.md), not committed [`bin/`](bin/README.md). Run `bash packages/cli/build.sh` from the repository root to assemble command fragments, generate standalone argc executables and refresh the JSON specs and Markdown reference. `bash tests/argc.sh` checks byte-for-byte reproducibility. Keep the whole CLI package at one revision: `bin/moss` invokes its adjacent private `bin/machine/deploy.sh`. The [GitHub App audit](../github-app-audit/README.md) is a separate package.

The pinned `.#operator` shell supplies runtime tools without argc; `.#dev` adds argc for building and verifying the generated files. Contributors may opt into the Bash pre-commit hook with `git config core.hooksPath .githooks` (shared across linked worktrees); it checks that CLI sources and generated artifacts are staged together.

The [CI](../../.github/workflows/ci.yml) and [audit](../../.github/workflows/lock-updates.yml) workflows now reference this layout. The [CLI generation workflow](../../.github/workflows/generate-cli-docs) has no `.yml` extension and does not run; a maintainer must rename it to `.github/workflows/generate-cli-docs.yml` because this GitHub App cannot change workflows.
