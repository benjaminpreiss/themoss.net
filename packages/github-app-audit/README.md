# GitHub App permissions audit

The [lock-update workflow](../../.github/workflows/lock-updates.yml) audits the GitHub App **before** it opens dependency-update PRs. The check is read-only: a permission mismatch stops the workflow, but a successful audit is **not merge authorization**. This package is separate from the `moss machine` operator CLI.

## Configure the caller's policy

Commit `.github/app-permissions.json` in each **consumer repository**:

```json
{
  "permissions": {
    "contents": "write",
    "pull_requests": "write",
    "metadata": "read"
  }
}
```

List *every* permission GitHub grants, including `metadata`. The workflow supplies its own `GITHUB_REPOSITORY`; **do not list repositories in the policy file**. Review changes to App access and this policy together—do not update the file merely to silence an unexpected failure.

> 🔒 **Scope matters.** This policy checks the calling repository's installation and its scoped token, *not* the App's global grants. An App key can mint tokens for other installations; administrators must review that wider scope separately.

## What the audit verifies

The caller supplies the policy path, App secrets and an immutable toolkit revision. [`bin/audit-app.sh`](bin/audit-app.sh) then:

1. Verifies the App identity.
2. Compares the expected permissions with **both** the caller's installation and a newly issued installation token. Token narrowing cannot mask extra installation permissions.
3. Requests an audit token restricted to the caller repository, paginates the repositories visible to that token and requires exactly `[GITHUB_REPOSITORY]`.

Other repositories may share the App or installation; the audit does not reject them solely for that reason. Missing data, API errors or a mismatch **fail closed**. After the audit, the workflow mints its *working* token restricted to the caller repository and Contents/Pull requests write. The App key comes from the consumer's Actions secret, lives briefly in a mode-0600 runner file for OpenSSL and is removed after the step. **It never goes to a deployment target.**

## Verify and maintain

- Run `bash tests/audit.sh` for credential-free identity, permission and token-scope fixtures. Then test the **real App** with `workflow_dispatch` before enabling a schedule; mocks cannot establish what GitHub will return.
- Edit `src/audit-app.sh` (argc-annotated), then run `bash packages/cli/build.sh` at the repository root to regenerate standalone `bin/audit-app.sh` and `docs/spec/github-app-audit/audit-app.json`. Never hand-edit the generated script.

For machine update policy—not App permissions—see the [machine guide](../cli/src/machine/README.md#update-an-existing-machine).
