# Machine implementation source

`deploy.sh` owns safe install/update execution and private SSH operations; `bootstrap-remote.sh` runs the root-only first-boot handoff. `update.nix` is the NixOS scheduled updater module and refers to the generated `bin/machine/deploy.sh`. `new-operator-manifest.sh` is retained only for the older, pinned manifest workflow; it is not part of the public `moss` command tree.

Edit these sources, then regenerate the standalone scripts. `moss` is the only public operator interface; do not expose private SSH commands through the web app.
