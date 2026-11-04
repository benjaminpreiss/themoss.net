# Deploy or adopt a machine

> ⚠️ Only applying an **install** plan erases a disk. Test on a disposable VM first; no real server has been validated. Never reinstall to repair bootstrap or adopt a running host.

## Principles

1. **Verify before acting.** Confirm SSH keys through the provider console, check the whole disk, and deploy a reviewed, pushed commit.
2. **Keep secrets out of Nix.** `machine.nix` and `facter.json` may enter the world-readable store. Keep credentials in a separate recovery tree or private target state.
3. **Preserve evidence.** Back up original machine facts and receipts off-host. A mismatch stops the process; neither install nor adoption repairs it silently.

**Who owns what?**

- **Consumer:** machine generation, supported hardware, Disko and applications, SSH keys, recovery files, evaluated checks, branch and update policy.
- **Toolkit:** re-probe, stage, require typed erase confirmation, invoke the sole installer, bootstrap.

See [manual agentic](../examples/agentic.nix) and [scheduled relay](../examples/thepeer.nix).

## Operator environment

**Linux or macOS:** install Nix with flakes enabled; check out a reviewed toolkit commit and verify its committed `flake.lock`. Then:

```bash
nix develop --no-write-lock-file .#operator
bash tests/operator-smoke.sh
```

The pinned shell supplies GNU `stat`, `tar`, `sha256sum` and `nixos-anywhere`, rather than relying on macOS system utilities. On macOS, configure a **Linux Nix builder** for the NixOS pre-build (`nix build`) before installation; building a Linux closure locally on macOS is not supported. A Linux VM with Nix is an alternative if you cannot provide a builder. Keep private inputs outside Git and the Nix store.

> 🧪 The smoke test mocks SSH and the installer. Linux CI tests the pinned shell; **native macOS still needs operator validation**. Target-side updates remain Linux-only.

## Fresh install: the public CLI

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
bash packages/cli/bin/moss machine plan root@HOST \
  --config /private/machine.json --disk /dev/vda --output /private/install-plan.json

# Rechecks the inputs, branch tip and live hardware. You must type ERASE
# /dev/vda before it rechecks again and runs the disk installer.
bash packages/cli/bin/moss machine apply /private/install-plan.json

# Verify the NEW installed SSH host key via the provider console first.
# A receipt exists only after the installer succeeds; bootstrap never erases.
bash packages/cli/bin/moss machine bootstrap /private/install-receipt.json \
  --config /private/machine.json
```

**Review the plan output**: target, architecture, NIC/MAC, whole-disk path/size/model/serial, exact pushed tip, NixOS output and consumer policy paths. Planning builds the staged system and invokes the consumer's `preEraseCheck` when configured, but does **not** itself render a full Disko layout diff; the consumer must make evaluated storage/boot/network effects visible in its check. Neither the saved plan nor the JSON authorizes erasure. `apply` rebuilds, reruns the consumer check and requires typed confirmation; it re-probes and verifies the pushed tip immediately before the installer. If any source input or observed disk identity differs, make a new plan.

Back up `/private/install-receipt.json` off-host: it binds the target, origin, revision and machine hashes. If installation succeeds but the receipt is missing, **stop and inspect via console**—never reinstall to make a receipt. Bootstrap writes root-only known-good state last; retry it on interruption, never retry install to repair bootstrap. Polling fails closed until bootstrap completes. For an existing host, omit `--disk` and use `plan`/`apply` for a same-branch reviewed update; [update rules](updates.md) still apply.

### Consumer policy hooks

Only values and consumer-owned policy vary; no app-specific keys are accepted. Optional fields are `reportGenerator`, `recoveryDir` and `preEraseCheck` (omit them when unused, rather than entering `-`):

| Field | Consumer-owned contract |
| --- | --- |
| `reportGenerator` | Executable receiving `TARGET OUTPUT_PATH`; writes a JSON hardware report. The toolkit saves it as `machine/facter.json` and refuses to replace an existing report. Back it up. |
| `recoveryDir` | Private, root-relative `nixos-anywhere --extra-files` tree, e.g. `etc/ssh/ssh_host_ed25519_key` (mode 600). Never staged in the flake. No symlinks. |
| `preEraseCheck` | Executable receiving `STAGED_FLAKE HOST_OUTPUT RECORD` after build. Compare *evaluated* Disko, boot and network choices with the record; nonzero exit stops before confirmation. Configure it when consumer policy requires it—the toolkit cannot infer that policy. |

> 🔒 **No secret contents in the JSON or store-bound files.** `machine.nix` and `facter.json` enter the world-readable Nix store. Review them and the evaluated configuration for credentials; the toolkit cannot detect every secret. Keep SSH keys in the separate recovery tree.

### Other machine lifecycles

The current public CLI deliberately refuses changing the selected branch or baseline, adopting an existing installation, or replacing a disk. These require separately designed evidence, review and authorization interfaces. Do not edit a receipt or root-owned state to bypass a refusal. Internal target-side polling and SSH protocol are not operator commands.
