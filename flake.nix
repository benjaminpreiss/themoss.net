{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs = { nixpkgs, ... }:
    let
      forSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          operatorTools = with pkgs; [ bash git jq openssh nix nixos-anywhere coreutils gnutar findutils ];
        in {
          operator = pkgs.mkShell { packages = operatorTools; };
          dev = pkgs.mkShell { packages = operatorTools ++ [ pkgs.argc ]; };
        };
    in {
      nixosModules.update = import ./packages/cli/src/machine/update.nix;
      devShells = nixpkgs.lib.genAttrs [
        "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"
      ] forSystem;
    };
}
