# Update a deployed machine

**Updates do not erase disks.** For a new machine, start with [Deploy a machine](deployment.md).

## Switch to a reviewed revision

```bash
moss update REPO BRANCH PRIVATE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

The target needs a root-owned consumer checkout, private machine directory and state directory. Bootstrap creates `STATE_DIR/revision` from the install receipt.

**Update stops if:** the fetch or build fails, or the branch no longer descends from the known-good revision. It switches NixOS *before* advancing that revision. A failed switch may still have partially activated services.

For older hosts, initialize `STATE_DIR/revision` (mode 0600) to the commit **actually deployed**, not the head of `main`.

## Move a tested candidate to `main`

**Before the transition:**

1. Install the candidate with its updater timer **off**. Confirm the timer is absent at first boot; bootstrap does not manage it.
2. Validate the host. Merge its installed commit into the reviewed branch without rewriting its history.
3. Prepare a reviewed, credential-free `machine.nix` in `REVIEWED_MACHINE_DIR` (mode 0600). The relay may enable automatic updates here; agentic may keep manual updates.

Then run:

```bash
moss transition generated/install-receipt.json root@HOST /root/consumer main REVIEWED_MACHINE_DIR /root/private-machine HOST_OUTPUT /var/lib/themoss
```

**Transition checks** the target's current revision and machine file against the receipt. It uploads the reviewed file, fetches `main`, checks ancestry, then builds and switches. Only after a successful switch does it save the new private file and revision on the target. The *consumer's* configuration decides whether a timer exists.

- **Fetch or build failed?** The old file and revision stay put.
- **Switch or later write failed?** Inspect the host before retrying; services may already have changed.
- **Squash/rebase removed the installed commit from `main`?** Transition refuses to proceed. Never edit `revision` or rerun the disk installer to bypass that check. No rebaseline operation is provided.

## Recover from a bad update

Stop an enabled timer. Inspect `journalctl -u themoss-update -n 100` and `nixos-rebuild list-generations`, then use SSH or the provider console to roll back. Re-enable updates only after diagnosing the failure. **NixOS generations are not off-server backups.**

## Propose dependency updates via PRs

The [reusable workflow](../.github/workflows/lock-updates.yml) belongs in a **consumer's** GitHub Actions caller. The consumer supplies its App credentials, schedule, tests and required checks. See [App permissions](app-permissions.md) before enabling it.

A minimal caller job (replace every placeholder with reviewed consumer values):

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

**Run it manually before scheduling.** The reusable job installs Nix with pinned `cachix/install-nix-action` v31. The commands run **inside that job**, not in earlier caller steps; provide other toolchains in consumer configuration or the commands. For example, the relay needs Cargo 1.95 rather than the runner default.

The workflow opens a PR and checks **classic branch protection** before requesting auto-merge; ruleset-only protection is not covered by this check. CI runs `bash tests/consumer-commands.sh` using a synthetic machine flake to check the Nix command shape. It cannot verify a real host, App authentication or scheduled execution. Test the pinned workflow with each consumer's actual locks, toolchains and App before relying on it.
