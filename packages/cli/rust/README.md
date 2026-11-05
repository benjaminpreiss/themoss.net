# Rust CLI migration (in progress)

This crate is the **replacement implementation in progress**, based on current `main` at `18ab6e8` (the merged public `moss machine` CLI). `moss init` is implemented in Rust; machine operations still refuse to run, so **do not install or publish it as `moss` yet**. [`../bin/moss`](../bin/moss) remains the executable until the entire lifecycle is ported and tested. `packages/github-app-audit` is outside this migration.

## Migration contract

- **Public commands:** preserve `moss init`, `moss machine plan TARGET [--config/--disk/--output]`, `moss machine apply [FILE] [--plan/--target]`, and `moss machine bootstrap RECEIPT [--config]`. Do not expose private deploy, SSH bootstrap, adoption, transition or polling verbs as public commands.
- **Plan and apply:** keep operator files under ignored `.moss/`, enforce mode/ownership and no linked paths, preserve `machine.json` and typed plan/receipt formats, latest-plan symlink, pushed-commit checks, and non-destructive plan → live revalidation → typed `ERASE /dev/DISK` → final revalidation → install ordering. Do not substitute the earlier `discover/install/update` interface.
- **Updates:** retain root-only selector and revision, lock, branch ancestry and exact-tip checks, build-before-switch, `needs-inspection` gate after an uncertain switch, non-destructive adoption and the scheduled poller. Keep candidate timer policy consumer-owned.
- **Bootstrap:** preserve retryable upload, receipt verification and exact installed commit; the operator and target may have different architectures. Decide target-binary delivery and version compatibility before replacing streamed target scripts.
- **Documentation:** clap should drive public help and a generated Markdown reference; CI must compare it with committed output. Until cutover, the existing argc spec and reference remain authoritative. Do not replace them with incomplete preview docs.
- **Verification:** migrate the current lifecycle fixtures (`tests/test.sh`, `tests/operator-smoke.sh`, `tests/argc.sh`) before changing entry points. Exercise failures immediately before disk erase, after switch and during bootstrap. Validate a real disposable VM separately.

## Build preview

```bash
cd packages/cli/rust
cargo test --locked
cargo run -- machine plan --help
```

`cargo run -- init` only creates operator-local storage. No `cargo run` invocation performs target-side actions. Keep Cargo's cache and target directory inside the worktree when developing in a restricted environment.
