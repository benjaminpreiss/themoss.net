# `moss init`

Run `moss init` **once** from a consumer checkout (or any subdirectory) to create a mode-`0700` `.moss/` directory at the Git root. Outside Git, it initializes `.moss/` in the current directory. It is safe to rerun: it does not create a machine configuration or plan, contact a target, or change `.gitignore`.

> 📝 **In Git:** Add `.moss/` to the checkout's `.gitignore` and commit the ignore rule **before** planning. `moss init` prints this instruction if needed; other commands refuse unignored or tracked operator files. Explicit config, plan, receipt and generated report paths inside any Git checkout must also be ignored. Files outside Git need no ignore rule.

Then use `moss machine plan root@HOST` to guide machine-specific configuration and create the first plan. See the [machine guide](../machine/README.md) for disk checks and the installation workflow.
