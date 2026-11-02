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

## Choose your next step

- **New machine?** Follow [Deploy a machine](deployment.md).
- **Existing machine or tested candidate?** Follow [Update a deployed machine](updates.md).
- **Automating dependency PRs?** Read [App permissions](app-permissions.md). The consumer owns the workflow credentials; the server does not need them.
