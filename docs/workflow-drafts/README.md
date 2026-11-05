# Workflow handoff

A GitHub App without `workflows` permission cannot update `.github/workflows/`. A maintainer should copy [`generate-cli-docs.yml`](generate-cli-docs.yml) over `.github/workflows/generate-cli-docs.yml` on `feat/issue-14-manifest` and commit that replacement. The only change from the active workflow is `docs/cli-spec` → `docs/spec` in the `git add` step.

`ci.yml` and `lock-updates.yml` are already installed in `.github/workflows/` and do not need replacing. Remove this temporary draft directory after the workflow is installed.
