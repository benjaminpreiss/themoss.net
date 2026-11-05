# Developing the `moss` CLI

Edit [`src/`](src/README.md), **not** [`bin/`](bin/README.md). The public entry point is `src/moss.sh`; command bodies live in `src/machine/{plan,apply,bootstrap}/`. The shared `src/machine/helpers/store.sh` resolves Git-root `.moss/<target>/` defaults, enforces Git-ignore and owns the per-target latest-plan reference. The planner's `configure.sh` prompts for first-use operator-local configuration when the default is missing; it probes whole disks read-only and records a single candidate or asks the operator to select one. Erase consent remains in `apply`. `src/machine/deploy.sh` holds shared probe/staging/selector checks and private target protocol. `src/machine/update.nix` defines scheduled polling. The [GitHub App audit](../github-app-audit/README.md) is a separate package.

## Build and verify

```bash
nix develop --no-write-lock-file .#dev
bash packages/cli/build.sh
bash tests/argc.sh
bash tests/test.sh
```

`build.sh` is the documentation generator: it expands `# @include` fragments, builds standalone argc executables, exports JSON specs under [`docs/spec/`](../../docs/spec/) and renders the [CLI reference](../../docs/cli-reference.md). `helpers/export-spec.sh` omits empty `author: null` metadata so otherwise identical argc versions produce the same committed JSON. `tests/argc.sh` independently rebuilds and compares those artifacts; it does not publish documentation. The target needs neither argc nor project sources at runtime. `.#operator` supplies runtime tools **without argc**; `.#dev` adds the pinned generator. Commit generated files with their sources; `tests/argc.sh` checks byte-for-byte drift. Opt into the Bash pre-commit hook with `git config core.hooksPath .githooks` (shared across linked worktrees).

## Generated specs

| Editable source | Committed executable | Generated spec |
| --- | --- | --- |
| `src/moss.sh` + command fragments | `bin/moss` | `docs/spec/cli/moss.json` |
| `src/machine/deploy.sh` + fragments | `bin/machine/deploy.sh` | `docs/spec/cli/machine/deploy.json` |
| `src/machine/bootstrap/remote.sh` | `bin/machine/bootstrap/remote.sh` | `docs/spec/cli/machine/bootstrap/remote.json` |
| `../github-app-audit/src/audit-app.sh` | `../github-app-audit/bin/audit-app.sh` | `docs/spec/github-app-audit/audit-app.json` |

Only `bin/moss` is a public operator command; private SSH and target-side verbs must not appear in its command tree.

> ⚠️ `.github/workflows/generate-cli-docs.yml` currently stages the **old** `docs/cli-spec/` location. A maintainer with workflow-write permission must update that path to `docs/spec/` when this change lands; the GitHub App cannot edit workflow files.
