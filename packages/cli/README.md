# `moss` CLI package

`bin/moss` is the public operator entry point. Its editable, argc-annotated source is `src/moss.sh`. Machine installation, scheduled updates and the private target protocol are grouped by command under `src/machine/` and built into standalone scripts in `bin/machine/`; they are **not** public operator or browser commands. The NixOS updater module lives next to the machine source. Deploy the package as a whole: `bin/moss` invokes its adjacent generated machine implementation.

See [`src/README.md`](src/README.md) and [`bin/README.md`](bin/README.md) for the source/build convention. `bash packages/cli/build.sh` assembles command fragments with `helpers/assemble.sh` and builds standalone Bash (no argc required at runtime), JSON specs in `docs/cli-spec/` and the public Markdown reference in `docs/cli-reference.md`. Edit the source, never the generated binaries; `bash tests/argc.sh` rejects drift. The CLI and machine implementation share one pinned repo revision. `nix develop --no-write-lock-file .#operator` runs the committed binaries without argc; `.#dev` adds argc to regenerate and verify them.

The supported plan types are `install` (known rescue target and explicitly chosen whole disk) and `update` (an installed branch-tracking host with an existing receipt). A branch transition, disk repair, existing-host adoption and restore are **not** public plan types. A fresh install still requires typed disk confirmation and a separate post-install SSH-host-key verification; an update never runs the disk installer. Safety and recovery instructions are human-authored in `docs/deployment.md` and `docs/updates.md`.

The unrelated GitHub App permission audit lives in [`../github-app-audit/`](../github-app-audit/), not in the machine CLI.
