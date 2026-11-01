# Deployment toolkit (pilot)

This toolkit shares **install, bootstrap and update mechanics**, not machine configuration or release decisions. It has not been validated on a real server. Start with a disposable VM; do not use it to migrate a production host.

- [`toolkit/deploy.sh`](../toolkit/deploy.sh) discovers, checks, installs, bootstraps or updates one machine.
- The flake exports `nixosModules.update`, an optional target-side update service and timer.
- [The App audit](app-permissions.md) and reusable workflow help consumers propose dependency updates through PRs.

## Who owns what?

| Where | What belongs there |
| --- | --- |
| `themoss.net` | Probe comparison, typed erase confirmation, staging and build-before-switch, update locking, optional timer and reusable workflow. |
| Each consumer repo | Disko layout, boot/network and application modules, flake and Cargo locks, supported hardware, branch/cadence policy, CI, and its schedule/dispatch caller. |
| Deployment computer; target when updating unattended | Per-machine `record.json`, generated `machine.nix`, optional `facter.json`, and the known-good deployed revision. Back these up **off-server**. |
| Consumer Actions secrets | Lock-update App ID and private key. Never place the key in this repo, on a target or in a Nix expression. |

The record contains hardware identity; `machine.nix` may contain a **public** SSH key. Neither may contain secrets: Nix store inputs can be world-readable. Keep password hashes, private keys and tokens out of staged source.

## Pin it in a consumer

Add a flake input at a reviewed full commit, lock it in the **consumer's** `flake.lock`, and import `inputs.themoss.nixosModules.update`. The consumer passes `inputs` through `specialArgs`. See the [manual agentic example](../examples/agentic.nix) and [relay example](../examples/thepeer.nix).

A future toolkit change is a **separate lockfile PR in each consumer**. Build that consumer's NixOS output with synthetic machine data and test its own services before choosing to deploy. This repo's CI parses the examples and checks the exported flake; it does **not** build either consumer's full OS output.

## Install a new machine

On the deployment computer, use the pinned toolkit checkout with Bash, SSH, `jq`, Git, tar, Nix and `nixos-anywhere`. The rescue target needs Bash, `ip`, `lsblk`, `uname` and SSH. Verify its SSH host key through the provider console **before** connecting. Confirm off-server backups and console recovery.

```bash
bash toolkit/deploy.sh discover root@HOST /dev/WHOLE_DISK PRIVATE_RECORD.json
bash toolkit/deploy.sh preflight PRIVATE_RECORD.json
bash toolkit/deploy.sh install PRIVATE_RECORD.json CONSUMER_REPO FULL_COMMIT PRIVATE_MACHINE_DIR HOST_OUTPUT PUSHED_BRANCH
```

Discovery records architecture, boot mode, NIC/MAC and the chosen whole disk in a new mode-0600 file; it **does not** decide which disk is safe. The consumer generates `PRIVATE_MACHINE_DIR/machine.nix` (and optionally `facter.json`) and owns the Disko configuration. Review that configuration against the recorded disk and the **actual target** before install. Preflight re-probes the target. Install requires `FULL_COMMIT` to be the exact pushed head of `PUSHED_BRANCH`, stages committed consumer source plus the private machine files, builds the NixOS output, re-probes, and requires you to type `ERASE /dev/WHOLE_DISK` before invoking `nixos-anywhere`. **Only install can invoke Disko.** Never use install to repair an existing machine.

Back up the record and generated files encrypted off-server. Never restore another machine's record onto this one.

## First-boot bootstrap

Verify the **new** SSH host key out of band at the provider console before putting it in your operator's `known_hosts`. The rescue host key is not the installed host key. No `accept-new` or automatic trust is used. After the first boot, from the deployment computer with the same pinned toolkit and reviewed private directory (mode 0600 `machine.nix`):

```bash
bash toolkit/deploy.sh bootstrap root@HOST CONSUMER_REPO FULL_COMMIT PRIVATE_MACHINE_DIR /root/consumer /root/private-machine /var/lib/themoss PUSHED_BRANCH
```

This copies **only** `machine.nix` and optional `facter.json` via strict-key SSH; neither private keys nor tokens are accepted as inputs. They must be credential-free because install staging places them in the Nix store. The target fetches the consumer's configured `origin` and checks out exactly `FULL_COMMIT` detached, requiring it to remain an ancestor of the pushed branch. It writes `/var/lib/themoss/revision` last. The root-only checkout, private files and state reject mismatching existing state; an interrupted upload/clone can be retried with identical arguments. Keep paths separate and root-owned, and protect off-server backups. Bootstrap disables the update timer; a candidate must **also** set `services.themossUpdate.timer = false` in its NixOS configuration. Bootstrap cannot reconfigure a running host or erase a disk.

After validating the candidate and merging to the reviewed branch, use the [explicit transition](updates.md#candidate-to-main-transition). Do not point a candidate's timer at old `main`.

## After installation

Use the [update guide](updates.md) to switch a reviewed revision, recover from a bad update, or configure scheduled lockfile PRs.

## Test without a server

CI runs `bash tests/test.sh` from [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); you can run the same command locally. It exercises discovery/preflight, destructive confirmation denial, failed and successful updates, and divergent Git history using synthetic probes, local Git and mocked Nix/SSH. It calls `bash tests/audit.sh`, which mocks GitHub responses to test App permission and installation/repository drift. Neither test contacts a server or GitHub or erases a disk. CI separately parses the Nix examples; **these tests do not build a consumer OS or prove a real install works**.

## Adoption PRs to propose—not part of this toolkit PR

See the [consumer migration guide](migration.md) for relay PR #4 and agentic issue #30. Each consumer reviews and tests its own pinned toolkit bump independently. Neither consumer repo nor any deployed host is changed by this PR.
