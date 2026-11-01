# Audit the lock-update App

The dependency-update workflow uses a GitHub App to open PRs. Before it updates anything, it checks that the App has **exactly the permissions the consumer expects** and that its installation can access **only the calling repository**. A mismatch stops the workflow.

This is a permission audit—not a merge authorization gate.

## Set the expected permissions

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

List every permission GitHub actually grants, including `metadata`. The workflow supplies its own `GITHUB_REPOSITORY` to the auditor; **do not specify repositories in this file**. The auditor requires **one App installation**, containing that repository and no others. A private key can mint tokens for *any* installation of its App, so both additional installations and additional repositories fail the check. Use a dedicated App per consumer.

Review changes to App access and this policy together. Don't change the policy merely to silence an unexpected failure.

## What the workflow checks

[`.github/workflows/lock-updates.yml`](../.github/workflows/lock-updates.yml) runs the audit before dependency updates. The caller supplies the policy path, App secrets and an immutable toolkit revision; see the [caller example](updates.md#propose-dependency-updates-through-prs).

The read-only [`audit-app.sh`](../toolkit/audit-app.sh) compares the policy to permissions reported for the **App registration**, the **installation** and a newly issued **installation token**. All three must match exactly; narrowing a token cannot conceal excess App permissions. It enumerates all App installations and requires exactly the caller's installation; then it paginates that installation's repositories and requires exactly `[GITHUB_REPOSITORY]`. Missing data, API errors and differences fail the audit.

After that check, the workflow creates its working token limited to the caller repo and Contents/Pull requests write. The App key comes from the consumer's Actions secret; the audit briefly puts it in a mode-0600 runner file for OpenSSL and removes that file when the step ends. It is **not** copied to a deployment target.

Run `bash tests/audit.sh` for credential-free permission, installation and repository drift fixtures, then test the real App with `workflow_dispatch` before enabling a schedule. Synthetic tests cannot establish what GitHub will return for your installation.

## Who can change or merge workflows?

This App has **no Workflows write permission**: GitHub rejected its attempt to push `.github/workflows/` files. That does **not** establish a human-approval rule for PRs changing workflows. The App has Contents and Pull requests write permissions, so do not assume it cannot request or perform a merge of an otherwise mergeable workflow-changing PR. Protect `.github/workflows/**` with CODEOWNERS, require code-owner/human review in branch rules, require checks, and give the App **no bypass**. Verify the effective rules and test merge denial with the actual App; this audit does not inspect or enforce them. The lock-update workflow itself stages only lockfiles, but a stolen key could be used elsewhere.

GitHub permissions are **not workflow-scoped**. Another workflow allowed to read the same secret—or anyone with the private key—can mint a token outside this workflow. Restrict secret access, review workflow/policy edits, monitor failures and rotate a compromised key. If a key already lives on a server, the audit can run there too; don't move an Actions-only key onto a server just to run it.
