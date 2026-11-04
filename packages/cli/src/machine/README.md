# `moss machine`

The public machine CLI plans and applies installs or same-branch updates, then bootstraps the installed host. Repair (`fix`) is a future capability, **not an available command**. The command folders own the implementation: `plan/` captures observations and builds proposals; `apply/` runs validated effects; `bootstrap/` performs the operator handoff and its separate root-only `remote.sh`; `update/`, `transition/` and `adopt/` hold target and migration logic. Common probe/staging/selector gates and the argc dispatch live in `deploy.sh`. Its `# @include` markers assemble these command bodies into one standalone `bin/machine/deploy.sh` before argc builds it, because the target receives only that script over SSH. No runtime sourcing of project files on the target is required.

`update.nix` is the scheduled updater module and refers to the generated deploy script. No legacy manifest author or positional operator compatibility layer is shipped. `plan/inputs.sh` validates ephemeral data created by the public planner; it is not an operator configuration format. Edit the sources and regenerate; do not expose private SSH commands through the web app.

## How machine changes work

A consumer repo defines its NixOS system; the CLI supplies reviewed machine facts, builds that committed source and either installs to an explicitly selected disk or switches an existing machine. The consumer pins this toolkit in its `flake.lock`. Keep credentials out of `machine.nix` and `facter.json`: Nix store inputs can be world-readable. A receipt and recorded revision are evidence of an operation, not proof of a safe boot.

## Deploy a machine

> ⚠️ Only applying an **install** plan erases a disk. Test on a disposable VM first; no real server has been validated. Never reinstall to repair bootstrap or adopt a running host.

### Principles

1. **Verify before acting.** Confirm SSH keys through the provider console, check the whole disk, and deploy a reviewed, pushed commit.
2. **Keep secrets out of Nix.** `machine.nix` and `facter.json` may enter the world-readable store. Keep credentials in a separate recovery tree or private target state.
3. **Preserve evidence.** Back up original machine facts and receipts off-host. A mismatch stops the process; neither install nor adoption repairs it silently.

**Who owns what?**

- **Consumer:** machine generation, supported hardware, Disko and applications, SSH keys, recovery files, evaluated checks, branch and update policy.
- **Toolkit:** re-probe, stage, require typed erase confirmation, invoke the sole installer, bootstrap.

See [manual agentic](../../../../examples/agentic.nix) and [scheduled relay](../../../../examples/thepeer.nix).

### Install `moss` on your operator computer

Pick and review a **full 40-character commit SHA**. This one-line install command downloads that revision's archive, extracts the complete CLI `bin/` tree under `~/.local/share/moss/`, and creates a launcher in `~/.local/bin/`:

```bash
MOSS_REV=REPLACE_WITH_REVIEWED_40_CHARACTER_SHA
mkdir -p "$HOME/.local/share/moss/$MOSS_REV" "$HOME/.local/bin" && curl -fLsS "https://github.com/benjaminpreiss/themoss.net/archive/$MOSS_REV.tar.gz" -o "$HOME/.local/share/moss/$MOSS_REV.tar.gz" && tar -xzf "$HOME/.local/share/moss/$MOSS_REV.tar.gz" -C "$HOME/.local/share/moss/$MOSS_REV" --strip-components=3 "themoss.net-$MOSS_REV/packages/cli/bin" && printf '#!/bin/sh\nexec "%s/bin/moss" "$@"\n' "$HOME/.local/share/moss/$MOSS_REV" >"$HOME/.local/bin/moss" && chmod 755 "$HOME/.local/bin/moss"
```

Ensure `~/.local/bin` is on `PATH`, then run `moss machine plan --help`. **Do not copy or symlink only `moss`:** plan/apply need the adjacent `bin/machine/deploy.sh`, and bootstrap also needs `bin/machine/bootstrap/remote.sh`. This downloads scripts but does not execute any downloaded code during installation. Review the pinned commit before using its CLI; `moss machine apply` can erase a disk. The CLI still needs `nix`, `nixos-anywhere`, `jq`, SSH and GNU tools; the pinned `.#operator` shell below provides them. Keep private configuration and plans on this operator computer, not on the target.

### Operator environment

**Linux or macOS:** install Nix with flakes enabled. If using a checkout, check out a reviewed toolkit commit and verify its committed `flake.lock`, then enter the operator shell:

```bash
nix develop --no-write-lock-file .#operator
bash tests/operator-smoke.sh
```

