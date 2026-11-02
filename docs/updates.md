# Choose what your machine follows

A machine can stay on one commit or follow one branch. The update timer is **always active**; the choice is stored on the host, outside the source it fetches.

| Selection | When the timer fires |
| --- | --- |
| `commit:FULL_SHA` | 🔒 Nothing: no fetch, build or switch. |
| `branch:NAME` | 🔎 Check *only that branch*. If its tip is unchanged, do nothing. |

Bootstrap starts with a commit pin. **No push can update the machine until an operator explicitly chooses a branch.** For example, following `branch:candidate` ignores pushes to `main`.

> ⚠️ **Tracking a branch trusts future pushes to that branch as potential OS updates.** Protect it with your own review and checks. A successful build does not prove a safe boot.

## Make a selection

Run these commands **as root on the target**, using its root-owned consumer checkout and private machine directory:

```bash
# Keep the machine pinned to a full commit already in the local checkout.
bash toolkit/deploy.sh deploy REPO commit:FULL_SHA MACHINE_DIR HOST_OUTPUT STATE_DIR

# Follow the current pushed tip of a reviewed branch.
bash toolkit/deploy.sh deploy REPO branch:candidate MACHINE_DIR HOST_OUTPUT STATE_DIR
```

A commit pin may be an unmerged candidate. A later *explicit* branch transition could replace it; review that change carefully.

For a branch, deployment fetches only the selected tip, verifies that it descends from the installed revision, builds it and checks **again** that the tip has not moved before switching. If it moved, retry rather than installing a different commit. Even a selector change with an unchanged tip requires a successful switch.

The timer runs the same branch checks through `poll`; you can also invoke it manually:

```bash
bash toolkit/deploy.sh poll REPO MACHINE_DIR HOST_OUTPUT STATE_DIR
```

## Change branches after a squash or rebase

Ordinary polling **refuses divergent history**. Do not edit the recorded revision to make it pass. Instead, review the new tip and a credential-free `machine.nix`, then use the explicit, non-destructive transition:

```bash
bash toolkit/deploy.sh transition INSTALL_RECEIPT root@HOST REMOTE_REPO BRANCH REVIEWED_MACHINE_DIR REMOTE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Transition verifies the install receipt against target state, builds the proposed branch tip with the reviewed machine file, rechecks the tip and switches **without Disko**. Only after a successful switch does it save the new machine file, selector and revision. A receipt-bound transition cannot be repeated after its baseline changes; a later rebaseline needs another reviewed procedure.

## Bring an existing host forward

> 🛑 **Do not enable the new timer on a legacy host yet.** A host with only `STATE_DIR/revision` fails closed; merging this toolkit PR does not change a live machine.

1. Stop the old updater. Through the console, confirm the **revision actually installed** and compare it with `STATE_DIR/revision`.
2. Update the consumer's pinned toolkit and NixOS module to use `poll`; remove the old `branch` and `timer` options.
3. As root, pin the verified revision:

   ```bash
   bash toolkit/deploy.sh migrate STATE_DIR commit:ACTUALLY_INSTALLED_FULL_SHA
   ```

4. Enable the timer. It now fires harmlessly in commit mode. Select a branch with `deploy` or a reviewed transition **only when ready**.

Migration accepts only the revision already recorded. If that differs from the running machine, **stop and investigate** rather than changing state by hand.

## If an update fails

- **Fetch, validation or build failed?** The running generation and recorded selection/revision stay unchanged.
- **Switch started, then failed?** Services may be partly activated. The toolkit leaves `STATE_DIR/needs-inspection` to block further automation.

For an uncertain switch:

- [ ] Stop the timer and inspect `journalctl -u themoss-update -n 100`, `nixos-rebuild list-generations`, the running system and both state files.
- [ ] Recover or roll back through SSH or the provider console. **NixOS generations are not off-host backups.**
- [ ] Only after confirming the recorded selector and revision match the recovered generation, remove `needs-inspection` and resume.

### Who owns the state?

`STATE_DIR` must be root-owned and mode `0700`. It holds `selector` (mode `0600`), `revision` (the last successfully switched full SHA), a shared operation lock and, when needed, `needs-inspection`. Keep it **outside the fetched checkout and Nix store**. Polls, deployments and transitions serialize; none repartitions disks or overwrites secrets. Keep credentials out of staged `machine.nix` and `facter.json`—Nix store inputs can be world-readable.

The consumer owns branch protection, timer cadence, private machine generation, credentials and CI policy. Pin the toolkit separately in the consumer's `flake.lock`; a webhook-supplied SHA is *not* deployment authority. For dependency-update PRs rather than host polling, see the [reusable workflow](../.github/workflows/lock-updates.yml) and [App permissions](app-permissions.md).
