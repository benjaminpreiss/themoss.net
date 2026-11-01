# Consumer adoption (not performed by this PR)

Pin this toolkit by immutable full Git revision in each consumer flake and lockfile; test a candidate on a disposable VM before any host. Do **not** change a deployed host while bumping the pin. See [deployment](deployment.md) and [updates](updates.md) for the operator CLI.

| Consumer | Keep local | Replace only after tests pass |
| --- | --- | --- |
| thepeer.stream relay PR #4 | `record.json → machine.nix` generator, supported hardware/network choices, public-key selection, relay/Disko modules, private live data, branch/cadence policy, flake/Cargo locks | Generic discovery/preflight/install flow in `prepare.sh`, `preflight.sh`, `install.sh`; post-install copy/checkout/revision logic in `bootstrap.sh`; update shell glue in `toolkit.sh` where equivalent |
| agentic issue #30 | NixOS modules, private credential handling, source allowlist, manual-update default, lockfiles | Generic prepare/preflight/deploy and manual update orchestration after comparing staging and recovery behavior |

For each consumer: (1) review the pin PR and generated machine facts; (2) push the exact candidate revision to a branch, install only on a disposable VM using `install ... PUSHED_BRANCH`; (3) verify the **new** SSH host key at the console, then `bootstrap` with root-only paths and retry an interrupted upload; (4) assert the target revision equals the installed commit and the candidate timer is off; (5) merge to `main`, test `transition` without Disko and check known-good; (6) only then remove duplicated wrappers and enable the relay timer in a reviewed main configuration. If the merge rewrites history, transition must reject it; do not silently rebaseline. Neither consumer nor a deployed machine is modified by this repo's change.
