# `moss machine`

Plan and apply NixOS installs and updates from your **operator computer**, then bootstrap the installed host. The consumer repository defines the OS; `moss` verifies the target and builds the reviewed, pushed source. [Install the CLI](../../README.md) first.

> 🛑 **An install can erase a whole disk.** Test on a disposable VM before using real hardware. A plan proposes an action; it does **not** authorize erasure. Repair (`fix`), adoption, restore and branch transitions are not public CLI commands.

## Operator environment

- **Tools:** `bash`, GNU coreutils, `git`, `jq`, SSH, Nix and `nixos-anywhere`. On Linux or macOS, use a reviewed toolkit checkout with flakes enabled and run `nix develop --no-write-lock-file .#operator` for the runtime tools (argc is only needed for development). macOS also needs a Linux Nix builder or VM; target-side updates require Linux.
- **Dry run:** `bash tests/operator-smoke.sh` in the toolkit checkout exercises mocks, *not hardware*.
- **Local files:** Run from the consumer Git checkout or a subdirectory. Add `.moss/` to its `.gitignore` and **commit the ignore rule before planning**; default storage refuses unignored files. Configuration, plans and receipts stay in `<git-root>/.moss/root@HOST/`, off the target and out of Git. [File layout and JSON properties](plan/README.md).
- **Secrets:** Keep `machine.nix` and optional `facter.json` credential-free: Nix builds may expose them in the store. Keep SSH keys in a separate recovery tree; back up the off-host install receipt separately.

## Install a machine

### 1. Prepare the source and target

- Push the **exact** consumer commit you intend to install. Prepare a mode-`0600`, credential-free `machine.nix` in a private directory you will name during setup. The consumer owns Disko, boot/network policy, credentials and evaluated checks; see [manual agentic](../../../../examples/agentic.nix) and [scheduled relay](../../../../examples/thepeer.nix).
- Verify the **rescue SSH host key** independently through the provider console. Review which physical whole disks are attached to this host.

### 2. Plan—no disk action

```bash
moss machine plan root@HOST
```

On first use, the CLI asks for the checkout, pushed commit/branch, NixOS output and private paths. It lists whole disks with **path, size, model and serial**; it proposes the only disk or requires a numbered choice. You can supply `--disk /dev/vda` explicitly. It saves a mode-`0600` configuration in `.moss/root@HOST/machine.json`, re-probes and builds a **separate install plan** in `.moss/root@HOST/plans/`. Later plans reuse the configuration; `--config` and `--output` override default paths.

**Before applying, review the printed plan path and its target, NIC/MAC, architecture, disk identity, branch tip, NixOS output and consumer checks.** `latest` points to the last successfully published plan *for that target*. Automatic disk selection is **not** erase consent. The CLI cannot infer a complete, safe Disko layout from Nix alone.

### 3. Apply—explicit erase consent

```bash
moss machine apply                     # only one target with plans in this checkout
moss machine apply --target root@HOST  # choose among multiple targets
# moss machine apply --plan /absolute/path/to/plan.json  # explicit override
```

`apply` prints the selected plan, rebuilds and rechecks the pushed tip, policy and **live disk**. Immediately before installation it requires you to type `ERASE /dev/vda`, then rechecks again. **Mismatch or uncertainty? Stop; make a new plan.** An explicit `--plan` (or positional plan path) selects a plan but never overwrites it or changes `latest`.

### 4. Verify the new host key, then bootstrap

After installation, verify the **new installed SSH host key** independently through the provider console. Only then run:

```bash
moss machine bootstrap "$(git rev-parse --show-toplevel)/.moss/root@HOST/install-receipt.json"
```

- Bootstrap never erases disks. If interrupted, **retry bootstrap, not install**.
- If install succeeded but its receipt is missing, **stop and inspect via the console**. Never reinstall merely to manufacture a receipt. Polling fails closed until bootstrap completes.

### Optional consumer checks

- `preEraseCheck` receives `STAGED_FLAKE HOST_OUTPUT RECORD` *after build* and must reject evaluated Disko/boot/network choices that disagree with discovery.
- `reportGenerator` can write a private `facter.json`; `recoveryDir` supplies root-only files (for example SSH keys) to `nixos-anywhere --extra-files`. Keep recovery material outside the flake and Nix store. See [configuration properties](plan/README.md#desired-configuration-machinejson).

## Update an existing machine

> **Branch tracking is a separate, reviewed decision.** Bootstrap initially pins the installed commit. Pushes cannot update it until the root-owned selector has been explicitly changed by the private transition process; `plan` will not change it. Once tracking is enabled, protect the selected branch with review and checks.

For a host *already tracking a branch*, set `revision` in its local config to the reviewed pushed tip, then:

```bash
moss machine plan root@HOST
moss machine apply --target root@HOST
```

- `plan` creates a typed **update** proposal without a disk action. `apply` rechecks the selector, recorded revision, origin, machine hash and exact branch tip under the target lock; it **never runs Disko** or selects a different branch.
- A moved tip, changed selector or divergent history **stops** the operation. Scheduled polling uses the same private update implementation, without an off-host plan. A successful build does not prove a safe reboot.

### If an update fails

- **Fetch/build failed:** running system and recorded state stay unchanged.
- **Switch started then failed:** services may be partly activated; `STATE_DIR/needs-inspection` blocks automation. Stop the timer, inspect `journalctl -u themoss-update -n 100`, the running system and NixOS generations, then recover via SSH or console. **NixOS generations are not off-host backups.** Resume only when selector and revision match the recovered generation.

Never edit receipts or root-owned state to bypass a refusal. `STATE_DIR` must be root-owned, mode `0700`, outside the fetched checkout and Nix store. For dependency-update PRs, see the [App audit](../../../github-app-audit/README.md).
