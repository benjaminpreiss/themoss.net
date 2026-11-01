# Optional target-side GitHub App ruleset audit

Consumers can import `inputs.themoss.nixosModules.appAudit` from their **flake-locked** toolkit. The NixOS module runs a read-only daily systemd timer (`themoss-app-audit.timer`) and a manual service (`systemctl start themoss-app-audit.service`). It authenticates with the consumer's own GitHub App installation, enumerates **all repositories accessible to that installation**, compares their exact set to the consumer policy and audits each default branch. Nothing is mutated. A nonzero service result is an audit failure; monitor `journalctl -u themoss-app-audit` and alert on missed runs and failures. One installation at a time: use a separate module instance or manual invocation for other installations.

Interface, on a consumer NixOS host:

```nix
{
  imports = [ inputs.themoss.nixosModules.appAudit ];
  services.themossAppAudit = {
    enable = true;
    appId = "12345"; installationId = "67890"; # public IDs, not credentials
    keyFile = "/etc/agentic/github-app/private-key.pem"; # root-only runtime PEM
    policyFile = "/etc/agentic/github-app/audit-policy.json"; # root-only runtime file
    interval = "daily";
  };
}
```

Never embed the PEM or policy values containing secrets in a Nix expression, stage or store. Transfer the PEM privately and protect it (0600 root-owned); the audit refuses symlinks. The policy itself contains only public settings but is read at runtime to keep policy release authority with the consumer. A relay whose App exists **only in Actions** should not transfer the key to the relay merely to use this audit: keep the audit on a separately trusted host or skip it. The GitHub App in `agentic` already has an on-host audit; its adoption PR should compare behavior before replacing that audit, rather than run two conflicting schedules.

Example `audit-policy.json` (the entries must be the **complete actual installation scope**, and token permissions must match exactly, including read-only or extra permissions such as `metadata`):

```json
{
  "permissions": { "contents": "write", "pull_requests": "read", "metadata": "read" },
  "repositories": {
    "benjaminpreiss/agentic": {
      "minApprovals": 1,
      "requiredChecks": ["Toolkit checks / fixtures"]
    }
  }
}
```

The audit fails closed for an unexpected/missing repo, permission drift, unreadable/incomplete API response, missing active default-only PR ruleset, PR rule covering other branches, missing default-branch effective required checks or stale-review dismissal, missing all-branch force-push/deletion rulesets or an explicit App bypass actor. For an unattended-update repo set `minApprovals: 0` **only if the human owner consciously accepts dependency auto-merge**; still specify nonempty required checks. Check names must match GitHub exactly. Authentication and audit use `curl`, `jq`, `openssl` and systemd-provided tooling; installation tokens and PEM never enter Nix/store, Git history or logs. Run `bash tests/audit.sh` for synthetic pass/failure fixtures without GitHub credentials.

**Limits:** Read-only API results do not prove actual push/merge rejection, an authorized reviewer's identity, role-based bypass visibility or reliable networking. An App may lack permission to view parent rulesets/bypass actors: the audit reports failure rather than PASS. Confirm rulesets and bypass roles with an administrator and test rejected direct pushes/merges using the actual App in a disposable branch. Alerting and remediation belong to the consumer; a PASS is a point-in-time snapshot, not permission enforcement. Do not give the audit App additional write permission just to make it pass.
