# moss machine command reference

> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#install-a-machine), not this command list.

## `moss`

Plan and apply reviewed changes to a themoss machine

**Options**

- **`--version`** (optional)

### `moss machine`

Operate on a machine

#### `moss machine plan`

Inspect the target and build a non-destructive reviewed installation plan

**Arguments**

- **`TARGET`** (required) — Known rescue SSH target (verify host key independently)

**Options**

- **`--config <FILE>`** (optional) — Override the default per-target configuration file
- **`--disk <DISK>`** (optional) — Choose a whole disk explicitly; otherwise detect during guided install
- **`--output <FILE>`** (optional) — New plan file; defaults to this target's .moss/plans directory

#### `moss machine apply`

Revalidate and apply a reviewed plan; installation erases the selected disk

**Arguments**

- **`FILE`** (optional) — Explicit plan path (also accepted for existing scripts)

**Options**

- **`--plan <FILE>`** (optional) — Explicit plan path instead of the latest managed plan
- **`--target <ROOT@HOST>`** (optional) — Choose a target when the checkout has multiple plans

#### `moss machine bootstrap`

Resume first-boot handoff after independently verifying the new SSH host key

**Arguments**

- **`RECEIPT`** (required) — Off-host installation receipt

**Options**

- **`--config <FILE>`** (optional) — Original private machine configuration; defaults to .moss for the receipt target
