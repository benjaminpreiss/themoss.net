# `moss` CLI

**`moss machine`** plans and applies reviewed NixOS installs or updates, then bootstraps new installations. [Install the CLI and follow the machine guide](src/machine/README.md), or look up flags in the [generated command reference](../../docs/cli-reference.md). Repair (`fix`) is **planned, not shipped**.

| What you need | Where to go |
| --- | --- |
| Operator install, disk safety or recovery | [Machine guide](src/machine/README.md) |
| Public command arguments | [Generated reference](../../docs/cli-reference.md) |
| Unrelated App permission checks | [GitHub App audit](../github-app-audit/README.md) |

## Source → build → executable

1. Edit [`src/`](src/README.md), not [`bin/`](bin/README.md). Command fragments are assembled at build time.
2. From the repository root, run `bash packages/cli/build.sh` to produce standalone executables, JSON specs and the Markdown reference.
3. Run `bash tests/argc.sh` to check the committed builds byte for byte. Keep the *whole* CLI package at the same revision: `bin/moss` invokes its adjacent private `bin/machine/deploy.sh`.

The pinned `.#operator` shell supplies runtime tools **without argc**; `.#dev` adds argc for generation and verification. To opt into the Bash pre-commit hook, run `git config core.hooksPath .githooks` (this setting is shared across linked worktrees).

> ⚠️ **Workflow maintenance:** [CI](../../.github/workflows/ci.yml) and [App audit](../../.github/workflows/lock-updates.yml) use the new layout. The [generation workflow](../../.github/workflows/generate-cli-docs) lacks a `.yml` extension and does **not** run; a maintainer must rename it to `.github/workflows/generate-cli-docs.yml`. This GitHub App cannot change workflow files.
