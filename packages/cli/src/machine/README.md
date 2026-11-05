# `moss machine`

Plan and apply reviewed NixOS installs and updates from your **operator computer**, then bootstrap a newly installed host. Your consumer repository defines the OS; `moss` verifies the target and builds the pushed source. [Install the CLI and check requirements](../../README.md) first.

> 🛑 **Install plans can erase a disk.** This is a pilot; test on a disposable VM before using real hardware. `moss machine fix`, adoption, restore and branch transitions are **not** public commands.

## Operator environment

The CLI needs `nix`, `nixos-anywhere`, `jq`, SSH and GNU tools. On Linux or macOS, use a reviewed toolkit checkout with flakes enabled and run `nix develop --no-write-lock-file .#operator`; it supplies runtime tools without argc. `bash tests/operator-smoke.sh` in that checkout exercises mocks, **not hardware**. On macOS you also need a Linux Nix builder (or a Linux VM) to build NixOS closures. Target-side updates require Linux.

Keep configuration, plans and receipts private **off-host**. Inputs to Nix builds (`machine.nix` and `facter.json`) may become world-readable in the store: never put secrets in them. Keep SSH keys in a separate recovery tree.

## Install a machine

1. **Prepare and review.** Verify the rescue SSH host key through the provider console. Push the exact consumer commit, be ready to review the target's **whole disks**, and prepare credential-free `/private/machine/machine.nix`. The consumer owns Disko, boot/network policy, credentials and evaluated checks; see [manual agentic](../../../../examples/agentic.nix) and [scheduled relay](../../../../examples/thepeer.nix).
2. **Plan without erasing.** Provide the verified rescue SSH target explicitly. On first use, omit `--config`: the CLI asks for the checkout, pushed revision/branch, NixOS output and private paths. It **lists whole disks** from the target with size, model and serial. It proposes the only disk if there is one; if there are several, you must select one by number. You can supply `--disk /dev/vda` to select explicitly. It saves the reviewed disk in a new mode-600 `/private/machine.json` **off-host**, without overwriting an existing file.

   ```bash
   moss machine plan root@HOST --output /private/install-plan.json
   ```

   `plan` re-probes the target and builds a separate typed proposal. **Review** target, NIC/MAC, architecture, disk path/size/model/serial, branch tip, NixOS output and evaluated policy. *Automatic selection is not permission to erase*; even a single disk needs typed confirmation at apply. For later plans, pass `--config /private/machine.json` to reuse this reviewed configuration. If you author JSON yourself, include the whole-disk path or pass `--disk` explicitly.

   Optional `preEraseCheck` runs *after build* with `STAGED_FLAKE HOST_OUTPUT RECORD` and must reject evaluated Disko/boot/network choices that disagree with discovery. The CLI **does not** render a complete Disko layout diff. Optional `reportGenerator` writes `facter.json`; optional `recoveryDir` holds root-only `nixos-anywhere --extra-files` content such as SSH keys. Keep both outside the flake.
3. **Apply with confirmation:**

   ```bash
   moss machine apply /private/install-plan.json
   ```

   Apply rebuilds and rechecks the pushed tip, evaluated policy and live disk before requiring you to type `ERASE /dev/vda`. It rechecks again immediately before the installer. **Any mismatch? Stop and make a new plan.**
4. **Verify the *new* installed SSH host key through the provider console**, then bootstrap without erasing:

   ```bash
   moss machine bootstrap /private/install-receipt.json --config /private/machine.json
   ```

   Back up the receipt off-host. If bootstrap is interrupted, retry **bootstrap**, never install. If installation succeeded but the receipt is missing, **stop and inspect by console—do not reinstall to manufacture one**. Polling fails closed until bootstrap completes.

## Update an existing machine

Bootstrap pins the installed commit; **pushes do not update it** until a separately reviewed selection enables branch tracking. That selection is not part of the public CLI. Following a branch trusts future pushes as potential OS updates—protect that branch with reviews and checks. A successful build does not prove a safe reboot.

For a host *already tracking a branch*, set `revision` in the private off-host config to that branch's reviewed pushed tip. Omit `--disk`:

```bash
moss machine plan root@HOST --config /private/machine.json --output /private/update-plan.json
moss machine apply /private/update-plan.json
```

The plan is mode-600 and typed `update`. Apply holds the update lock and rechecks the selector, recorded revision, origin, machine hash and exact tip before switching. A moved tip, changed selector or divergent history **stops**; it never calls the disk installer or silently selects a different branch. Scheduled polling uses the same private update implementation, without an off-host plan.

### If an update fails

- **Fetch/build failed:** running system and recorded state stay unchanged.
- **Switch started then failed:** services may be partly activated; `STATE_DIR/needs-inspection` blocks automation. Stop the timer, inspect `journalctl -u themoss-update -n 100`, the running system and NixOS generations, then recover via SSH or console. **NixOS generations are not off-host backups.** Resume only when the selector and revision match the recovered generation.

Do not edit receipts or root-owned state to bypass a refusal. `STATE_DIR` must stay root-owned, mode `0700`, outside the fetched checkout and Nix store. For dependency-update PRs, see the [App audit](../../../github-app-audit/README.md).
