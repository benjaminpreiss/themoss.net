# Configuration and plans

`moss machine plan` uses **desired configuration** plus **observed target state** to create a typed plan. Both JSON files stay on the operator computer, must be mode `0600`, and are never overwritten. A plan is a proposal—not permission to erase a disk or evidence that anything was installed. For the operator journey and recovery rules, see the [machine guide](../README.md).

## Desired configuration: `machine.json`

By default, from anywhere in the consumer Git checkout, `plan root@HOST` finds the Git root and uses `<git-root>/.moss/root@HOST/machine.json`. On first use it asks for the values below, offers defaults where possible, probes whole disks read-only, records the only candidate or prompts you to choose from a numbered list, and asks you to review the JSON before saving. Later runs reuse that file automatically. Files for different SSH targets have separate directories. Neither a configuration nor an existing plan is overwritten. `--config /absolute/path/machine.json` overrides the lookup; automation can supply its own JSON with the same fields.

**Before first use, add `.moss/` to the consumer repo's `.gitignore` and commit it.** The CLI refuses default storage if `.moss/` is not ignored or contains tracked files, and prints an instruction. The directory is mode `0700`, its JSON files mode `0600`; back up the installation receipt separately. This is operator-local state inside the checkout, not data in the Git index or Nix store.

| Property | Meaning |
| --- | --- |
| `version` | Must be `1`. Unknown fields are rejected. |
| `repo` | Absolute local consumer Git checkout. The reviewed revision must be the pushed tip of `branch`. |
| `revision`, `branch` | Full 40-character source commit and chosen pushed branch. Update plans use the reviewed tip of the **already selected** branch. |
| `output` | NixOS output name in the consumer flake. |
| `machine` | Absolute private directory containing credential-free, mode-`0600` `machine.nix` (and optionally `facter.json`). These are separate from `machine.json`. |
| `receipt` | Absolute off-host path where a **successful install** will create its mode-`0600` receipt. An existing receipt makes planning an update, never another install. |
| `remoteCheckout`, `remoteMachine`, `remoteState` | Absolute paths used later for the target's checkout, private machine inputs and root-owned selector/revision state. |
| `disk` | Optional whole `/dev/…` path. Guided installation records its reviewed selection here; an explicit `--disk` must agree. The field may remain in the config during later updates, but updates **never use it to install**. |
| `reportGenerator`, `recoveryDir`, `preEraseCheck` | Optional consumer-owned executable/paths for a hardware report, private recovery files and an evaluated pre-erase policy check. Omit unused fields. |

The configuration contains **paths and choices, not secret contents**. Do not commit it. `machine.nix` and optional `facter.json` can enter the world-readable Nix store, so they must be credential-free. Planning may create `facter.json` via a configured report generator; it will not replace an existing report. Disk identity (size, model and serial) is **not** stored in `machine.json`: it comes from a fresh target probe and is captured in the install plan.

## Generated plan: `--output PLAN`

By default, `plan` writes a new, mode-`0600` JSON file under `<git-root>/.moss/root@HOST/plans/` and atomically updates `<git-root>/.moss/root@HOST/latest` to contain its absolute path. The reference is per-target and changes only after a successful plan; no plan is overwritten. `moss machine apply` uses it when exactly one target has a latest plan in the checkout. With multiple targets, specify `apply --target root@HOST`. Use `apply --plan /absolute/path/plan.json` (or the original positional plan argument) to select another plan explicitly; this does not change `latest`. `plan --output /absolute/path/plan.json` chooses a new path instead; when using the default config, it still updates `latest`.

Every plan has `version: 1`, `type`, the absolute `config` path, `configSha256`, `target` and `origin` (the consumer Git remote). There are exactly two recognized types:

| `type` | Additional properties | What they bind |
| --- | --- | --- |
| `install` | `disk`, `observed`, `machineSha256`, `facterSha256` | The selected whole-disk path; read-only probe facts (`observed.target`, architecture, boot mode, NIC/MAC, and disk path/type/size/model/serial); hashes of private machine inputs. `facterSha256` is an empty string if no report exists. |
| `update` | `expected` | Target's current revision (`current`), root-owned branch selector (`selected`), reviewed candidate tip (`next`) and machine-input hash (`machineSha256`). **No disk field and no disk installer.** |

`apply` rejects unknown plan types and revalidates the config hash and operation-specific facts. For an install, it rebuilds, re-probes the physical disk, rechecks the pushed tip and requires you to type `ERASE /dev/DISK` before running the installer. For an update, it rechecks the recorded selector/revision and exact tip under the target lock before switching. A changed file, moved branch, different disk or uncertain target state means **stop and make a new plan**.

The discovery record, assembled install inputs and staged build tree are temporary; they are not extra operator files to edit. The **install receipt** is created only after the installer succeeds and is distinct from both configuration and plan. `bootstrap` consumes that receipt after independent verification of the new SSH host key.
