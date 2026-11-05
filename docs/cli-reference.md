# moss CLI reference

> Generated from clap help. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#install-a-machine), not this command list.

## `moss`

```text
Initialize local storage and plan reviewed changes to a themoss machine

Usage: moss <COMMAND>

Commands:
  init     Create operator-local .moss in the current directory or Git ancestor
  machine  Operate on a machine
  help     Print this message or the help of the given subcommand(s)

Options:
  -h, --help
          Print help

  -V, --version
          Print version

```

## `moss init`

```text
Create operator-local .moss in the current directory or Git ancestor

Usage: moss init

Options:
  -h, --help
          Print help

```

## `moss machine`

```text
Operate on a machine

Usage: moss machine <COMMAND>

Commands:
  plan       Inspect the target and build a non-destructive reviewed installation plan
  apply      Revalidate and apply a reviewed plan; installation erases the selected disk
  bootstrap  Resume first-boot handoff after independently verifying the new SSH host key
  help       Print this message or the help of the given subcommand(s)

Options:
  -h, --help
          Print help

```

## `moss machine plan`

```text
Inspect the target and build a non-destructive reviewed installation plan

Usage: moss machine plan [OPTIONS] <TARGET>

Arguments:
  <TARGET>
          Known rescue SSH target (verify host key independently)

Options:
      --config <FILE>
          Override the default per-target configuration file

      --disk <DISK>
          Choose a whole disk explicitly; otherwise detect during guided install

      --output <FILE>
          New plan file; defaults to this target's .moss/plans directory

  -h, --help
          Print help

```

## `moss machine apply`

```text
Revalidate and apply a reviewed plan; installation erases the selected disk

Usage: moss machine apply [OPTIONS] [FILE]

Arguments:
  [FILE]
          Explicit plan path (also accepted for existing scripts)

Options:
      --plan <FILE>
          Explicit plan path instead of the latest managed plan

      --target <ROOT@HOST>
          Choose a target when the checkout has multiple plans

  -h, --help
          Print help

```

## `moss machine bootstrap`

```text
Resume first-boot handoff after independently verifying the new SSH host key

Usage: moss machine bootstrap [OPTIONS] <RECEIPT>

Arguments:
  <RECEIPT>
          Off-host installation receipt

Options:
      --config <FILE>
          Original private machine configuration; defaults to .moss for the receipt target

  -h, --help
          Print help

```
