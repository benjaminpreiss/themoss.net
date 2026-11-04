# Choose what your machine follows

A machine can stay on one commit or follow one branch. The update timer is **always active**; the choice is stored on the host, outside the source it fetches.

| Selection | When the timer fires |
| --- | --- |
| `commit:FULL_SHA` | 🔒 Nothing: no fetch, build or switch. |
| `branch:NAME` | 🔎 Check *only that branch*. If its tip is unchanged, do nothing. |

Bootstrap starts with a commit pin. **No push can update the machine until an operator explicitly chooses a branch.** For example, following `branch:candidate` ignores pushes to `main`.

> ⚠️ **Tracking a branch trusts future pushes to that branch as potential OS updates.** Protect it with your own review and checks. A successful build does not prove a safe boot.

## Plan and apply a same-branch manual update

After bootstrap, the host starts pinned. A separately reviewed transition must first select branch tracking; `plan` must **not** change that policy or choose a replacement branch. Update the `revision` in your private off-host configuration to the current pushed tip of that same selected branch, then:

```bash
bash packages/cli/bin/moss machine plan root@HOST --config /private/machine.json --output /private/update-plan.json
bash packages/cli/bin/moss machine apply /private/update-plan.json
```

With an existing install receipt and no `--disk`, `plan` observes root-owned selector and revision, fetches only the selected branch and builds the exact candidate on the installed host. It saves a mode-600 `type: update` plan; no installer is called. `apply` rechecks the selector, recorded revision, target Git origin, private machine input hash, ancestry and exact branch tip while holding the update lock; it builds before switching. A changed tip or selector stops rather than deploying an unreviewed revision. Branch divergence and manual changes to the private machine input need a separate reviewed transition, not an update plan.

The scheduled timer uses the internal safe update implementation without requiring an off-host operator plan. It never runs Disko. A public transition or recovery plan is **not implemented**.

## Internal target-side selection protocol

The following retained commands are for pinned consumers and target-side policy maintenance, **not** the public operator CLI. Run them as root on the target, using its root-owned consumer checkout and private machine directory:

```bash
# Keep the machine pinned to a full commit already in the local checkout.
bash packages/cli/bin/machine/deploy.sh deploy REPO commit:FULL_SHA MACHINE_DIR HOST_OUTPUT STATE_DIR

# Follow the current pushed tip of a reviewed branch.
bash packages/cli/bin/machine/deploy.sh deploy REPO branch:candidate MACHINE_DIR HOST_OUTPUT STATE_DIR
```

A commit pin may be an unmerged candidate. A later *explicit* branch transition could replace it; review that change carefully.

For a branch, deployment fetches only the selected tip, verifies that it descends from the installed revision, builds it and checks **again** that the tip has not moved before switching. If it moved, retry rather than installing a different commit. Even a selector change with an unchanged tip requires a successful switch.

The timer runs the same branch checks through `poll`; you can also invoke it manually:

```bash
bash packages/cli/bin/machine/deploy.sh poll REPO MACHINE_DIR HOST_OUTPUT STATE_DIR
```

## Change branches after a squash or rebase

Ordinary polling **refuses divergent history**. Do not edit the recorded revision to make it pass. Instead, review the new tip and a credential-free `machine.nix`, then use the explicit, non-destructive transition:

```bash
bash packages/cli/bin/machine/deploy.sh transition INSTALL_RECEIPT root@HOST REMOTE_REPO BRANCH REVIEWED_MACHINE_DIR REMOTE_MACHINE_DIR HOST_OUTPUT STATE_DIR
```

Transition verifies the install receipt against target state, builds the proposed branch tip with the reviewed machine file, rechecks the tip and switches **without Disko**. Only after a successful switch does it save the new machine file, selector and revision. A receipt-bound transition cannot be repeated after its baseline changes; a later rebaseline needs another reviewed procedure.

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