If you installed from the archive instead of checking out the repo, use `nix develop "github:benjaminpreiss/themoss.net/$MOSS_REV#operator"` for the matching runtime tools (`tests/operator-smoke.sh` is only available in a checkout). The pinned operator shell supplies GNU `stat`, `tar`, `sha256sum` and `nixos-anywhere`, rather than relying on macOS system utilities. It does not include argc; contributors use `.#dev` to regenerate or verify the standalone scripts. On macOS, configure a **Linux Nix builder** for the NixOS pre-build (`nix build`) before installation; building a Linux closure locally on macOS is not supported. A Linux VM with Nix is an alternative if you cannot provide a builder. Keep private inputs outside Git and the Nix store.

> 🧪 The smoke test mocks SSH and the installer. Linux CI tests the pinned shell; **native macOS still needs operator validation**. Target-side updates remain Linux-only.

### Fresh install: the public CLI

> 🛑 Verify the rescue SSH host key via the provider console first. Keep configuration, plans and receipts private and off-host. Prepare a credential-free `/private/machine/machine.nix` and push the exact reviewed consumer revision.

Write one mode-600, off-host desired machine configuration (never commit or stage it):

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

The configuration is operator-owned data, not a shell script or a copy of the Nix machine definition. `machine.nix` and the pinned Git commit define the desired OS. Neither a target nor a physical disk is selected by this JSON; the CLI requires those explicitly. The configuration stays off-host; the tool does not copy it to the target. Optional fields `reportGenerator`, `recoveryDir` and `preEraseCheck` are described below.

```bash
# Reads the verified rescue target, selects a whole disk, stages and builds
# the exact pushed revision, runs the consumer evaluated check, and publishes
# a mode-600 install plan. No disk operation is executed.
moss machine plan root@HOST \
  --config /private/machine.json --disk /dev/vda --output /private/install-plan.json

# Rechecks the inputs, branch tip and live hardware. You must type ERASE
# /dev/vda before it rechecks again and runs the disk installer.
moss machine apply /private/install-plan.json

# Verify the NEW installed SSH host key via the provider console first.
# A receipt exists only after the installer succeeds; bootstrap never erases.
moss machine bootstrap /private/install-receipt.json \
  --config /private/machine.json
```

**Review the plan output**: target, architecture, NIC/MAC, whole-disk path/size/model/serial, exact pushed tip, NixOS output and consumer policy paths. Planning builds the staged system and invokes the consumer's `preEraseCheck` when configured, but does **not** itself render a full Disko layout diff; the consumer must make evaluated storage/boot/network effects visible in its check. Neither the saved plan nor the JSON authorizes erasure. `apply` rebuilds, reruns the consumer check and requires typed confirmation; it re-probes and verifies the pushed tip immediately before the installer. If any source input or observed disk identity differs, make a new plan.

