# Generated executables — do not edit

`moss` is assembled from `../src/moss.sh` and its command fragments; `machine/deploy.sh` is assembled from `../src/machine/deploy.sh` and its command fragments. The bootstrap remote helper has its own source file in its command folder. `bash packages/cli/build.sh` builds standalone executables with argc's embedded parser. Commit them with their source; `bash tests/argc.sh` compares byte-for-byte builds, JSON specs and generated Markdown. Do not hand-edit files in `bin/`.

Only `moss` is a public operator command. The machine scripts are implementation/target-side protocol, not supported shell or browser entry points.
