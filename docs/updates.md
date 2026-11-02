# Update a deployed machine

Updates build and switch NixOS. **They do not partition or erase disks.** For the first install, see [Deploy a machine](deployment.md).

## Switch to a reviewed revision

On the target, keep a root-owned consumer checkout, a private machine directory and a state directory. Bootstrap creates the initial `STATE_DIR/revision` from the install receipt.

```bash
bash toolkit/deploy.sh update REPO BRANCH PRIVATE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Update fetches the branch and requires its new commit to descend from the known-good revision. It builds before `nixos-rebuild switch` and advances `STATE_DIR/revision` **only if switch succeeds**. A failed switch may still have partially activated services.

For existing hosts that were not bootstrapped with this toolkit, initialize the state file to the commit **actually deployed**, not the current head of `main`. Keep it mode 0600.

## Move a tested candidate to `main`

Install a test candidate with the consumer's updater timer **off**. Check on first boot that the timer is absent. Bootstrap does not change systemd policy; do not start the updater against old `main`.

After validating the host and merging the installed commit into the reviewed branch, prepare a new, reviewed, credential-free `machine.nix` (mode 0600). The relay can set `autoUpdate = true` in this file; agentic can leave manual updates in place.

```bash
bash toolkit/deploy.sh transition generated/install-receipt.json root@HOST /root/consumer main REVIEWED_MACHINE_DIR /root/private-machine HOST_OUTPUT /var/lib/themoss
```

Transition checks the receipt against the target's current state. It uploads the new machine file, fetches `main`, checks ancestry, builds and switches. **Only after a successful switch** does it replace the target's private file and advance the known-good revision. The consumer's reviewed configuration—not this command—decides whether a timer exists.

If fetch or build fails, the old private file and revision stay put. If switch or a later write fails, inspect the host before retrying: services may already have changed.

A squash or rebase that removes the installed commit from `main` is rejected. Do not edit `revision` or rerun the disk installer to bypass this check. A non-destructive rebaseline would require a separate reviewed procedure; none is provided here.

## Recover from a bad update

Stop an enabled timer, inspect `journalctl -u themoss-update -n 100` and `nixos-rebuild list-generations`, then use SSH or the provider console to roll back. Re-enable updates only after diagnosing the failure. Keep off-server backups; NixOS generations are not backups.

## Propose dependency updates via PRs

The [reusable workflow](../.github/workflows/lock-updates.yml) runs in a **consumer** repository. That repo owns its App credentials, schedule, tests and required checks. This toolkit stores no App credentials and does not run `nix flake update` on a target. See [App permissions](app-permissions.md) before enabling it.

For a consumer caller, replace the revisions, tests and check names with reviewed values:

```yaml
jobs:
  update:
    uses: benjaminpreiss/themoss.net/.github/workflows/lock-updates.yml@REVIEWED_FULL_COMMIT
    with:
      toolkit-revision: 'REVIEWED_FULL_COMMIT'
      app-policy-file: '.github/app-permissions.json'
      update-command: 'nix flake update && cargo update'
      test-command: 'bash tests/test-deployment.sh'
      required-checks: 'Build and test / OS'
    secrets:
      APP_ID: ${{ secrets.UPDATE_APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.UPDATE_APP_PRIVATE_KEY }}
```

The workflow opens a PR and checks classic branch protection before requesting auto-merge. Test it with `workflow_dispatch` before scheduling it. A passing build is not proof that an OS update will boot or preserve network access.
