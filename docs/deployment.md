# Deploy a machine

> ⚠️ **`install` erases a whole disk.** Start with a disposable VM; this toolkit has not been validated on a real server. Never use `install` to repair a machine.

The operator flow is **discover → install → verify the new SSH key → bootstrap**. The consumer supplies the OS configuration and decides whether automatic updates are enabled.

## 1. Discover and review

```bash
bash toolkit/deploy.sh discover root@HOST /dev/vda generated/record.json
bash toolkit/deploy.sh preflight generated/record.json
```

**Before connecting:** verify the rescue environment's SSH host key through the provider console. SSH will not accept a new key automatically.

**What you review:**

- `generated/record.json` — the target's architecture, network interface and chosen whole disk. **You** decide which disk is safe to erase; check it against the provider console.
- `generated/machine.nix` — the consumer-generated NixOS machine configuration. Add a reviewed `generated/facter.json` if needed.
- The consumer's own preflight — for example, the relay compares its *evaluated* disk, boot mode and MAC against the record.

🔒 **Keep credentials out of `machine.nix` and `facter.json`.** Nix can put these inputs in the world-readable store.

## 2. Install the pushed commit

Commit and push the configuration you reviewed. Have **off-server backups and console recovery** ready, then run:

```bash
bash toolkit/deploy.sh install generated/record.json /path/to/consumer FULL_COMMIT generated HOST_OUTPUT PUSHED_BRANCH generated/install-receipt.json
```

Install checks that the checkout is clean and `FULL_COMMIT` is the pushed branch head. It builds that commit, rechecks the target, and requires you to type `ERASE /dev/vda` before invoking the disk installer.

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

## What belongs to the consumer?

Keep machine generation, supported hardware and network choices, SSH public-key selection, application and Disko modules, update branch/cadence and live private data in the consumer. Small wrappers can supply its paths and pinned toolkit revision. See the [relay](../examples/thepeer.nix) and [manual-update](../examples/agentic.nix) examples.

**Before adopting a toolkit update:** pin a full commit in the consumer's flake and test that consumer's OS. Locally, `bash tests/test.sh` exercises the toolkit with mocks; it does not contact a server or prove a real install works.
