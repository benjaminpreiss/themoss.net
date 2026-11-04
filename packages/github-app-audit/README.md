# GitHub App permissions audit

This package audits the installation and scoped token permissions of the GitHub App used for dependency-update PRs. It is unrelated to machine installation or the `moss` operator CLI.

Edit `src/audit-app.sh` (argc-annotated) and run `bash packages/cli/regenerate.sh` to produce the standalone `bin/audit-app.sh` and `docs/cli-spec/audit-app.json`. Do not edit the generated script. The workflow invokes `bin/audit-app.sh`; `bash tests/audit.sh` exercises its policy fixtures.
