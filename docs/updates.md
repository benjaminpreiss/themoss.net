# Track a commit or a branch

The timer stays active whenever `services.themossUpdate.enable = true`. Its root-owned selector, **not a branch configured in the flake**, determines whether it can update the host. The consumer owns the cadence, branch protection, credentials, private machine generation and CI policy. Pin the toolkit separately in the consumer's `flake.lock`.

`STATE_DIR` (mode 0700) contains `revision` (last successfully switched full SHA), `selector` (mode 0600, `commit:FULL_SHA` or `branch:NAME`), `lock` and, after an uncertain switch, `needs-inspection`. These files must live outside the fetched checkout and Nix store. Bootstrap creates a `commit:` pin from the install receipt. Nothing polls autonomously until an operator selects a branch. The timer may fire before bootstrap: it fails closed on missing state.

## Operator commands (run as root on the target)

```bash
bash toolkit/deploy.sh deploy REPO commit:FULL_SHA MACHINE_DIR HOST_OUTPUT STATE_DIR
bash toolkit/deploy.sh deploy REPO branch:candidate MACHINE_DIR HOST_OUTPUT STATE_DIR
bash toolkit/deploy.sh poll REPO MACHINE_DIR HOST_OUTPUT STATE_DIR
```

A commit pin has no autonomous fetch, build or switch. `deploy` pins an existing local full commit; it warns if moving from the installed commit to an unmerged candidate. To select a branch, `deploy` fetches **only its pushed tip**, requires that it descend from the installed revision, builds it and rechecks that the tip has not moved before switching. Even when the tip equals the installed SHA, changing a selector requires a successful switch. Polling a branch uses the same check, but skips an unchanged tip. A candidate branch ignores pushes to `main`. Protect branches appropriately: a build is not proof of a safe boot.

Do not use a webhook-supplied SHA as authority. A branch name is permission for future pushes to that branch to become OS updates. Run deployment from an operator-reviewed toolkit version; no fetched consumer source controls its selector.

## Explicit reviewed transition (including squash/rebase)

The receipt-bound, non-destructive transition can change a private machine file and select a new branch even when its pushed tip does **not** descend from the old revision:

```bash
bash toolkit/deploy.sh transition INSTALL_RECEIPT root@HOST REMOTE_REPO BRANCH REVIEWED_MACHINE_DIR REMOTE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Inspect and approve the new branch tip and credential-free `machine.nix` before running. Transition checks the receipt's installed revision and machine hash against target state, fetches the selected pushed tip, builds with the proposed file, checks the tip again and switches **without Disko**. It then persists the private file, revision and selector. This is the only supported rebaseline after a squash/rebase. Receipt-bound transitions cannot be repeated after the baseline changes; arrange a new reviewed procedure if a later rebaseline is needed. Never edit `revision` to bypass ancestry.

## Existing installations and recovery

Legacy installations with only `STATE_DIR/revision` fail closed. Verify the **actually running** generation and revision through the console; stop any old updater and update the pinned consumer configuration to use `poll` (remove the old `branch` and `timer` options). As root run:

```bash
bash toolkit/deploy.sh migrate STATE_DIR commit:ACTUALLY_INSTALLED_FULL_SHA
```

Migration accepts only the recorded revision as a commit pin. Inspect discrepancies before migrating. Use `deploy` or an explicit reviewed transition to enable branch tracking. Do not enable the new timer until this procedure is complete; deploying code alone does not change a live host.

Fetch, validation and build failures leave recorded state and the running generation alone. Once a switch begins, even a nonzero result may have partially activated services: `needs-inspection` blocks all future polls, deployments and transitions. Stop the timer, inspect `journalctl -u themoss-update -n 100`, `nixos-rebuild list-generations`, the running system and both state files; restore/roll back as needed. Only after confirming the recorded revision and selector match the recovered generation should the operator remove `needs-inspection` and resume. If a post-switch state write fails, inspect both files before recovery. NixOS generations are not off-host backups.

Poll, deploy, bootstrap and transition serialize through `STATE_DIR/lock` (transition upload preparation releases the lock during transfer; final application revalidates the baseline under lock). None invokes Disko or replaces secrets. Keep private keys out of staged `machine.nix` and `facter.json`: Nix store inputs are readable.

## Dependency updates

The [reusable PR workflow](../.github/workflows/lock-updates.yml) is separate from host polling. Consumers supply their App credentials, schedule, tests and required checks; see [App permissions](app-permissions.md). CI uses only local Git fixtures and mocked Nix/SSH, never a live host.
