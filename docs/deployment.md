# Deployment toolkit (pilot)

This toolkit shares **install and update mechanics**, not machine configuration or release decisions. It has not been validated on a real server. Start with a disposable VM; do not use it to migrate a production host.

- [`toolkit/deploy.sh`](../toolkit/deploy.sh) discovers, checks, installs or updates one machine.
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
bash toolkit/deploy.sh install PRIVATE_RECORD.json CONSUMER_REPO FULL_COMMIT PRIVATE_MACHINE_DIR HOST_OUTPUT
```

Discovery records architecture, boot mode, NIC/MAC and the chosen whole disk in a new mode-0600 file; it **does not** decide which disk is safe. The consumer generates `PRIVATE_MACHINE_DIR/machine.nix` (and optionally `facter.json`) and owns the Disko configuration. Review that configuration against the recorded disk and the **actual target** before install. Preflight re-probes the target. Install stages committed consumer source plus the private machine files, builds the NixOS output, re-probes, and requires you to type `ERASE /dev/WHOLE_DISK` before invoking `nixos-anywhere`. **Only install can invoke Disko.** The CLI does not upload credentials or bootstrap target-side private files for you.

Back up the record and generated files encrypted off-server. Never restore another machine's record onto this one.

## After installation

Use the [update guide](updates.md) to switch a reviewed revision, recover from a bad update, or configure scheduled lockfile PRs. Do not rerun the disk installer to repair an existing machine.

## Test without a server

CI runs `bash tests/test.sh` from [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); you can run the same command locally. It exercises discovery/preflight, destructive confirmation denial, failed and successful updates, and divergent Git history using synthetic probes, local Git and mocked Nix/SSH. It calls `bash tests/audit.sh`, which mocks GitHub responses to test App permission and installation/repository drift. Neither test contacts a server or GitHub or erases a disk. CI separately parses the Nix examples; **these tests do not build a consumer OS or prove a real install works**.

## Adoption PRs to propose—not part of this toolkit PR

- **agentic:** retain its modules, `nixos/flake.lock`, `.deployment/generated/`, credential handling and `scripts/stage.sh` source allowlist until an equivalent is tested. Map its prepare/preflight/deploy scripts to discovery, preflight and install; map `scripts/update/apply.sh` to manual update. Keep unattended upgrades disabled. Test a disposable VM; do not switch an existing host here.
- **thepeer.stream:** retain its relay/saorsa modules, Disko, flake/Cargo pins and generated machine config. Map deployment prepare/preflight/install to the shared steps and target `update.sh` to the optional service. Test PR #4 on a real server before enabling the timer. A branch install must never fetch old `main` during validation.

Each consumer reviews and tests its own pinned toolkit bump independently. Neither consumer repo nor any deployed host is changed by this PR.
