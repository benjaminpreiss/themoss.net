# Updating a deployed machine

**Updates do not repartition disks.** Use the install path only for a new machine, not for repairs. This guide covers both switching an existing NixOS host and proposing pinned dependency updates. For the initial install, see the [deployment guide](deployment.md).

## Switch a reviewed revision

The target needs a consumer Git checkout with its trusted `origin`, a private machine directory and a root-owned state directory. For new installs, bootstrap initializes `STATE_DIR/revision` from the off-host install receipt; for previously deployed hosts, initialize it with the **40-character commit actually deployed**, not whichever commit happens to be on `main`. Keep the state file mode 0600.

```bash
bash toolkit/deploy.sh update REPO BRANCH PRIVATE_MACHINE_DIR HOST_OUTPUT STATE_DIR
# Or, if enabled in the consumer NixOS configuration:
systemctl start themoss-update.service
```

The update locks attempts, fetches the reviewed branch, requires the new commit to descend from the known-good revision, stages only committed source with the private machine files, and builds **before** `nixos-rebuild switch`. A failed fetch or build cannot reach switch; a failed switch may have partially activated services. State advances only on successful switch. Updates never call Disko.

For a candidate/branch install, keep `services.themossUpdate.timer = false` **in the installed candidate** and verify that no updater timer is present after boot. Do not manually start the service against old `main`. Bootstrap does not manage systemd units. Agentic can leave the timer off and update manually; the relay may opt in after validation.

### Candidate-to-main transition

After first-boot verification and a merge that retains the installed commit's ancestry, review the branch's NixOS configuration. The consumer prepares a **new**, credential-free `machine.nix` in `REVIEWED_MACHINE_DIR` (mode 0600): for the relay this changes `peerRelay.autoUpdate = true` in both the off-server copy and the reviewed target input. Agentic may keep its manual-update default. Then run explicitly from the operator's pinned toolkit checkout:

```bash
bash toolkit/deploy.sh transition PRIVATE_INSTALL_RECEIPT.json root@HOST /root/consumer main REVIEWED_MACHINE_DIR /root/private-machine HOST_OUTPUT /var/lib/themoss
```

Transition checks that the target's current revision and machine file still match the install receipt, uploads the reviewed file, fetches the requested branch, checks ancestry, stages the **new** private file, builds and switches; only after a successful switch does it replace the target's private file and advance known-good state. It does not choose update policy: the consumer owns the new file, and a timer appears only if that file and the reviewed branch's NixOS configuration enable it. No Disko, reset or silent rebaseline. If fetch/build fails, neither the private file nor revision advances; a failed switch may partially activate services. If a post-switch write fails, stop and inspect the host rather than assuming it is synchronized. A squash/rebase that loses ancestry fails closed: do not edit `revision` to make it pass. A separate reviewed, non-destructive rebaseline procedure would need to prove the running configuration and new baseline match before writing state; this toolkit does not implement one.

### Recover from a bad update

Stop the timer first: `systemctl disable --now themoss-update.timer`. Inspect `journalctl -u themoss-update -n 100` and `nixos-rebuild list-generations`. Use the provider console/boot menu or `nixos-rebuild switch --rollback`; diagnose and re-enable the timer deliberately. Keep known-good generations, but do not mistake on-server generations for off-server backups. A successful build cannot prove networking, safe boot or application health.

## Propose dependency updates through PRs

This repo hosts the [reusable workflow](../.github/workflows/lock-updates.yml), but **only consumer repos** install the update App, store its key in Actions secrets and own a schedule/dispatch caller. No update App credentials or installation belong in `themoss.net`. The consumer owns the schedule and calls the pinned workflow. It updates committed lockfiles, runs consumer-supplied tests, opens a PR and requests auto-merge only after checking the caller-named branch-protection requirements. It [audits the App permissions](app-permissions.md) first. A branch-protection API error or absent required check fails the auto-merge step; ruleset-only protection is not yet supported by that check.

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

Give the update App Contents and Pull requests write access, **no bypass**, and install it on only the repos you intend to manage. The workflow checks its permissions and scopes its tokens to the calling repo; it does not audit the App's total reach across other installations. Review that scope separately.

Here is the **complete prefilled GitHub App registration URL**. Inspect it before opening or submitting the form; it suggests a private App with webhooks and OAuth-on-install disabled, not a guarantee that those settings are enforced:

```text
https://github.com/settings/apps/new?name=themoss-consumer-lock-updates&description=Reviewed%20consumer%20lockfile%20PRs&url=https%3A%2F%2Fgithub.com%2Fbenjaminpreiss%2Fthemoss.net&public=false&webhook_active=false&request_oauth_on_install=false&contents=write&pull_requests=write
```

The App token triggers PR CI where the default `GITHUB_TOKEN` normally would not. Protect the consumer branch, enable auto-merge, and alert on failed/stalled workflows and host updates. **Auto-merging dependencies is a path to root-level OS code**; checks do not replace review, staged rollout or recovery.
