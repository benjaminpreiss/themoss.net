# Deploy or adopt a machine

> ⚠️ **Only `install` erases a disk.** Test on a disposable VM first; no real server has been validated. Never reinstall to repair bootstrap or adopt a running host.

## Principles

1. **Verify before acting.** Confirm SSH keys through the provider console, check the whole disk, and deploy a reviewed, pushed commit.
2. **Keep secrets out of Nix.** `machine.nix` and `facter.json` may enter the world-readable store. Keep credentials in a separate recovery tree or private target state.
3. **Preserve evidence.** Back up original machine facts and receipts off-host. A mismatch stops the process; neither install nor adoption repairs it silently.

The consumer owns machine generation, supported hardware, Disko and application modules, SSH keys, recovery files, evaluated pre-erase checks, branch and update policy. The toolkit owns target re-probing, staging, typed erase confirmation, the sole installer call and guarded bootstrap. See [manual agentic](../examples/agentic.nix) and [scheduled relay](../examples/thepeer.nix) examples.

## Operator environment

**On a Mac:** use an x86_64/aarch64 Linux VM with Nix (flakes enabled) and SSH access to the target. Native macOS is not tested: off-host scripts currently use GNU `stat`, `tar` and `sha256sum`. In the VM, check out a reviewed toolkit commit, verify its `flake.lock`, then run `nix develop --no-write-lock-file .#operator`. The locked shell provides `nixos-anywhere` and other operator tools. Keep the consumer's pinned source and private inputs in the VM, outside Git and the Nix store. Target-side updates remain Linux-only.

CI tests this pinned shell and synthetic commands, **not** a live install.

## Fresh install

### 1. Discover and review

Verify the **rescue** SSH host key via the provider console, then:

```bash
bash toolkit/deploy.sh discover root@HOST /dev/vda generated/record.json
bash toolkit/deploy.sh preflight generated/record.json
```

Compare the private record's architecture, boot mode, NIC/MAC and **whole disk** with the provider console. Prepare `generated/machine.nix` and, if needed, `generated/facter.json`; neither may contain credentials.

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

Use `-` to skip an earlier option. The toolkit requires a clean checkout and the exact pushed branch head, builds it, runs the optional check, re-probes the target and asks you to type `ERASE /dev/vda`. Only then does it invoke `nixos-anywhere`.

**Save the private `generated/install-receipt.json` off-host.** It binds target, origin, revision and machine-file hashes. If installation succeeds but writing the receipt fails, **stop** and inspect the installed revision via console. Do not reinstall to mint a receipt.

### 3. Bootstrap

Verify the **new installed** SSH host key through the console before changing `known_hosts`:

```bash
bash toolkit/deploy.sh bootstrap generated/install-receipt.json /path/to/consumer generated /root/consumer /root/private-machine /var/lib/themoss
```

Bootstrap uploads the original private files, checks out the **exact installed commit** and writes the root-only known-good revision last. Retry interrupted uploads with the same command; inspect conflicting files rather than overwriting them. For a test-branch install, keep the updater timer **off before first boot**; bootstrap does not control timers. After host validation, see [updates and reviewed transitions](updates.md).

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

`adopt` builds the pinned output, compares its store path to the evidence **and** running host, then reuses the guarded, retryable root-only bootstrap. It does **not prove historical inputs**; that depends on your independent records. Missing evidence, differing closures or conflicting target state require investigation, not a guessed revision. Until bootstrap writes the known-good revision, polling fails closed. Enable branch tracking only in a later reviewed transition. **Adoption changes neither disks nor the running system.**

Before updating the toolkit itself, pin a full commit in the consumer's flake and test that consumer's OS. `bash tests/test.sh` exercises mocks, not real hardware.
