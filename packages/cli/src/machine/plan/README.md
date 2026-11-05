# Configuration and plans

> 🛑 **A plan is not permission to erase a disk.** It describes a proposed install or update; only a successful install produces a receipt. For the sequence of operator actions, see the [machine guide](../README.md).

## Where the files live

From anywhere in the **consumer Git checkout**, `moss machine plan root@HOST` uses its Git root:

```text
.moss/root@HOST/
├── machine.json            # desired configuration, created on first use
├── plans/<unique>.json     # immutable typed proposals
├── latest                  # absolute path of last successfully written plan
└── install-receipt.json    # created only after successful installation
```

- **Protect the directory:** Add `.moss/` to the consumer repo's `.gitignore` and commit the ignore rule *before* planning. The CLI refuses an unignored or tracked `.moss/`. Directories must be mode `0700`; JSON and `latest` files are mode `0600`. These are operator-local files **inside the checkout but outside Git and off the target**. Back up the receipt separately.
- **Keep plans distinct:** Each target has its own directory. `plan` never overwrites a configuration or a plan; it updates `latest` only after publishing a new plan. `apply` uses that reference if just one target has plans, or needs `--target root@HOST` when several do. It never picks the globally newest file by modification time.
- **Override when necessary:** `plan --config FILE` and `plan --output FILE` accept absolute paths. `apply --plan FILE` (or the existing positional plan path) selects an explicit plan without changing `latest`. A custom output with the default config still updates its target's `latest`. Passing *both* config and output paths works outside a Git checkout, without default storage.

## Desired configuration: `machine.json`

On first use the CLI asks for source/policy choices, probes whole disks read-only, proposes the only disk or asks you to select from a numbered list, and asks you to review the JSON **before saving**. Subsequent plans reuse that file. You can also provide your own mode-`0600` JSON via `--config`; `version` must be `1` and unknown keys are rejected.

### Source and build inputs

- **`repo`, `revision`, `branch`:** Absolute local consumer checkout, full 40-character commit and pushed branch. Install requires that commit to be the exact pushed branch tip; updates follow only the *already selected* branch.
- **`output`:** NixOS host output in the consumer flake.
- **`machine`:** Absolute private directory containing mode-`0600`, credential-free `machine.nix` and, optionally, `facter.json`. These are **not** the JSON configuration. A configured `reportGenerator` may create `facter.json` during planning but cannot overwrite it.

### Installation and target paths

- **`disk` (optional):** Whole `/dev/…` path. Guided installation saves its reviewed selection here; `--disk` must agree if both are supplied. The field can remain in an update config, but **updates never use it to install**. Fresh disk size/model/serial are recorded in the *plan*, not the config.
- **`receipt`:** Absolute off-host path for the mode-`0600` receipt created **only after a successful install**. When it exists, `plan` prepares an update, never a second install.
- **`remoteCheckout`, `remoteMachine`, `remoteState`:** Absolute paths for the target checkout, private machine inputs and root-owned selector/revision state.

### Optional consumer hooks

- **`reportGenerator`:** Executable that produces a hardware report without replacing an existing one.
- **`preEraseCheck`:** Executable that checks the evaluated install before erase.
- **`recoveryDir`:** Separate private files for the installer; never staged into the Nix flake.

The JSON contains **paths and choices, not secret contents**. Do not commit it. `machine.nix` and `facter.json` may enter the world-readable Nix store: neither may contain credentials.

## Generated plan: `plans/<unique>.json`

Every new mode-`0600` plan has **`version: 1`, `type`, `config`, `configSha256`, `target` and `origin`** (the checkout's Git remote). `config` is an absolute path, and its hash binds the configuration reviewed during planning. There are two recognized types:

- **`install`:** `disk` names the proposed whole disk; `observed` holds the read-only target probe (target, architecture, boot mode, NIC/MAC and disk path/type/size/model/serial). `machineSha256` and `facterSha256` bind the private build inputs; the latter is empty when no report exists. No disk is erased by planning.
- **`update`:** `expected` binds the target's current revision (`current`), root-owned branch selector (`selected`), reviewed branch tip (`next`) and machine-input hash (`machineSha256`). **There is no disk field or disk installer.**

**Applying revalidates—never trusts the plan alone.** For an install, `apply` checks the config and input hashes, rebuilds, re-probes the disk, verifies the pushed tip and requires typed `ERASE /dev/DISK` consent before the installer. For an update it rechecks the recorded selector/revision and exact tip under the target lock. A changed file, moved tip, different disk or uncertain state means **stop and make a new plan**.

Discovery records, assembled install inputs and staged builds are temporary; they are not additional operator files to edit. `bootstrap` consumes the separate install receipt after you independently verify the new SSH host key.
