# `moss machine`: install and update a NixOS host

Use the public `moss machine` command **on your operator computer** to plan, apply and bootstrap reviewed changes. Your consumer repository defines the OS; `moss` checks the target and committed source, builds the system and either installs to a chosen disk or switches an existing host. [Repair (`fix`) is not implemented](#what-is-not-supported-yet).

> ⚠️ **Pilot only.** No real server has been validated. Test on a disposable VM first. Applying an **install** plan erases the selected disk; applying an **update** never runs the disk installer.

| If you want to… | Start here |
| --- | --- |
| Set up the command | [Install `moss` on your computer](#install-moss-on-your-operator-computer) |
| Install a new host | [Plan → apply → bootstrap](#install-a-new-machine) |
| Update an installed host | [Review a same-branch update](#update-an-existing-machine) |
| Investigate a failure | [Recovery checklist](#if-an-update-fails) |

## Install `moss` on your operator computer

Review and pin a **full 40-character toolkit commit SHA**. Set `MOSS_REV`, then run the following single-line install command. It downloads that revision's archive, extracts the *entire* CLI `bin/` tree under `~/.local/share/moss/`, and writes a launcher to `~/.local/bin/moss`:

```bash
MOSS_REV=REPLACE_WITH_REVIEWED_40_CHARACTER_SHA
mkdir -p "$HOME/.local/share/moss/$MOSS_REV" "$HOME/.local/bin" && curl -fLsS "https://github.com/benjaminpreiss/themoss.net/archive/$MOSS_REV.tar.gz" -o "$HOME/.local/share/moss/$MOSS_REV.tar.gz" && tar -xzf "$HOME/.local/share/moss/$MOSS_REV.tar.gz" -C "$HOME/.local/share/moss/$MOSS_REV" --strip-components=3 "themoss.net-$MOSS_REV/packages/cli/bin" && printf '#!/bin/sh\nexec "%s/bin/moss" "$@"\n' "$HOME/.local/share/moss/$MOSS_REV" >"$HOME/.local/bin/moss" && chmod 755 "$HOME/.local/bin/moss"
```

Ensure `~/.local/bin` is on `PATH`, then try `moss machine plan --help`. **Do not copy or symlink only `moss`:** it needs adjacent `bin/machine/deploy.sh`, and bootstrap also needs `bin/machine/bootstrap/remote.sh`. The download does *not* execute the downloaded code, but using the CLI does. Review the pinned commit before running a command that can erase a disk. Keep private inputs, plans and receipts **off the target**.

### Runtime tools

The CLI also needs `nix`, `nixos-anywhere`, `jq`, SSH and GNU tools. On Linux or macOS, install Nix with flakes enabled and enter the pinned **operator** shell (it does not need argc):

- **Using a reviewed checkout:** verify its committed `flake.lock`, then run `nix develop --no-write-lock-file .#operator`. In that checkout, `bash tests/operator-smoke.sh` exercises SSH and installer mocks.
- **Using the archive above:** run `nix develop "github:benjaminpreiss/themoss.net/$MOSS_REV#operator"` for tools from the same toolkit revision. The smoke test is only available in a checkout.

> 🧪 Linux CI checks the pinned shell, but native macOS still needs operator validation. On macOS, configure a **Linux Nix builder** for the NixOS pre-build, or use a Linux VM; macOS cannot build a Linux closure locally. Target-side updates run on Linux only.

## Install a new machine

### Before you begin

1. Verify the **rescue SSH host key** independently through the provider console. Identify the intended *whole disk* and push the exact consumer commit you reviewed.
2. Prepare a credential-free `/private/machine/machine.nix`. Review evaluated storage, boot and network policy: this CLI cannot infer all consumer-specific choices. See [manual agentic](../../../../examples/agentic.nix) and [scheduled relay](../../../../examples/thepeer.nix).
3. Keep configuration, plans, receipts, SSH keys and recovery material private and off-host. `machine.nix` and `facter.json` may enter the **world-readable Nix store**; never put credentials in them. Back up original machine facts and receipts separately.

**Ownership:** The consumer controls Disko, hardware support, applications, credentials, evaluated checks and update policy. `moss` re-probes, stages, requires typed erase confirmation and invokes the installer only for an install plan.

Create a mode-600 configuration file *outside Git* (never commit or stage it):

```json
{
  "version": 1,
  "repo": "/work/consumer",
  "revision": "FULL_40_CHARACTER_PUSHED_COMMIT",
  "branch": "main",
  "output": "HOST_OUTPUT",
  "machine": "/private/machine",
  "receipt": "/private/install-receipt.json",
  "remoteCheckout": "/root/consumer",
  "remoteMachine": "/root/private-machine",
  "remoteState": "/var/lib/themoss",
  "preEraseCheck": "/private/check-evaluated-config"
}
```

This JSON is operator-owned **desired configuration**, not a shell script or the Nix machine definition. It stays off-host. Neither the target nor the disk is selected in the file; choose both explicitly when planning. `preEraseCheck` is optional, as are the [other consumer hooks](#consumer-owned-hooks).

### 1. Plan without erasing

```bash
moss machine plan root@HOST \
  --config /private/machine.json --disk /dev/vda --output /private/install-plan.json
```

Planning checks the rescue target, stages and builds the exact pushed revision and publishes a mode-600 plan. **Review** the target, architecture, NIC/MAC, disk path/size/model/serial, pushed tip, NixOS output and policy paths. If configured, `preEraseCheck` compares *evaluated* storage/boot/network choices with the discovery record. The CLI does **not** render a complete Disko layout diff; your consumer check must cover its policy.

### 2. Apply with explicit authorization

```bash
moss machine apply /private/install-plan.json
```

A plan is **not erase authorization**. Apply rechecks the inputs, branch tip and live disk identity, rebuilds and reruns the consumer check, then asks you to type `ERASE /dev/vda`. It checks again immediately before invoking the disk installer. If the source or disk changed, **stop and make a new plan**.

### 3. Verify the new key, then bootstrap

Verify the **new installed SSH host key** through the provider console before connecting again:

```bash
moss machine bootstrap /private/install-receipt.json --config /private/machine.json
```

Back up the receipt off-host; it binds the target, origin, revision and machine hashes. Bootstrap writes root-only known-good state *last* and never erases a disk. If interrupted, retry **bootstrap**, not install. If installation succeeded but the receipt is missing, stop and inspect through the console—**never reinstall to manufacture a receipt**. Polling fails closed until bootstrap completes.

### Consumer-owned hooks

Omit optional fields when unused (do not set them to `-`):

| Field | What the consumer supplies |
| --- | --- |
| `reportGenerator` | Executable receiving `TARGET OUTPUT_PATH`; writes a JSON hardware report to `machine/facter.json`. It cannot overwrite an existing report. Back it up. |
| `recoveryDir` | Private `nixos-anywhere --extra-files` tree, such as `etc/ssh/ssh_host_ed25519_key` (mode 600). Never stage it in the flake; no symlinks. |
| `preEraseCheck` | Executable receiving `STAGED_FLAKE HOST_OUTPUT RECORD` *after build*. Compare evaluated Disko, boot and network choices with the record; failure stops before confirmation. |

> 🔒 **Secrets stay out of store-bound files.** Review `machine.nix`, `facter.json` and the evaluated system for credentials; the CLI cannot detect every secret. Keep SSH keys in the separate recovery tree.

## Update an existing machine

A machine is either pinned to one commit or follows one branch. The scheduled timer is always active, but its root-owned selection determines what it does:

| Selection | Timer behavior |
| --- | --- |
| `commit:FULL_SHA` | 🔒 No fetch, build or switch. Bootstrap starts here. |
| `branch:NAME` | 🔎 Checks only that branch and does nothing if its tip is unchanged. |

**No push can update a newly bootstrapped machine until an operator explicitly selects a branch.** Following `branch:candidate` ignores pushes to `main`. Branch tracking trusts future pushes as potential OS updates: protect the branch with your own reviews and checks. A successful build does not prove a safe reboot.

### Review a same-branch update

A separately reviewed transition must first select branch tracking; `plan` will **not** change that policy. Set `revision` in the private off-host configuration to the current pushed tip of the *same selected branch*, then omit `--disk`:

```bash
moss machine plan root@HOST --config /private/machine.json --output /private/update-plan.json
moss machine apply /private/update-plan.json
```

With an existing install receipt, plan observes the target's root-owned selector/revision, fetches only the chosen branch and builds the exact candidate on the installed host. It saves a mode-600 `type: update` plan; **no disk installer runs**. Apply holds the update lock while rechecking the selector, recorded revision, Git origin, machine-input hash, ancestry and exact tip, then builds before switching. A moved tip or changed selector stops rather than switching to an unreviewed revision. Divergent history or changed machine input requires a separate reviewed transition. Scheduled polls use the same safe internal updater without an off-host operator plan.

### If an update fails

- **Fetch, validation or build fails:** the running generation and recorded selector/revision stay unchanged.
- **Switch starts and fails:** services may be partly activated. `STATE_DIR/needs-inspection` blocks further automation.

For an uncertain switch:

1. Stop the timer. Inspect `journalctl -u themoss-update -n 100`, `nixos-rebuild list-generations`, the running system and both state files.
2. Recover or roll back through SSH or the provider console. **NixOS generations are not off-host backups.**
3. Only after confirming that the selector and recorded revision match the recovered generation, remove `needs-inspection` and resume.

`STATE_DIR` must be root-owned and mode `0700`. It contains `selector` (mode `0600`), `revision` (last successfully switched full SHA), a shared operation lock and possibly `needs-inspection`. Keep it **outside the fetched checkout and Nix store**. Polls and deployments serialize; none repartitions disks or overwrites secrets. The consumer owns branch protection, timer cadence, private machine generation, credentials and CI policy. A webhook-supplied SHA is *not* deployment authority. For dependency-update PRs rather than host polling, see the [lock-update workflow](../../../../.github/workflows/lock-updates.yml) and [GitHub App audit](../../../github-app-audit/README.md).

## What is not supported yet

The public CLI deliberately refuses branch/baseline transitions, existing-host adoption, disk repair/replacement and restore. **`moss machine fix` does not exist yet.** These need separately reviewed evidence and authorization; do not edit a receipt or root-owned state to bypass a refusal. Internal target-side polling and SSH operations are *not* public operator commands.

<details>
<summary>Private target-side policy protocol (maintainers only)</summary>

These are implementation commands, **not** a supported public operator interface. `deploy` and `poll` run on the target as root with its root-owned checkout and private machine directory:

```bash
# Pin a full commit already in the local checkout.
bash packages/cli/bin/machine/deploy.sh deploy REPO commit:FULL_SHA MACHINE_DIR HOST_OUTPUT STATE_DIR

# Select the reviewed branch tip; polling also uses this protocol.
bash packages/cli/bin/machine/deploy.sh deploy REPO branch:candidate MACHINE_DIR HOST_OUTPUT STATE_DIR
bash packages/cli/bin/machine/deploy.sh poll REPO MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Ordinary polling refuses divergent history. Separately, an internal off-host transition can review a different branch and credential-free `machine.nix`, build the proposed tip, recheck it and switch **without Disko**:

```bash
bash packages/cli/bin/machine/deploy.sh transition INSTALL_RECEIPT root@HOST REMOTE_REPO BRANCH REVIEWED_MACHINE_DIR REMOTE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

A transition verifies the receipt against target state and saves the machine file, selector and revision only after a successful switch. It cannot be repeated once its receipt-bound baseline changes; later rebaselines need another reviewed procedure. Never rewrite the recorded revision to make a divergent history pass.

</details>

## Source and build notes

The editable `plan/`, `apply/` and `bootstrap/` folders own the public command bodies. `update/`, `transition/` and `adopt/` contain private target behavior. Common probe/staging/selector checks and argc dispatch live in `deploy.sh`; its `# @include` fragments are assembled **at build time** into standalone `bin/machine/deploy.sh`. The target needs neither argc nor project sources at runtime. `bootstrap/remote.sh` is a separate root-only helper; `update.nix` is the scheduled updater module.

`plan/inputs.sh` validates ephemeral data from the public planner, **not** a user-authored manifest. No legacy authoring wizard or public positional interface is shipped. Edit sources and run `bash packages/cli/build.sh`; do not expose private SSH commands through the web app.
