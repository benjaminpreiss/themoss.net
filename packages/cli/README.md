# moss CLI package

`moss.sh` is the public operator entry point (`moss machine plan`, `apply`, `bootstrap`). `source/moss.sh` is its argc-annotated source. `internal/` contains the implementation, the NixOS updater module, and the retained positional protocol for already-pinned consumers. Do not expose the internal commands through an operator or browser interface.

The generated executable needs `internal/deploy.sh` (and its adjacent `bootstrap-remote.sh`) at runtime; deploy the entire `packages/cli/` package, not `moss.sh` alone. Regenerate after changing the annotated sources with `bash packages/cli/regenerate.sh` from the repository root in the pinned operator shell. Generated command JSON is in `docs/cli-spec/`; the public Markdown command reference is `docs/cli-reference.md`. Safety and recovery instructions remain human-authored in `docs/deployment.md` and `docs/updates.md`.

Currently supported plan types are `install` (known rescue target and explicitly selected whole disk) and `update` (already installed host, existing receipt and an unchanged tracked branch). Changing the baseline branch, replacing a disk, adopting a legacy machine, and restoring data are **not** public plan types. The target-side scheduled updater remains internal. An install still requires typed disk confirmation; an update never runs the installer.
