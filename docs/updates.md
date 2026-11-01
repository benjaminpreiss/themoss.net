# Updating a deployed machine

**Updates do not repartition disks.** Use the install path only for a new machine, not for repairs. This guide covers both switching an existing NixOS host and proposing pinned dependency updates. For the initial install, see the [deployment guide](deployment.md).

## Switch a reviewed revision

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

## Propose dependency updates through PRs

This repo hosts the [reusable workflow](../.github/workflows/lock-updates.yml), but **only consumer repos** install the update App, store its key in Actions secrets and own a schedule/dispatch caller. No update App credentials or installation belong in `themoss.net`. The consumer owns the schedule and calls the pinned workflow. The reusable job installs Nix (pinned `cachix/install-nix-action` v31) before running consumer-supplied commands. It updates committed lockfiles, runs consumer-supplied tests, opens a PR and requests auto-merge only after checking the caller-named branch-protection requirements. It [audits the App permissions](app-permissions.md) first. A branch-protection API error or absent required check fails the auto-merge step; ruleset-only protection is not yet supported by that check.

Example caller (replace the revision, commands and check names with tested consumer values). The commands run in the reusable job, **not** in preceding caller steps: install or pin any other required tools through committed consumer configuration or inside the commands. In particular, thepeer.stream needs **Cargo 1.95** for its lockfile; commit a `rust-toolchain.toml` selecting 1.95 (with rustup available) or invoke Cargo 1.95 from a pinned Nix dev shell. Do not rely on the runner's default Cargo version.

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

CI runs `bash tests/consumer-commands.sh` with a credential-free synthetic machine flake: it executes `nix flake update` and builds `nixosConfigurations.synthetic.config.system.build.toplevel`. This checks the Nix command shape, not a real host closure, App authentication, scheduled caller execution or auto-merge. Test the pinned reusable workflow in each consumer with its actual locks, toolchains and App before relying on scheduled PRs; until the consumer pins a merged revision and passes that test, automated dependency PRs are **not operational**.

Give the update App Contents and Pull requests write access, **no bypass**, and install it on only the repos you intend to manage. The workflow checks its permissions and scopes its tokens to the calling repo; it does not audit the App's total reach across other installations. Review that scope separately.

Here is the **complete prefilled GitHub App registration URL**. Inspect it before opening or submitting the form; it suggests a private App with webhooks and OAuth-on-install disabled, not a guarantee that those settings are enforced:

```text
https://github.com/settings/apps/new?name=themoss-consumer-lock-updates&description=Reviewed%20consumer%20lockfile%20PRs&url=https%3A%2F%2Fgithub.com%2Fbenjaminpreiss%2Fthemoss.net&public=false&webhook_active=false&request_oauth_on_install=false&contents=write&pull_requests=write
```

The App token triggers PR CI where the default `GITHUB_TOKEN` normally would not. Protect the consumer branch, enable auto-merge, and alert on failed/stalled workflows and host updates. **Auto-merging dependencies is a path to root-level OS code**; checks do not replace review, staged rollout or recovery.
