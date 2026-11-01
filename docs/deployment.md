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

## Update without repartitioning

The target needs a consumer Git checkout with its trusted `origin`, a private machine directory and a root-owned state directory. Initialize `STATE_DIR/revision` with the **40-character commit actually deployed**, not whichever commit happens to be on `main`. Keep the state file mode 0600.

```bash
bash toolkit/deploy.sh update REPO BRANCH PRIVATE_MACHINE_DIR HOST_OUTPUT STATE_DIR
# Or, if enabled in the consumer NixOS configuration:
systemctl start themoss-update.service
```

The update locks attempts, fetches the reviewed branch, requires the new commit to descend from the known-good revision, stages only committed source with the private machine files, and builds **before** `nixos-rebuild switch`. A failed fetch or build cannot reach switch; a failed switch may have partially activated services. State advances only on successful switch. Updates never call Disko.

For a candidate/branch install, keep `services.themossUpdate.timer = false` and **do not manually start the service against old `main`**. Enable the timer only after merge and first-boot verification. Agentic can leave it off and update manually; the relay may opt in after validation.

### Recover from a bad update

Stop the timer first: `systemctl disable --now themoss-update.timer`. Inspect `journalctl -u themoss-update -n 100` and `nixos-rebuild list-generations`. Use the provider console/boot menu or `nixos-rebuild switch --rollback`; diagnose and re-enable the timer deliberately. Keep known-good generations, but do not mistake on-server generations for off-server backups. A successful build cannot prove networking, safe boot or application health.

## Dependency-update workflow

The **consumer** owns the schedule and calls the pinned [reusable workflow](../.github/workflows/lock-updates.yml). It updates committed lockfiles, runs consumer-supplied tests, opens a PR and requests auto-merge only after checking the caller-named branch-protection requirements. It [audits the App permissions](app-permissions.md) first. A branch-protection API error or absent required check fails the auto-merge step; ruleset-only protection is not yet supported by that check.

Example caller (replace the revision, commands and check names with tested consumer values):

```yaml
name: Dependency updates
on:
  schedule: [{ cron: '25 5 * * 2' }]
  workflow_dispatch:
permissions: { contents: read }
jobs:
  update:
    uses: benjaminpreiss/themoss.net/.github/workflows/lock-updates.yml@REPLACE_WITH_FULL_COMMIT
    with:
      toolkit-revision: 'REPLACE_WITH_SAME_FULL_COMMIT_AS_USES'
      app-policy-file: '.github/app-permissions.json'
      update-command: 'nix flake update && cargo update'
      test-command: 'bash tests/test-deployment.sh && nix build .#nixosConfigurations.HOST.config.system.build.toplevel'
      required-checks: 'Build and test / OS,Build and test / Application'
    secrets:
      APP_ID: ${{ secrets.UPDATE_APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.UPDATE_APP_PRIVATE_KEY }}
```

Use a dedicated App installed on **only the intended consumer repositories**, with Contents and Pull requests write and no bypass. [Prefilled registration form](https://github.com/settings/apps/new?name=themoss-consumer-lock-updates&description=Reviewed%20consumer%20lockfile%20PRs&url=https%3A%2F%2Fgithub.com%2Fbenjaminpreiss%2Fthemoss.net&public=false&webhook_active=false&request_oauth_on_install=false&contents=write&pull_requests=write): verify every setting yourself (private App, no webhook/OAuth, no additional write permissions). The App token triggers PR CI where the default `GITHUB_TOKEN` normally would not. Protect the consumer branch, enable auto-merge, and alert on failed/stalled workflows and host updates. **Auto-merging dependencies is a path to root-level OS code**; checks do not replace review, staged rollout or recovery.

## Adoption PRs to propose—not part of this toolkit PR

- **agentic:** retain its modules, `nixos/flake.lock`, `.deployment/generated/`, credential handling and `scripts/stage.sh` source allowlist until an equivalent is tested. Map its prepare/preflight/deploy scripts to discovery, preflight and install; map `scripts/update/apply.sh` to manual update. Keep unattended upgrades disabled. Test a disposable VM; do not switch an existing host here.
- **thepeer.stream:** retain its relay/saorsa modules, Disko, flake/Cargo pins and generated machine config. Map deployment prepare/preflight/install to the shared steps and target `update.sh` to the optional service. Test PR #4 on a real server before enabling the timer. A branch install must never fetch old `main` during validation.

Each consumer reviews and tests its own pinned toolkit bump independently. Neither consumer repo nor any deployed host is changed by this PR.
