# `moss` CLI

**`moss machine`** plans and applies reviewed NixOS installs or updates, then bootstraps new installations. Repair (`fix`) is **planned, not shipped**. For disk safety and recovery, follow the [machine guide](src/machine/README.md); for flags, see the [generated command reference](../../docs/cli-reference.md).

## Install `moss` on your operator computer

Review and pin a **full 40-character toolkit commit SHA**. Set `MOSS_REV`, then run this single-line install command. It downloads that revision's archive, extracts the *whole* CLI `bin/` tree under `~/.local/share/moss/`, and writes a launcher to `~/.local/bin/moss`:

```bash
MOSS_REV=REPLACE_WITH_REVIEWED_40_CHARACTER_SHA
mkdir -p "$HOME/.local/share/moss/$MOSS_REV" "$HOME/.local/bin" && curl -fLsS "https://github.com/benjaminpreiss/themoss.net/archive/$MOSS_REV.tar.gz" -o "$HOME/.local/share/moss/$MOSS_REV.tar.gz" && tar -xzf "$HOME/.local/share/moss/$MOSS_REV.tar.gz" -C "$HOME/.local/share/moss/$MOSS_REV" --strip-components=3 "themoss.net-$MOSS_REV/packages/cli/bin" && printf '#!/bin/sh\nexec "%s/bin/moss" "$@"\n' "$HOME/.local/share/moss/$MOSS_REV" >"$HOME/.local/bin/moss" && chmod 755 "$HOME/.local/bin/moss"
```

Ensure `~/.local/bin` is on `PATH`, then try `moss machine plan --help`. **Do not copy or symlink only `moss`:** it needs adjacent `bin/machine/deploy.sh`, and bootstrap needs `bin/machine/bootstrap/remote.sh`. The download does *not* execute the downloaded code, but using the CLI does. Review the pinned commit before running a command that can erase a disk. The CLI also needs `nix`, `nixos-anywhere`, `jq`, SSH and GNU tools; the [operator environment](src/machine/README.md#operator-environment) explains the pinned shell.

## Where to go next

| What you need | Guide |
| --- | --- |
| Plan/install, update or recover a host | [Machine guide](src/machine/README.md) |
| Public command arguments | [Generated reference](../../docs/cli-reference.md) |
| Unrelated App permission checks | [GitHub App audit](../github-app-audit/README.md) |

## Source → build → executable

1. Edit [`src/`](src/README.md), not [`bin/`](bin/README.md). Command fragments are assembled at build time.
2. From the repository root, run `bash packages/cli/build.sh` to produce standalone executables, JSON specs and the Markdown reference.
3. Run `bash tests/argc.sh` to check committed builds byte for byte. Keep the *whole* CLI package at the same revision: `bin/moss` invokes its adjacent private `bin/machine/deploy.sh`.

The pinned `.#operator` shell supplies runtime tools **without argc**; `.#dev` adds argc for generation and verification. To opt into the Bash pre-commit hook, run `git config core.hooksPath .githooks` (shared across linked worktrees).

> ⚠️ **Workflow maintenance:** [CI](../../.github/workflows/ci.yml) and [App audit](../../.github/workflows/lock-updates.yml) use the new layout. The [generation workflow](../../.github/workflows/generate-cli-docs) lacks a `.yml` extension and does **not** run; a maintainer must rename it to `.github/workflows/generate-cli-docs.yml`. This GitHub App cannot change workflow files.
