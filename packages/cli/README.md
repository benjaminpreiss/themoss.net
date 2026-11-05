# `moss` CLI

`moss machine` plans, applies and bootstraps NixOS installs and updates. See the [machine guide](src/machine/README.md) before applying a plan: **install can erase a disk**. Repair (`fix`) is not available yet.

## Install the latest CLI

After this PR reaches `main`, run this on your **operator computer**:

```bash
mkdir -p "$HOME/.local/bin" && curl -fsSL https://github.com/benjaminpreiss/themoss.net/archive/refs/heads/main.tar.gz | tar -xz -C "$HOME/.local/bin" --strip-components=4 themoss.net-main/packages/cli/bin
```

Ensure `~/.local/bin` is on your `PATH`, then try `moss machine plan --help`. This installs **all** of `bin/`, not just `moss`: it needs its adjacent private scripts. Running the command again replaces the installed CLI with the latest `main`. Review the version before any real installation; `main` is a moving ref.

## Requirements

- `bash`, `curl` and `tar` for the download; GNU coreutils, `git`, `jq`, SSH, Nix and `nixos-anywhere` for machine operations.
- A Linux or macOS operator computer. The [machine guide](src/machine/README.md#operator-environment) explains the pinned Nix shell and macOS Linux-builder requirement.
- Private configuration and receipts **off the target**. See [plan, apply and bootstrap](src/machine/README.md#install-a-machine) for disk and SSH-key checks.

For command flags, see the [generated CLI reference](../../docs/cli-reference.md). The unrelated [GitHub App audit](../github-app-audit/README.md) is a separate package.

**Contributing?** See [DEVELOP.md](DEVELOP.md) for the `src/` → `bin/` build, generated specs and checks.
