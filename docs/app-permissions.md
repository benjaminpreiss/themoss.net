# Audit the lock-update App's permissions

`toolkit/audit-app.sh APP_ID PEM_FILE POLICY_JSON OWNER/REPO` is a **read-only permission/scope check**, not a ruleset auditor or merge gate. It signs a short-lived JWT and reads `GET /app` (App permission grants), `GET /repos/OWNER/REPO/installation` (installation grants), mints an installation token (token grants), and paginates `GET /installation/repositories` to check the entire installation scope. All three permissions objects must equal the policy exactly; every accessible repository must be listed in the policy and vice versa. Any HTTP, schema, or pagination error fails the check. It never prints the key, JWT, token, or response bodies. Run `bash tests/audit.sh` for synthetic fixtures (App/installation/token drift and surprise repo).

Keep a credential-free policy JSON **in each consumer repo**, e.g. `.github/app-permissions.json`:

```json
{
  "permissions": { "contents": "write", "pull_requests": "write", "metadata": "read" },
  "repositories": [ "benjaminpreiss/thepeer.stream" ]
}
```

List every permission actually reported by GitHub (including implicit `metadata`), and every repository on that installation. For separate consumers use separate installations/policies; a shared installation requires each consumer policy to explicitly list the same complete set. Audit before dependency updates run; a changed installation or App registration must be reviewed and the policy updated deliberately. Limit the **workflow's minted token** to the caller repository and Contents/PR write even when the installation contains more repos. The script also checks the full App and installation grants: down-scoping a token cannot hide excessive permissions on the App or its private key.

**Actions integration:** `workflow-templates/lock-updates.yml` shows the audit before App token creation. A maintainer with workflow-write permission must replace `.github/workflows/lock-updates.yml` with that template; the coding App cannot push workflow changes. The caller passes a full immutable toolkit commit as `toolkit-revision` matching the `uses: ...@SHA` reference, plus its policy path and App secrets. The template checks out the pinned toolkit to read the audit script, and checks out the consumer separately; it does **not** fetch scripts with `curl`. The key exists only as a caller Actions secret (briefly materialized in a mode-0600 temp file for OpenSSL), never on a target host or in Nix/store. Protect the workflow and policy from unreviewed edits. App secrets are not literally exclusive to this one workflow: any authorized workflow able to read the same repository secret can use them. An attacker with the private key can mint a different token outside this workflow. Reduce that risk with narrow installation scope, branch rules without App bypass, review of workflow changes, secret access controls, alerts and key rotation. Required-check branch protection in the lock-update workflow is a separate safety requirement; it does not constrain token provenance.

If a consumer's App key already lives on a server for unrelated reasons, the script can run there with the same policy and alerting, but **do not move an Actions-only private key onto a server just to run this audit**. An administrator must still independently review actual bypass rights/branch protection; a permission audit cannot prove an App may merge only workflow-created PRs.
