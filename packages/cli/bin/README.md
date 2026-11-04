# Generated executables — do not edit

| File | Role |
| --- | --- |
| `moss` | **Public** operator command, assembled from `../src/moss.sh` and command fragments. |
| `machine/deploy.sh` | Private target protocol, assembled from `../src/machine/deploy.sh` and fragments. |
| `machine/bootstrap/remote.sh` | Private, standalone bootstrap helper. |

`bash packages/cli/build.sh` embeds argc's parser in each executable; **argc is not needed at runtime**. Commit generated files alongside their sources. `bash tests/argc.sh` compares scripts, JSON specs and Markdown against a fresh build. The machine scripts are *not* supported operator or browser commands.
