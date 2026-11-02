# Deploy or adopt a machine

> ⚠️ **Only `install` erases a disk.** Test on a disposable VM first; no real server has been validated. Never reinstall to repair bootstrap or adopt a running host.

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

## Fresh install

### 1. Discover and review

Verify the **rescue** SSH host key via the provider console, then:

```bash
bash toolkit/deploy.sh discover root@HOST /dev/vda generated/record.json
bash toolkit/deploy.sh preflight generated/record.json
```

Review the private record against the console: **architecture, boot mode, NIC/MAC, whole disk**. Prepare credential-free `generated/machine.nix` and optional `generated/facter.json`.

### 2. Install the pushed commit

Back up private files off-host and prepare console recovery. Commit and push the reviewed configuration:

```bash
bash toolkit/deploy.sh install generated/record.json /path/to/consumer FULL_COMMIT generated HOST_OUTPUT PUSHED_BRANCH generated/install-receipt.json [REPORT_GENERATOR|- [RECOVERY_DIR|- [PRE_ERASE_CHECK|-]]]
```

Optional consumer inputs, in positional order:

| Input | Contract |
| --- | --- |
| `REPORT_GENERATOR` | Executable receiving `TARGET OUTPUT_PATH`; writes a JSON hardware report. The toolkit saves it privately as `generated/facter.json` and **refuses to replace** an existing report. Back it up. |
| `RECOVERY_DIR` | Private, root-relative `nixos-anywhere --extra-files` tree (for example `etc/ssh/ssh_host_ed25519_key`, mode 600). It is **not staged in the flake**. The toolkit rejects symlinks but does not create or rotate credentials. |
| `PRE_ERASE_CHECK` | Executable receiving `STAGED_FLAKE HOST_OUTPUT RECORD` after build; compare *evaluated* Disko, boot and network choices with the record. Nonzero exit stops before confirmation. |

Use `-` to skip an earlier option. Before the installer, the toolkit:

1. Requires a clean checkout at the exact pushed branch head.
2. Builds, runs the optional check and re-probes the target.
3. Requires you to type `ERASE /dev/vda`.

**Back up `generated/install-receipt.json` off-host.** It binds target, origin, revision and machine-file hashes. If the installer succeeded but the receipt was not written, **stop**: inspect the installed revision via console. Never reinstall just to mint a receipt.

### 3. Bootstrap

Verify the **new installed** SSH host key through the console before changing `known_hosts`:

```bash
bash toolkit/deploy.sh bootstrap generated/install-receipt.json /path/to/consumer generated /root/consumer /root/private-machine /var/lib/themoss
```

Bootstrap uploads original private files, checks out the **exact installed commit** and writes the root-only known-good revision **last**.

- **Interrupted?** Retry the same command; do not reinstall.
- **Conflict?** Inspect files; bootstrap will not overwrite them.
- **Test branch?** Keep the updater timer **off before first boot**. Bootstrap does not control timers.

After validation, see [updates and reviewed transitions](updates.md).

## Existing host: adopt without reinstalling

1. **Pause the consumer's updater timer.** Verify `/run/current-system` via console. Recover the *actual* pinned source commit and original credential-free `machine.nix` / optional `facter.json` from private records. The commit must be reachable from the nominated branch; do not switch branches on the host.
2. **Record operator-verified evidence** off-host in a mode-600 JSON file (never commit it):

   ```json
   {
     "target": "root@HOST", "origin": "SSH_OR_HTTPS_GIT_URL",
     "revision": "FULL_40_CHARACTER_COMMIT", "branch": "CANDIDATE_BRANCH",
     "machineSha256": "SHA256_OF_ORIGINAL_MACHINE_NIX", "facterSha256": "",
     "runningSystem": "/nix/store/VERIFIED-CURRENT-SYSTEM",
     "verifiedBy": "operator, date and console/change record"
   }
   ```

   Set `facterSha256` to the original report's hash if present. Independently check the origin, revision, hashes, ancestry and running closure against deployment records.
3. **Verify the SSH key**, then run:

   ```bash
   bash toolkit/deploy.sh adopt /private/evidence.json /path/to/consumer /private/machine HOST_OUTPUT /root/consumer /root/private-machine /var/lib/themoss
   ```

`adopt` compares a build of the pinned output with **both** the evidence and the running host, then bootstraps root-only state. It **cannot prove historical inputs** without your independent records.

- **Mismatch or missing evidence?** Stop; never invent a revision or overwrite existing state.
- **Interrupted?** Retry with the same evidence. Polling fails closed until the known-good revision exists.
- **Ready to track a branch?** Enable it in a later reviewed transition, not during adoption.

**Adoption changes neither disks nor the running system.** Before upgrading the toolkit, pin a full commit in the consumer flake and test that OS. `bash tests/test.sh` uses mocks, not real hardware.
