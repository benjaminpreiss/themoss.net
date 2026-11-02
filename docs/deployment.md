# Deploy a machine

Use this toolkit to install a **new** NixOS machine from a consumer repository. Start with a disposable VM: the toolkit has not been validated on a real server.

The consumer owns the OS configuration, disk layout and update policy. The toolkit supplies the steps below.

## 1. Discover and review the target

On your deployment computer, using the toolkit revision pinned by the consumer:

```bash
bash toolkit/deploy.sh discover root@HOST /dev/vda generated/record.json
bash toolkit/deploy.sh preflight generated/record.json
```

Before connecting, verify the **rescue environment's SSH host key** through the provider console. The toolkit never accepts a new key automatically.

Discovery writes a new, private record of the target's architecture, network interface and chosen whole disk. **You choose the disk**; the toolkit cannot tell you which disk is safe to erase. Review the record against the provider console. The consumer must also generate and review `generated/machine.nix` (and, if needed, `generated/facter.json`). These files must contain no credentials: Nix may put them in the world-readable store.

The consumer can add its own preflight checks. For example, the relay compares its *evaluated* disk, boot mode and MAC to the discovered target.

## 2. Install the exact pushed commit

Commit and push the consumer configuration you reviewed. Then run:

```bash
bash toolkit/deploy.sh install generated/record.json /path/to/consumer FULL_COMMIT generated HOST_OUTPUT PUSHED_BRANCH generated/install-receipt.json
```

Install requires a clean checkout and checks that `FULL_COMMIT` is the pushed branch head. It stages and builds that commit, re-probes the target, and asks you to type `ERASE /dev/vda` before calling `nixos-anywhere`.

**This is the only command that can erase a disk. Never use it to repair a machine.** Have off-server backups and console recovery ready first.

After a successful install, the toolkit writes `install-receipt.json`. It records the target, commit, branch, origin and hashes of the reviewed machine files. Back it up off-server. If the installer succeeded but writing the receipt failed, **stop** and verify the installed revision through the console; do not rerun install just to create a receipt.

## 3. Bootstrap after first boot

The installed machine has a **different SSH host key**. Verify that new key through the provider console before updating `known_hosts` or running:

```bash
bash toolkit/deploy.sh bootstrap generated/install-receipt.json /path/to/consumer generated /root/consumer /root/private-machine /var/lib/themoss
```

Bootstrap checks the private files against the receipt. It uploads only `machine.nix` and optional `facter.json`, checks out the exact installed commit on the target, and records that commit as the initial known-good revision. It refuses conflicting existing files. If an upload or clone stops halfway, retry the **same command**; do not reinstall.

The target paths are root-only. Bootstrap does **not** change timer policy. For a test-branch install, the consumer must configure the updater timer **off before installation** and verify it is absent on first boot.

Once the machine is working, see [updates and candidate transitions](updates.md).

## What stays in the consumer?

Keep the machine generator, supported architecture and network choices, application and Disko modules, SSH public-key selection, branch/cadence policy and live private data in the consumer. Small wrappers that pass the consumer's paths and pinned toolkit revision are expected. See the [relay example](../examples/thepeer.nix) and [manual-update example](../examples/agentic.nix).

Consumers pin an immutable toolkit commit in their own flake and test each pin bump before deployment. This repository does not build either consumer's complete OS. Run `bash tests/test.sh` for local, mocked lifecycle checks; these tests do not contact a server or erase a disk.
