# `moss` CLI

`moss machine` guides first-use configuration, then plans, applies and bootstraps NixOS installs and updates. See the [machine guide](src/machine/README.md) before applying a plan: **install can erase a disk**. Repair (`fix`) is not available yet.

## Install the latest CLI

Run this on your **operator computer** to install the latest CLI from `main`:

```bash
mkdir -p "$HOME/.local/bin" && curl -fsSL https://github.com/benjaminpreiss/themoss.net/archive/refs/heads/main.tar.gz | tar -xz -C "$HOME/.local/bin" --strip-components=4 themoss.net-main/packages/cli/bin
```

Ensure `~/.local/bin` is on your `PATH`, then try `moss machine plan --help`. This installs **all** of `bin/`, not just `moss`: it needs its adjacent private scripts. Running the command again replaces the installed CLI with the latest `main`. Review the version before any real installation; `main` is a moving ref.

## Before operating a machine

Start with [`moss init`](src/init/README.md) to prepare operator-local storage, then follow the [machine guide](src/machine/README.md#operator-environment) for runtime requirements and safety checks. For command flags, see the [generated CLI reference](../../docs/cli-reference.md). The unrelated [GitHub App audit](../github-app-audit/README.md) is a separate package.

**Contributing?** See [DEVELOP.md](DEVELOP.md) for the `src/` → `bin/` build, generated specs and checks.
