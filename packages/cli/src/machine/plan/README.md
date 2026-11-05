# Configuration and plans

> 🛑 **A plan is a proposal, not permission to erase a disk.** Only a successful install creates a receipt. Follow the [machine guide](../README.md) for the operator workflow.

## Where files live

From the consumer Git checkout (or a subdirectory), `moss machine plan root@HOST` uses:

```text
.moss/root@HOST/
├── machine.json            # desired configuration
├── plans/<unique>.json     # immutable install/update proposals
├── latest -> /…/plans/<unique>.json  # symlink to the last published plan
└── install-receipt.json    # written only after a successful install
```

- **Before first use:** Add `.moss/` to the consumer `.gitignore` and commit the ignore rule. The CLI refuses unignored or tracked `.moss/` files. Directories must be mode `0700`; config, plan and receipt JSON files must be mode `0600`. The `latest` symlink has no separate mode—it points at a mode-`0600` plan.
- **One target at a time:** Each target has its own folder and `latest` symlink. `apply` uses it when the checkout has only one target with a plan; for several targets, use `apply --target root@HOST`. It never guesses from file modification times. Plans are never overwritten.
- **Explicit paths:** `plan --config FILE` and `--output FILE` override defaults; `apply --plan FILE` (or a positional plan path) overrides `latest` without changing it. A custom output with the default config still updates that target's symlink. With *both* config and output paths, planning also works outside a Git checkout.

These files are **operator-local, not committed or copied onto the target**. Back up the receipt separately.

## Desired configuration: `machine.json`

First use prompts for choices, probes whole disks **read-only**, proposes the only disk or asks for a numbered selection, and shows the JSON for review before writing it. Later plans reuse this file. `--config` may supply a mode-`0600` file instead; only the listed keys are allowed.

**Shape of the generated config** (illustrative JSONC: comments explain fields but are *not* accepted in an actual JSON file):

```jsonc
{
  "version": 1,                        // schema version; required
  "repo": "/home/me/consumer",          // absolute consumer Git checkout
  "revision": "<40-hex commit>",        // reviewed, pushed branch tip
  "branch": "main",                     // pushed source branch
  "output": "server",                   // NixOS host output in the flake
  "machine": "/home/me/private-machine", // directory with mode-0600 machine.nix
  "receipt": "/home/me/consumer/.moss/root@HOST/install-receipt.json", // receipt after install
  "remoteCheckout": "/root/consumer",   // target's future checkout
  "remoteMachine": "/root/private-machine", // target's private machine files
  "remoteState": "/var/lib/themoss",    // target's root-owned selector/revision

  // Optional keys—omit unused ones:
  "disk": "/dev/vda",                   // reviewed whole-disk candidate (not erase consent)
  "reportGenerator": "/home/me/report", // executable that creates facter.json
  "preEraseCheck": "/home/me/check",    // evaluated install policy check
  "recoveryDir": "/home/me/recovery"    // private files passed to installer, not Nix
}
```

- **No secrets:** `machine.nix` and optional `facter.json` are separate from this JSON and may enter the world-readable Nix store. A configured report generator may create `facter.json` during planning but cannot overwrite it. Keep credentials in the separate recovery tree.
- **Disk identity:** The config records the selected *path*, not size/model/serial; those come from a fresh probe in the install plan. `--disk` must agree with a configured disk. An existing receipt switches planning to **update**; the disk path may remain in the config but is never used to reinstall.

## Generated plan: `plans/<unique>.json`

Each new, mode-`0600` plan has this **shared envelope** (the values below are placeholders):

```jsonc
{
  "version": 1,
  "type": "install",             // or "update"
  "config": "/absolute/path/machine.json",
  "configSha256": "<hash>",   // binds reviewed config bytes
  "target": "root@HOST",
  "origin": "<Git remote>"    // source checkout's origin
  // ... type-specific keys below
}
```

**Install** adds these properties. `observed` is a snapshot of the **read-only target probe**; it does not authorize the disk installer:

```jsonc
"disk": "/dev/vda",
"observed": {
  "target": "root@HOST", "arch": "x86_64", "boot": "bios",
  "nic": [ /* probed NICs */ ], "mac": "<address>",
  "disk": { "path": "/dev/vda", "type": "disk", "size": 1000,
            "model": "<model>", "serial": "<serial>" }
},
"machineSha256": "<hash>",
"facterSha256": ""          // empty when no report exists
```

**Update** adds `expected` instead. **No disk field. No disk installer.**

```jsonc
"expected": {
  "current": "<installed commit>",
  "selected": "branch:main",  // root-owned branch selector
  "next": "<reviewed tip>",
  "machineSha256": "<hash>"
}
```

**At apply:** Config/input hashes and target facts are rechecked. Install rebuilds, re-probes and requires typed `ERASE /dev/DISK` confirmation; update rechecks the selector and exact tip under the target lock. **Changed file, moved tip, different disk or uncertain state? Stop and make a new plan.** Discovery records and staged builds are temporary, not operator files to edit.
