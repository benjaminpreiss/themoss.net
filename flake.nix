{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs = { nixpkgs, ... }:
    let
      forSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          moss = pkgs.callPackage ./packages/cli/rust/package.nix { };
          operatorTools = with pkgs; [ moss bash git jq openssh nix nixos-anywhere coreutils gnutar findutils ];
        in {
          operator = pkgs.mkShell { packages = operatorTools; };
          dev = pkgs.mkShell { packages = operatorTools ++ [ pkgs.argc ]; };
        };
    in {
      nixosModules.update = import ./packages/cli/src/machine/update.nix;
      packages = nixpkgs.lib.genAttrs [
        "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"
      ] (system: {
        moss = nixpkgs.legacyPackages.${system}.callPackage ./packages/cli/rust/package.nix { };
      });
      devShells = nixpkgs.lib.genAttrs [
        "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"
      ] forSystem;
    };
}
