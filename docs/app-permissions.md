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

**We have not verified whether this App can merge a PR that changes `.github/workflows/`.** GitHub rejected this App's *direct push* of workflow files without Workflows write permission. GitHub's [create/update file endpoint](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents) separately documents a `workflow` scope for classic tokens changing those files. But the [merge PR endpoint](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request) lists Contents write for App installation tokens and does **not** say whether a workflow-changing PR has an additional restriction. Neither source proves what happens on merge.

Until tested, assume the App **might** merge such a PR when branch rules allow it. Require a human code-owner review for `.github/workflows/**` through CODEOWNERS and branch protection, required checks, and **no App bypass**; the audit does not verify those rules. To settle the API question, use a disposable repository and a **test App with the same permissions and branch rules**: have a different identity open a PR changing a harmless workflow, request a merge with a short-lived test-App installation token, and record the API status and effective rules. This tests GitHub's merge behavior without installing the real App on another repo or merging a consumer PR. It does not prove that the live repo's rules are configured correctly; verify those separately. The lock-update workflow itself stages only lockfiles, but a stolen key could be used elsewhere.

GitHub permissions are **not workflow-scoped**. Another workflow allowed to read the same secret—or anyone with the private key—can mint a token outside this workflow. Restrict secret access, review workflow/policy edits, monitor failures and rotate a compromised key. If a key already lives on a server, the audit can run there too; don't move an Actions-only key onto a server just to run it.
