# Deployment toolkit v0 (pilot, not production validated)

Interface: `flake.nix` exports `nixosModules.update`; `toolkit/deploy.sh` exposes `discover TARGET WHOLE_DISK PRIVATE_RECORD`, `preflight PRIVATE_RECORD`, `install PRIVATE_RECORD CONSUMER_GIT_REVISION_REPO COMMIT PRIVATE_MACHINE_DIR HOST`, and `update REPO BRANCH PRIVATE_MACHINE_DIR HOST STATE_DIR`. The deployment computer needs Bash, SSH, jq, git, tar, Nix, and nixos-anywhere for install. The rescue target needs Bash, `ip`, `lsblk`, `uname`, and SSH; the installed target needs the packages supplied by the update module. Test SSH fingerprints out of band; no permissive host-key policy. Never run this without a provider console and verified off-server backup. Discovery cannot determine whether a disk is safe to erase.

**Ownership:** This repo owns probe comparison, destructive prompt, committed-source staging, build-before-switch logic, update serialization and the optional timer. The consumers retain the Disko layout, bootloader, network and service modules, host output name, flake.lock, Cargo.lock, supported hardware/network/storage policy, branch protection, release cadence and workflows calling the shared workflow. Operator-private `record.json` is created mode 600 and must be stored outside Git; the consumer generates and backs up `machine.nix` and optional `facter.json` in PRIVATE_MACHINE_DIR on the deployment computer and (for unattended updates) on the target. These are *not secrets*: Nix store paths are world-readable. Keep password hashes, PEMs and tokens outside the Nix source/stage. Back up the private machine directory and record encrypted off-server; restore only to the same machine, verify identities and file permissions before retrying. `install` never writes credentials to the target; consumers arrange private file transfer/initial state bootstrap separately. Initial target `STATE_DIR/revision` must contain exactly the deployed 40-character Git commit (mode 0600, root-owned); don't initialize it from the latest main unless that is what is running.

## Pin and integrate

In each consumer add `themoss.url = "github:benjaminpreiss/themoss.net/<reviewed-full-commit>";`, lock and commit its own flake.lock. Pass flake `inputs` via specialArgs and import `inputs.themoss.nixosModules.update` (see `examples/`). CI in this repo parses both examples and evaluates the exported flake; consumer adoption PRs must additionally build their actual NixOS outputs with synthetic generated machine modules before deployment. The module `timer = false` is mandatory for candidate/test installs; after merging the candidate and verifying first boot, opt in explicitly. The timer is *not* installed merely because `enable = true`. Manual agentic use: invoke `bash toolkit/deploy.sh update ...` on the target or invoke the systemd service manually if installed. Neither update command has a Disko entry point; `install` alone calls nixos-anywhere. Install needs a consumer-owned Disko configuration that uses the recorded disk: inspect and confirm the generated module and effective disk configuration independently; this CLI does not generate a disk layout. Source Git checkout on target must have origin set to the reviewed public consumer repo; it fetches the named branch and refuses non-fast-forward from the recorded known-good commit. No runtime fetch of toolkit scripts: they come from the flake-locked module. The manual CLI must be invoked from a checked-out, pinned toolkit revision.

Successful update advances state only after switch; a failed fetch/build leaves it untouched, while a failed switch may partially activate services. Service logs show old/new revision or failure in journald. Keep bootable NixOS generations. On failure pause the timer (`systemctl disable --now themoss-update.timer`), inspect `journalctl -u themoss-update -n 100`, `nixos-rebuild list-generations`; use console boot menu or `nixos-rebuild switch --rollback`, repair, then re-enable explicitly. On-server generations aren't off-server backups. A build cannot prove network connectivity, successful boot or app behavior.

## Consumer mapping and follow-up PRs

- **agentic adoption PR (proposed, not made here):** retain `nixos/modules/{base,disk,agentic,recovery,firstboot}.nix`, `nixos/flake.lock`, `.deployment/generated/`, credential upload and service tests. Keep `scripts/stage.sh` for its special skill/source allowlist or adapt that policy before replacing it. Map `scripts/install/prepare.sh` to discover + agentic-specific machine generation, `preflight.sh` to preflight + real Nix build, `deploy.sh` to install; map `scripts/update/apply.sh` to a manual build/switch. Keep unattended upgrades disabled. Test a fresh install in a disposable VM; do not switch an existing host here.
- **thepeer.stream adoption PR (proposed, not made here):** retain relay/saorsa modules, Disko, flake/Cargo pins and private generated config. Map `deployment/scripts/prepare.sh`, `preflight.sh`, `install.sh` to probe/preflight/install, and its target-side `update.sh` to the shared module's service. Start with `timer = false` in candidate branch; only enable after merge and real-server test. The draft PR #4 has not been validated on a server. Never have a branch install automatically fetch old `main`.

Each consumer proposes the shared flake lock bump in its **own** PR, runs fixture tests and real consumer output builds, reviews differences and chooses when to deploy. No central repository can advance a consumer's release. These examples are integration sketches, not drop-in substitutions for consumer policies.

## Lock update automation

A consumer-owned scheduled/dispatch workflow calls `.github/workflows/lock-updates.yml@<immutable-full-commit>` with trusted `update-command`, `test-command` and exact `required-checks`. The current workflow must first be replaced by [`workflow-templates/lock-updates.yml`](../workflow-templates/lock-updates.yml) by a maintainer with workflow-write permission: that version audits the App's permissions and complete installation repository scope **before** proposing updates (see [App permission audit](app-permissions.md)); call the workflow with `contents: read` and App secrets `APP_ID` and `APP_PRIVATE_KEY` scoped to that consumer's Actions repository. Example caller:

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
      update-command: 'nix flake update && cargo update --locked'
      test-command: 'bash tests/test-deployment.sh && nix build .#nixosConfigurations.HOST.config.system.build.toplevel'
      required-checks: 'Build and test / OS,Build and test / Application'
      toolkit-revision: 'REPLACE_WITH_SAME_FULL_COMMIT_AS_USES'
      app-policy-file: '.github/app-permissions.json'
    secrets:
      APP_ID: ${{ secrets.UPDATE_APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.UPDATE_APP_PRIVATE_KEY }}
```

Replace commands with **real** consumer commands and synthetic fixture setup. App registration example: [prefilled GitHub App form](https://github.com/settings/apps/new?name=themoss-consumer-lock-updates&description=Reviewed%20consumer%20lockfile%20PRs&url=https%3A%2F%2Fgithub.com%2Fbenjaminpreiss%2Fthemoss.net&public=false&webhook_active=false&request_oauth_on_install=false&contents=write&pull_requests=write). Verify the form: private, no webhook/OAuth, Contents and PR read/write only, install on **only the consuming repo**. Do not store the PEM in themoss or on targets. GitHub's default `GITHUB_TOKEN` PRs generally do not trigger other workflows; the dedicated App token does. Configure branch protection with the named required checks, enable auto-merge, no App bypass, notifications for stalled/failed PRs and service failures. The shared workflow fails closed if it cannot read branch protection or verify every named check is required (ruleset-only protection needs a separately verified implementation). It cannot make missing protections safe. Auto-merging dependencies gives upstream code a path to root on the OS; review/checks, staged rollouts and console recovery are essential.
