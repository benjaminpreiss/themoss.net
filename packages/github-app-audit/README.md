# GitHub App permissions audit

This package audits the installation and scoped token permissions of the GitHub App used for dependency-update PRs. It is unrelated to machine installation or the `moss` operator CLI.

Edit `src/audit-app.sh` (argc-annotated) and run `bash packages/cli/build.sh` to produce the standalone `bin/audit-app.sh` and `docs/cli-spec/audit-app.json`. Do not edit the generated script. The workflow invokes `bin/audit-app.sh`; `bash tests/audit.sh` exercises its policy fixtures.

## Audit the lock-update App

The dependency-update workflow uses a GitHub App to open PRs. Before it updates anything, it checks the permissions granted to the **calling repository's installation** and its caller-scoped token. A mismatch stops the workflow. Other repositories may share the App or installation.

This is a permission audit—not a merge authorization gate.

### Set the expected permissions

Commit `.github/app-permissions.json` in each **consumer** repository:

```json
{
  "permissions": {
    "contents": "write",
    "pull_requests": "write",
    "metadata": "read"
  }
}
```

List every permission GitHub actually grants, including `metadata`. The workflow supplies its own `GITHUB_REPOSITORY` to the auditor; **do not specify repositories in this file**. The policy checks the caller's installation and token, not the App's global grants or access across other repositories. A private key can mint tokens for other installations too, so administrators must review that wider scope separately.

Review changes to App access and this policy together. Don't change the policy merely to silence an unexpected failure.

### What the workflow checks

The [lock-update workflow](../../.github/workflows/lock-updates.yml) runs the audit before dependency updates. The caller supplies the policy path, App secrets and an immutable toolkit revision; see the [machine update policy](../cli/src/machine/README.md#updates-and-recovery).

The read-only [`audit-app.sh`](bin/audit-app.sh) verifies the App's identity, then compares the policy to permissions reported for the **caller's installation** and a newly issued **installation token**. Both must match exactly; token narrowing cannot hide extra permissions approved for this installation. It requests an **audit token restricted to the caller repo**, then paginates that token's visible repositories and requires exactly `[GITHUB_REPOSITORY]`. It does not fail merely because the App or installation also covers other repositories. Missing data, API errors and differences fail the audit.

After that check, the workflow creates its working token limited to the caller repo and Contents/Pull requests write. The App key comes from the consumer's Actions secret; the audit briefly puts it in a mode-0600 runner file for OpenSSL and removes that file when the step ends. It is **not** copied to a deployment target.

Run `bash tests/audit.sh` for credential-free identity, installation-permission and token-scope fixtures, then test the real App with `workflow_dispatch` before enabling a schedule. Synthetic tests cannot establish what GitHub will return for your installation.
