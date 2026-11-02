# Deploy a machine

> ⚠️ **`install` erases a whole disk.** Start with a disposable VM; this toolkit has not been validated on a real server. Never use `install` to repair a machine.

The operator flow is **discover → install → verify the new SSH key → bootstrap**. The consumer supplies the OS configuration and decides whether automatic updates are enabled.

## Operator environment (including Mac operators)

The off-host scripts use Linux `stat`, GNU `tar`, `sha256sum`, Bash, Nix and `nixos-anywhere`; **native macOS is not supported**. From a Mac, use an x86_64 or aarch64 **Linux VM** with SSH access to the target and a Nix installation with flakes enabled. Check out a reviewed full toolkit commit in the VM, verify that commit and its committed `flake.lock`, then run `nix develop --no-write-lock-file .#operator` from that checkout. The shell uses the committed nixpkgs lock for the installer and command-line dependencies; use your consumer's pinned source commit and private operator files inside the VM. Verify rescue and installed SSH keys independently through the provider console; never copy credentials into the Nix store. CI evaluates the pinned shell and runs synthetic off-host command fixtures, not a live install or a macOS binary. Linux target-side `update` remains outside this operator shell.

## 1. Discover and review

```bash
bash toolkit/deploy.sh discover root@HOST /dev/vda generated/record.json
bash toolkit/deploy.sh preflight generated/record.json
```

**Before connecting:** verify the rescue environment's SSH host key through the provider console. SSH will not accept a new key automatically.

**What you review:**

- `generated/record.json` — the target's architecture, network interface and chosen whole disk. **You** decide which disk is safe to erase; check it against the provider console.
- `generated/machine.nix` — the consumer-generated NixOS machine configuration. Add a reviewed `generated/facter.json` if needed. A consumer may instead supply a generator executable to `install`; it receives `TARGET OUTPUT_PATH`, writes JSON to the private output path and the toolkit refuses to replace any existing report. Back up the resulting report before discarding the operator machine.
- The consumer's own pre-erase executable receives `STAGED_FLAKE HOST_OUTPUT RECORD` **after the build** and can evaluate the consumer's actual Disko, boot and network settings against the record. A nonzero exit aborts before the erase prompt. This check complements, not replaces, the toolkit's target re-probe.

🔒 **Keep credentials out of `machine.nix` and `facter.json`.** Nix can put these inputs in the world-readable store.

## 2. Install the pushed commit

Commit and push the configuration you reviewed. Have **off-server backups and console recovery** ready, then run:

```bash
bash toolkit/deploy.sh install generated/record.json /path/to/consumer FULL_COMMIT generated HOST_OUTPUT PUSHED_BRANCH generated/install-receipt.json [REPORT_GENERATOR|- [RECOVERY_DIR|- [PRE_ERASE_CHECK|-]]]
```

Install checks that the checkout is clean and `FULL_COMMIT` is the pushed branch head. It builds that commit, runs the optional check, rechecks the target, and requires you to type `ERASE /dev/vda` before invoking the disk installer. Optional `RECOVERY_DIR` is a separate consumer-prepared `nixos-anywhere --extra-files` tree copied onto the installed root filesystem; it is **never staged in the Nix flake**. Prepare root-relative paths and permissions (e.g. `etc/ssh/ssh_host_ed25519_key` mode 600) yourself; do not put private keys in `machine.nix`, `facter.json` or Git. The toolkit rejects linked recovery files; it does not create, rotate or replace recovery credentials. Keep the source tree off-host and private.

**Save `generated/install-receipt.json` off-server.** Written only after a successful install, it records the installed commit, target, branch, origin and hashes of the machine files. Bootstrap uses it; you will not need to re-enter the commit.

> If install succeeded but writing the receipt failed, **stop**. Check the installed revision via the provider console. Do not run the installer again just to create a receipt.

## 3. Verify the new key and bootstrap

The installed machine has a **new SSH host key**, different from the rescue environment's. Verify it through the provider console before updating `known_hosts`.

```bash
bash toolkit/deploy.sh bootstrap generated/install-receipt.json /path/to/consumer generated /root/consumer /root/private-machine /var/lib/themoss
```

Bootstrap checks the machine files against the receipt, uploads them, checks out the **exact installed commit** on the target and records it as the initial known-good revision. Target files are root-only.

- **Interrupted upload or clone?** Retry the same bootstrap command; do not reinstall.
- **Conflicting target files?** Stop and inspect them. Bootstrap will not overwrite them.
- **Test-branch install?** Configure the updater timer **off before install** and confirm it is absent at first boot. Bootstrap does not control timers.

After validating the host, see [updating and candidate transitions](updates.md).

## Adopt an existing host (no install receipt)

**Do not run `install` on a running host.** First disable the consumer's updater timer and verify the installed NixOS closure via the provider console and `/run/current-system`. Select the *actual* pinned source commit and original credential-free `machine.nix` / optional `facter.json` from private backups, not regenerated or changed files. Ensure the commit is reachable from the nominated remote branch; do not switch branches on the host yet. Create an off-host mode-600 evidence JSON (never commit it):

```json
{
  "target": "root@HOST", "origin": "SSH_OR_HTTPS_GIT_URL",
  "revision": "FULL_40_CHARACTER_COMMIT", "branch": "CANDIDATE_BRANCH",
  "machineSha256": "SHA256_OF_ORIGINAL_MACHINE_NIX", "facterSha256": "",
  "runningSystem": "/nix/store/VERIFIED-CURRENT-SYSTEM",
  "verifiedBy": "operator name, date, and console/change record"
}
```

Set `facterSha256` to the original report's SHA-256 when present. Verify the origin, commit, hashes, branch ancestry and `/run/current-system` against the operator's deployment records. Then, from a verified SSH host key:

```bash
bash toolkit/deploy.sh adopt /private/evidence.json /path/to/consumer /private/machine HOST_OUTPUT /root/consumer /root/private-machine /var/lib/themoss
```

`adopt` builds the selected output, compares its store path to both the evidence and the running host, then uses the same guarded, retryable root-only bootstrap as a fresh install. This is **not proof** that an old deployment used exactly these inputs: that assertion depends on your independent records and review. A build with a different store path or an unavailable historical source is a stop, not a reason to invent a revision. Existing target checkout, private facts or state must match exactly; mismatches are not replaced. A dropped upload can be retried with the same evidence. The known-good revision is written last: until it exists, the poller refuses to update. Keep the timer disabled until a separate reviewed transition enables it. No disk or running system is changed by adoption.


## What belongs to the consumer?

Keep machine generation, supported hardware and network choices, SSH public-key selection, application and Disko modules, update branch/cadence and live private data in the consumer. Small wrappers can supply its paths and pinned toolkit revision. Install-time report generation, recovery contents and evaluated checks are consumer-owned; target identity checks, staging, typed erase confirmation, bootstrap and the only installer invocation are toolkit mechanics. See the [relay](../examples/thepeer.nix) and [manual-update](../examples/agentic.nix) examples.

**Before adopting a toolkit update:** pin a full commit in the consumer's flake and test that consumer's OS. Locally, `bash tests/test.sh` exercises the toolkit with mocks; it does not contact a server or prove a real install works.
