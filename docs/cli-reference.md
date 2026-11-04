# moss machine command reference

> Generated from the argc JSON spec. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#deploy-a-machine), not this command list.

## `bash packages/cli/bin/moss`

Plan and apply reviewed changes to a themoss machine

### `bash packages/cli/bin/moss machine`

Operate on a machine

#### `bash packages/cli/bin/moss machine plan`

Inspect the target and build a non-destructive reviewed installation plan

| Argument | Required | Description |
| --- | --- | --- |
| `TARGET` | yes | Known rescue SSH target (verify host key independently) |

#### `bash packages/cli/bin/moss machine apply`

Revalidate and apply a reviewed plan; installation erases the selected disk

| Argument | Required | Description |
| --- | --- | --- |
| `PLAN` | yes | Private typed plan produced by machine plan |

#### `bash packages/cli/bin/moss machine bootstrap`

Resume first-boot handoff after independently verifying the new SSH host key

| Argument | Required | Description |
| --- | --- | --- |
| `RECEIPT` | yes | Off-host installation receipt |