Back up `/private/install-receipt.json` off-host: it binds the target, origin, revision and machine hashes. If installation succeeds but the receipt is missing, **stop and inspect via console**—never reinstall to make a receipt. Bootstrap writes root-only known-good state last; retry it on interruption, never retry install to repair bootstrap. Polling fails closed until bootstrap completes. For an existing host, omit `--disk` and use `plan`/`apply` for a same-branch reviewed update; [update rules](#updates-and-recovery) still apply.

#### Consumer policy hooks

Only values and consumer-owned policy vary; no app-specific keys are accepted. Optional fields are `reportGenerator`, `recoveryDir` and `preEraseCheck` (omit them when unused, rather than entering `-`):

| Field | Consumer-owned contract |
| --- | --- |
| `reportGenerator` | Executable receiving `TARGET OUTPUT_PATH`; writes a JSON hardware report. The toolkit saves it as `machine/facter.json` and refuses to replace an existing report. Back it up. |
| `recoveryDir` | Private, root-relative `nixos-anywhere --extra-files` tree, e.g. `etc/ssh/ssh_host_ed25519_key` (mode 600). Never staged in the flake. No symlinks. |
| `preEraseCheck` | Executable receiving `STAGED_FLAKE HOST_OUTPUT RECORD` after build. Compare *evaluated* Disko, boot and network choices with the record; nonzero exit stops before confirmation. Configure it when consumer policy requires it—the toolkit cannot infer that policy. |

> 🔒 **No secret contents in the JSON or store-bound files.** `machine.nix` and `facter.json` enter the world-readable Nix store. Review them and the evaluated configuration for credentials; the toolkit cannot detect every secret. Keep SSH keys in the separate recovery tree.

#### Other machine lifecycles

The current public CLI deliberately refuses changing the selected branch or baseline, adopting an existing installation, or replacing a disk. These require separately designed evidence, review and authorization interfaces. Do not edit a receipt or root-owned state to bypass a refusal. Internal target-side polling and SSH protocol are not operator commands.

## Updates and recovery

A machine can stay on one commit or follow one branch. The update timer is **always active**; the choice is stored on the host, outside the source it fetches.

| Selection | When the timer fires |
| --- | --- |
| `commit:FULL_SHA` | 🔒 Nothing: no fetch, build or switch. |
| `branch:NAME` | 🔎 Check *only that branch*. If its tip is unchanged, do nothing. |

Bootstrap starts with a commit pin. **No push can update the machine until an operator explicitly chooses a branch.** For example, following `branch:candidate` ignores pushes to `main`.

> ⚠️ **Tracking a branch trusts future pushes to that branch as potential OS updates.** Protect it with your own review and checks. A successful build does not prove a safe boot.

### Plan and apply a same-branch manual update

After bootstrap, the host starts pinned. A separately reviewed transition must first select branch tracking; `plan` must **not** change that policy or choose a replacement branch. Update the `revision` in your private off-host configuration to the current pushed tip of that same selected branch, then:

```bash
moss machine plan root@HOST --config /private/machine.json --output /private/update-plan.json
moss machine apply /private/update-plan.json
```

With an existing install receipt and no `--disk`, `plan` observes root-owned selector and revision, fetches only the selected branch and builds the exact candidate on the installed host. It saves a mode-600 `type: update` plan; no installer is called. `apply` rechecks the selector, recorded revision, target Git origin, private machine input hash, ancestry and exact branch tip while holding the update lock; it builds before switching. A changed tip or selector stops rather than deploying an unreviewed revision. Branch divergence and manual changes to the private machine input need a separate reviewed transition, not an update plan.

The scheduled timer uses the internal safe update implementation without requiring an off-host operator plan. It never runs Disko. A public transition or recovery plan is **not implemented**.

### Internal target-side selection protocol

The following private commands are for target-side policy maintenance, **not** the public operator CLI. Run them as root on the target, using its root-owned consumer checkout and private machine directory:

```bash
# Keep the machine pinned to a full commit already in the local checkout.
bash packages/cli/bin/machine/deploy.sh deploy REPO commit:FULL_SHA MACHINE_DIR HOST_OUTPUT STATE_DIR

# Follow the current pushed tip of a reviewed branch.
bash packages/cli/bin/machine/deploy.sh deploy REPO branch:candidate MACHINE_DIR HOST_OUTPUT STATE_DIR
```

A commit pin may be an unmerged candidate. A later *explicit* branch transition could replace it; review that change carefully.

For a branch, deployment fetches only the selected tip, verifies that it descends from the installed revision, builds it and checks **again** that the tip has not moved before switching. If it moved, retry rather than installing a different commit. Even a selector change with an unchanged tip requires a successful switch.

The timer runs the same branch checks through `poll`; you can also invoke it manually:

```bash
bash packages/cli/bin/machine/deploy.sh poll REPO MACHINE_DIR HOST_OUTPUT STATE_DIR
```

### Change branches after a squash or rebase

Ordinary polling **refuses divergent history**. Do not edit the recorded revision to make it pass. Instead, review the new tip and a credential-free `machine.nix`, then use the explicit, non-destructive transition:

```bash
bash packages/cli/bin/machine/deploy.sh transition INSTALL_RECEIPT root@HOST REMOTE_REPO BRANCH REVIEWED_MACHINE_DIR REMOTE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Transition verifies the install receipt against target state, builds the proposed branch tip with the reviewed machine file, rechecks the tip and switches **without Disko**. Only after a successful switch does it save the new machine file, selector and revision. A receipt-bound transition cannot be repeated after its baseline changes; a later rebaseline needs another reviewed procedure.

### If an update fails

- **Fetch, validation or build failed?** The running generation and recorded selection/revision stay unchanged.
- **Switch started, then failed?** Services may be partly activated. The toolkit leaves `STATE_DIR/needs-inspection` to block further automation.

For an uncertain switch:

- [ ] Stop the timer and inspect `journalctl -u themoss-update -n 100`, `nixos-rebuild list-generations`, the running system and both state files.
- [ ] Recover or roll back through SSH or the provider console. **NixOS generations are not off-host backups.**
- [ ] Only after confirming the recorded selector and revision match the recovered generation, remove `needs-inspection` and resume.

#### Who owns the state?

`STATE_DIR` must be root-owned and mode `0700`. It holds `selector` (mode `0600`), `revision` (the last successfully switched full SHA), a shared operation lock and, when needed, `needs-inspection`. Keep it **outside the fetched checkout and Nix store**. Polls, deployments and transitions serialize; none repartitions disks or overwrites secrets. Keep credentials out of staged `machine.nix` and `facter.json`—Nix store inputs can be world-readable.

The consumer owns branch protection, timer cadence, private machine generation, credentials and CI policy. Pin the toolkit separately in the consumer's `flake.lock`; a webhook-supplied SHA is *not* deployment authority. For dependency-update PRs rather than host polling, see the [reusable workflow](../../../../.github/workflows/lock-updates.yml) and [App permissions](../../../github-app-audit/README.md).
