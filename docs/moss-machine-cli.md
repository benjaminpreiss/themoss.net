# `moss machine` command contract

> Implemented in [PR #15](https://github.com/benjaminpreiss/themoss.net/pull/15), not yet merged or deployed. See [ADR 0001](adr/0001-public-machine-cli.md) and the [machine guide on the PR branch](https://github.com/benjaminpreiss/themoss.net/blob/feat/issue-14-manifest/packages/cli/src/machine/README.md). The earlier [CLI guideline findings](cli-guidelines-findings.md) describe the alternatives considered; this command contract supersedes their preliminary install naming recommendation.

## Public operator commands

```bash
# From the consumer Git checkout: add .moss/ to .gitignore and commit it.
# First use asks for source/policy choices and probes whole disks read-only;
# propose the only disk or ask which one to use. Save an operator-local
# machine.json and typed install plan under .moss/root@HOST/ without erasing.
moss machine plan root@HOST

# Revalidate, rebuild, run consumer checks and require typed disk identity
# immediately before the installer. Writes an off-host install receipt.
moss machine apply --target root@HOST

# Verify the new installed SSH host key independently before first-boot setup.
# This handoff is retryable and never calls the installer.
moss machine bootstrap "$(git rev-parse --show-toplevel)/.moss/root@HOST/install-receipt.json"

# On an installed, branch-tracking host: build an exact reviewed tip, check
# the root-owned selector, and save a type: update plan (no disk action).
moss machine plan root@HOST

# Revalidate the reviewed tip and selector under the target lock; build and
# switch without running Disko. Divergence requires a separate transition.
moss machine apply --target root@HOST
```

`moss` is the public entry point (generated executable `packages/cli/bin/moss`). The operator's mode-600 JSON declares pinned source, policy paths and the reviewed whole-disk candidate, not a second Nix machine definition. By default `plan` finds the consumer checkout's Git root, refuses an unignored `.moss/` directory and interactively creates `.moss/root@HOST/machine.json` on first use. Subsequent plans reuse it, write separate mode-600 JSON files under `plans/` and update a per-target `latest` reference only after success. `apply` requires `--target root@HOST` when several targets have plans; `--config`, `--output` and `--plan` (or a positional plan path) remain explicit overrides. A default plan never silently crosses targets. A complete evaluated storage diff requires consumer-provided checks; the CLI does not infer safe disk layout from generic Nix data. A sole detected disk is only proposed, not authorized for erasure. Applying an install plan *always* requires a new typed disk confirmation and re-probe. A failed or uncertain switch blocks further automatic updates until inspection.

## Internal protocol and future work

The root-owned update timer, internal deploy/transition operations and SSH prepare/apply messages remain implementation details, not public verbs. A newly bootstrapped host starts commit-pinned. Moving it to a tracked branch is a **separately reviewed transition**; the public `plan` refuses to perform that policy change automatically. Adopting a legacy host, transitioning branches, replacing a failed disk, restoring a backup, status/actions/job JSON, and a web-management protocol need additional interfaces and tests; **do not present them as shipped commands**.

A browser or relay must not execute arbitrary CLI strings. A future host management service should validate authenticated, signed, typed, fresh requests and expose structured status, proposals and operation progress. CLI help/JSON/Markdown are generated from argc; the command schema alone is not a management authorization or a substitute for the recovery runbook.
