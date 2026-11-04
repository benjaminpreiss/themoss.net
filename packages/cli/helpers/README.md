# CLI build helpers

`assemble.sh` expands command fragments at build time; `render-cli-reference.sh` renders Markdown from the generated JSON specs. They are implementation details of [`../build.sh`](../build.sh), not runtime dependencies of `bin/moss` or the target-side scripts. Run `bash packages/cli/build.sh` from the repository root to rebuild the committed artifacts.
