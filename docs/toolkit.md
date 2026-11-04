# How the toolkit fits together

**Your consumer repo describes the machine. This toolkit helps install and update it.** It does not supply a disk layout, an application, credentials or a release schedule.

```text
consumer repo + reviewed machine facts
                │
                ▼
        Nix builds a NixOS system
                │
        ┌───────┴────────┐
        ▼                ▼
  install on a       switch an existing
  new disk           machine (no Disko)
```

## What happens when you run a command?

| Command | In plain language | Nix's role |
| --- | --- | --- |
| `discover` / `preflight` | Record and recheck the target's disk and hardware. **No changes.** | None. |
| `install` | Check the pushed commit, build it, ask for typed disk confirmation, then install it. **Erases the chosen disk.** | Build the consumer's NixOS output; `nixos-anywhere` installs it. |
| `bootstrap` | After you verify the **new SSH host key**, put the installed commit and reviewed machine facts on the target. **No disk install.** | None; this prepares future builds. |
| `deploy` / `poll` / `transition` | Select a commit pin or a branch, check its tip, build and switch when eligible. **No disk install.** | Build the new NixOS output; `nixos-rebuild switch` activates it. |

**Transition explicitly changes a reviewed branch baseline and private machine file.** The timer is always active; bootstrap pins the installed commit so polling is a no-op until a reviewed branch selection.

## What makes a build reproducible?

The consumer pins this toolkit by an **immutable flake commit** and commits its own `flake.lock`. Install and update build *committed* consumer source with reviewed `machine.nix` (and optional `facter.json`) staged alongside it. They do not build arbitrary uncommitted edits or update the lockfile on the host.

> 🔒 **Machine facts are not secrets.** Even when stored in root-only files, inputs to a Nix build can end up in the world-readable Nix store. Keep tokens, private keys and password hashes out of them.

The Git checkout and root-only selector/revision state live outside the Nix store. Bootstrap pins the **installed commit**; later switches record the **last successfully switched commit**. Neither is a promise that the host has passed a reboot or health check. A failed fetch or build cannot advance it; a failed switch needs operator inspection.

## CLI help, JSON spec and generated reference

For every command and argument, see the [generated Markdown command reference](cli-reference.md). The equivalent [JSON command specs](cli-spec/) are committed alongside it. Keep the runbooks for **review decisions and failure recovery**—a command schema cannot establish those safeguards.

The public [`bin/moss`](../packages/cli/bin/moss) and private machine scripts in [`bin/machine/`](../packages/cli/bin/machine/) are **standalone argc builds**. They do not need argc at runtime, including when scripts are streamed to the target over SSH. Edit [`packages/cli/src/moss.sh`](../packages/cli/src/moss.sh) or [`packages/cli/src/machine/`](../packages/cli/src/machine/), never generated files. The unrelated [GitHub App audit](../packages/github-app-audit/) has its own source and generated executable. The positional machine protocol is strictly internal; public operators use only `moss machine`. No compatibility authoring wizard or legacy command tree is shipped. Private SSH commands are not web-app or operator commands. The package [`README.md`](../packages/cli/README.md) explains the `src/` → `bin/` build.

For operators, use the [pinned `.#operator` shell](deployment.md#operator-environment). It has the tools to run the committed executable, **not argc**:

```bash
nix develop --no-write-lock-file .#operator
bash packages/cli/bin/moss machine --help
bash tests/operator-smoke.sh
```

For contributors, use `.#dev`, which adds pinned argc to the same tools:

```bash
nix develop --no-write-lock-file .#dev
bash packages/cli/build.sh # build Bash, JSON specs and Markdown reference
bash tests/argc.sh
bash tests/test.sh
```

The committed [JSON specs](cli-spec/) are produced from the assembled argc sources; [`render-cli-reference.sh`](../packages/cli/helpers/render-cli-reference.sh) turns the public `moss` spec into Markdown. Both artifacts are checked for drift in the GitHub **Toolkit checks** job (`tests/consumer-commands.sh` runs `tests/argc.sh` in `.#dev`). Use the JSON to inspect command names and positional parameters.

**Contributors:** opt into the plain Bash pre-commit hook with `git config core.hooksPath .githooks` (Git stores this setting in the shared config of linked worktrees; enable it deliberately). The hook runs the pinned generation check and refuses to commit unstaged CLI source/generated changes. No npm or Node dependency is required. If it reports drift, use `nix develop --no-write-lock-file .#dev`, run `bash packages/cli/build.sh`, and stage the updated scripts, JSON and Markdown.

The GitHub App cannot update `.github/workflows/`, so [updated CI](workflow-drafts/ci.yml), [audit](workflow-drafts/lock-updates.yml) and [generation](workflow-drafts/generate-cli-docs.yml) workflow files are staged under `docs/workflow-drafts/` for a maintainer with workflow-write access to install. The current `.github/workflows/generate-cli-docs` has **no `.yml`/`.yaml` extension**, so GitHub does not run it. Until the drafts are installed, the existing CI still references pre-restructure paths. Generated command docs describe the interface, not the private configuration or proof of safety; the executable gates and runbook remain authoritative. CI compares generated scripts byte-for-byte against the pinned argc version.

## Choose your next step

- **New machine?** Follow [Deploy a machine](deployment.md).
- **Existing machine or tested candidate?** Follow [Update a deployed machine](updates.md).
- **Automating dependency PRs?** Read [App permissions](app-permissions.md). The consumer owns the workflow credentials; the server does not need them.
