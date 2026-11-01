# Audit the lock-update App

The dependency-update workflow uses an App to open PRs. Before doing so, it checks that the App has **exactly the permissions and repository access the consumer expects**. A mismatch stops the workflow.

This is a permission audit—not a ruleset audit and not a guarantee that the App can act only from this workflow.

## Set the expected access

Commit `.github/app-permissions.json` in the **consumer** repository:

```json
{
  "permissions": {
    "contents": "write",
    "pull_requests": "write",
    "metadata": "read"
  },
  "repositories": ["benjaminpreiss/thepeer.stream"]
}
```

List **every** permission GitHub grants, including `metadata`, and **every** repository accessible to that installation. The example is not a universal policy: edit it to match the actual App. A shared installation needs the same complete repository list in each consumer's policy. Prefer a separate installation per consumer when possible.

To change the App's access, review the change and its policy update together. Do not change the policy just to silence an unexpected audit failure.

## What the workflow checks

[`.github/workflows/lock-updates.yml`](../.github/workflows/lock-updates.yml) runs the audit **before** updating dependencies. The caller supplies the policy path, App secrets and an immutable toolkit revision; see the [caller example](deployment.md#dependency-update-workflow).

The read-only [`audit-app.sh`](../toolkit/audit-app.sh) compares the policy against:

1. The permissions on the App registration, installation and newly issued installation token. **All three must match exactly.** A restricted token cannot conceal excess permissions on the App itself.
2. The complete, paginated list of repositories accessible to that installation. No extra or missing repositories are accepted.

Missing data, an API error or a mismatch fails the audit. The workflow then creates a token limited to the **caller repository** with Contents and Pull requests write access. It never copies the App key to a deployment target. The key comes from the consumer's Actions secret; the audit briefly puts it in a mode-0600 runner file for OpenSSL and removes that file when the step ends.

Run the credential-free fixtures with `bash tests/audit.sh`. They cover App, installation and token permission drift, plus an unexpected repository. **They do not verify GitHub's live API or a consumer's real App**; perform an initial `workflow_dispatch` and inspect its result before enabling a schedule.

## What this does not protect

GitHub permissions are **not workflow-scoped**. Another workflow allowed to read the same secret—or anyone with the private key—can mint a token outside this workflow. Protect workflow and policy changes, restrict installation scope, monitor failures and rotate a compromised key. Branch protection and required checks are separate merge safeguards, not proof of where a token came from. An administrator should independently inspect App bypass rights.

The script can also run on a server **if the key already belongs there**, but do not move an Actions-only key onto a server just to audit it. The lock-update workflow performs its own audit on each run.
