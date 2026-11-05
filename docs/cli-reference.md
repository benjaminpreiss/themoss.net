# moss machine command reference

> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#install-a-new-machine), not this command list.

## `moss`

Plan and apply reviewed changes to a themoss machine

| Option | Required | Description |
| --- | --- | --- |
| `--version` | no |  |

### `moss machine`

Operate on a machine

#### `moss machine plan`

Inspect the target and build a non-destructive reviewed installation plan

| Argument | Required | Description |
| --- | --- | --- |
| `TARGET` | yes | Known rescue SSH target (verify host key independently) |

| Option | Required | Description |
| --- | --- | --- |
| `--config <FILE>` | no | Existing private configuration; omit for guided creation |
| `--disk <DISK>` | no | Optional explicit whole disk; otherwise detect and select during guided install |
| `--output <FILE>` | no | New private plan file; defaults to .moss for this target |

#### `moss machine apply`

Revalidate and apply a reviewed plan; installation erases the selected disk

| Argument | Required | Description |
| --- | --- | --- |
| `FILE` | no | Explicit plan path (also accepted for existing scripts) |

| Option | Required | Description |
| --- | --- | --- |
| `--plan <FILE>` | no | Explicit plan path instead of the latest managed plan |
| `--target <ROOT@HOST>` | no | Choose a target when the checkout has multiple plans |

#### `moss machine bootstrap`

Resume first-boot handoff after independently verifying the new SSH host key

| Argument | Required | Description |
| --- | --- | --- |
| `RECEIPT` | yes | Off-host installation receipt |

| Option | Required | Description |
| --- | --- | --- |
| `--config <FILE>` | no | Original private machine configuration; defaults to .moss for the receipt target |
