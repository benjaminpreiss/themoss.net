# Proposed `moss machine` command contract

> **Design, not shipped commands.** The current interface remains `toolkit/deploy.sh`; this proposal is for its future public replacement. See [ADR 0001](adr/0001-public-machine-cli.md) and the [current deployment runbook](deployment.md).

## First release: existing machine lifecycle only

| Operator intent | Proposed command | Effect |
| --- | --- | --- |
| Identify one rescue target and whole disk | `moss machine discover --target root@HOST --disk /dev/vda --record /private/record.json` | Write a private discovery record; do not erase. Disk is explicit, never auto-selected. |
| Author private operator state | `moss machine manifest create /private/operator.json` | Interactively write a new off-host manifest; do not copy it to the host. |
| Review an installation | `moss machine plan /private/operator.json` | Re-probe and show target, NIC, whole-disk identity, exact pushed revision, output and paths; no disk mutation. |
| Install a new machine | `moss machine install /private/operator.json` | Repeat the plan, stage/build, run the consumer pre-erase check, require **typed disk identity**, re-probe and recheck pushed tip, then install. The **only** disk-erasing command in this release. |
| Finish first boot | `moss machine bootstrap /private/operator.json` | Verify receipt and original facts; retryable, never repartitions. Requires independent verification of the *new* SSH host key. |
| Bring a verified legacy host under management | `moss machine adopt …` | Compare evidence with the actual running closure; never repartitions. Specify the evidence/input interface before implementation. |
| Change a reviewed baseline | `moss machine transition /private/operator.json` | Propose new machine input and candidate branch, enforce the installed receipt baseline; never repartitions. |

The existing on-host `poll`, `migrate`, and SSH `prepare-transition`/`apply-transition` are **internal protocol**, not first-class operator verbs. The updater remains root-owned and fail-closed. Its transport and invocation from `update.nix` must be migrated together with the CLI; don't expose a compatibility alias merely to make the rename pass. `audit-app.sh` is a separate automation audit, not a machine operation.

## Interface rules

- A positional argument identifies the subject (such as a manifest); optional values get named flags. `--help` at every command level and a versioned machine-readable command schema come from the same argc command tree. Generate Markdown from the exported JSON. Keep operational runbooks human-authored.
- Distinguish **plans** (read-only evidence for human review) from **applications** (effects). Human-readable output cannot be the authority for a destructive operation: revalidate disk, target, revision and receipt at execution time. A `--yes` flag may never waive disk identity confirmation. An eventual non-interactive installation needs a separate reviewed authorization design, not an implied default.
- Keep credentials out of argv, the manifest, the Nix store and generated docs. Never shell-source untrusted JSON. Structured plan/result formats must be versioned when introduced, with stable keys, explicit error codes and stdout reserved for data.
- `update` means switching an **already installed** machine; `install` means a potentially destructive first install. Do not use a public `deploy` verb for both.
- A CLI command is not itself a management authorization. A future browser/proxy/VM flow must send typed signed requests to the hypervisor's validating service; it must not forward arbitrary shell commands or gain host execution from a transport connection.

## Deliberately not specified yet

Issue #1 describes storage, recovery, backup, service isolation and peer features at different stages of design. Do **not** publish `moss storage`, `moss backup`, `moss service` or `moss machine repair` as working commands until their policies, safe plans and tests exist. The current host filesystem direction is Btrfs RAID1 for multi-drive hosts; the older ZFS proposal is superseded. Tahoe-LAFS remains exploratory, not a CLI capability.

## Migration acceptance before shipping `moss`

1. Migrate every operator command, target-side timer, remote transport and synthetic test to the new entry point in one release; do not leave a silently working old positional public API.
2. Preserve exact pushed-tip verification, staged build, re-probe after confirmation, receipt matching, root-owned revision/selector, locking, interrupted-bootstrap retry and fail-closed inspection markers.
3. Run existing relay-like and agentic-like fixtures against the new executable. Test wrong disk/target, unsafe paths, lost SSH host-key trust, rejected pre-erase check and interrupted transition/bootstrap. There must be **no new path to `nixos-anywhere`** outside `machine install`.
4. Pin the new argc command tree in the Nix operator shell; generate standalone scripts, JSON spec and Markdown together, and reject drift in CI. Only remove the old interface once consumer callers are intentionally migrated.
