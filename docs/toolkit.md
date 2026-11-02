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

The four Bash entry points (`deploy.sh`, `bootstrap-remote.sh`, `audit-app.sh`, `new-operator-manifest.sh`) are **standalone argc builds** committed in `toolkit/`. They do **not** need argc at runtime, including when the scripts are streamed to the target over SSH. Their annotated definitions live in [`toolkit/source/`](../toolkit/source/); change those, not the generated scripts. Positional commands used by existing pinned consumers remain supported. The internal SSH commands are visible in generated help/spec but must not be run by operators.

Inside the [pinned operator shell](deployment.md#operator-environment):

```bash
bash toolkit/deploy.sh --help
bash toolkit/deploy.sh manifest install --help
argc --argc-export toolkit/source/deploy.sh > /private/deploy-cli-spec.json
# Optional: argc --argc-mangen toolkit/source/deploy.sh /private/man
bash toolkit/regenerate-cli.sh # rebuild Bash, JSON specs, and Markdown reference
bash tests/argc.sh
bash tests/test.sh
```

`--argc-export` produces JSON **from the same argc annotations as parsing and help**; [`render-cli-reference.sh`](../toolkit/render-cli-reference.sh) turns the four exported JSON trees into Markdown. Both artifacts live in this repo and are checked for drift in the GitHub **Toolkit checks** job (`tests/consumer-commands.sh` runs `tests/argc.sh` inside the pinned operator shell). Use the JSON to inspect command names and positional parameters.

**Contributors:** run `npm ci` once to install the Husky pre-commit hook (Node/npm are development-only, not operator or target dependencies). The hook runs `npm run check:generated` and refuses to commit unstaged CLI source/generated changes. You can run that command yourself before a PR. CI runs the same generation check independently, so commits made without the hook are still checked. If the hook reports drift, use `nix develop --no-write-lock-file .#operator`, run `bash toolkit/regenerate-cli.sh`, and stage the updated scripts, JSON and Markdown. It describes the *command interface*, not the contents of the private manifest or a proof that a command is safe: those validations remain in the toolkit's executable gates. CI checks regenerated scripts byte-for-byte against the pinned argc version. Regenerate inside the operator shell rather than using an unrelated argc release.

## Choose your next step

- **New machine?** Follow [Deploy a machine](deployment.md).
- **Existing machine or tested candidate?** Follow [Update a deployed machine](updates.md).
- **Automating dependency PRs?** Read [App permissions](app-permissions.md). The consumer owns the workflow credentials; the server does not need them.
