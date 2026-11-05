# Build helpers

These scripts are implementation details of [`../build.sh`](../build.sh), **not runtime dependencies**:

- `assemble.sh` expands command fragments into standalone argc input.
- `export-spec.sh` exports JSON from argc, dropping only empty version-dependent author metadata.
- `render-cli-reference.sh` turns generated JSON specs into the Markdown command reference.

From the repository root, run `bash packages/cli/build.sh` to refresh the committed artifacts. Do not invoke these helpers on a target.
