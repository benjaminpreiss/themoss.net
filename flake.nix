{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs = { nixpkgs, ... }:
    let
      forOperator = system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        pkgs.mkShell {
          packages = with pkgs; [ bash git jq openssh nix nixos-anywhere coreutils gnutar findutils argc ];
        };
    in {
      nixosModules.update = import ./packages/cli/src/machine/update.nix;
      devShells.x86_64-linux.operator = forOperator "x86_64-linux";
      devShells.aarch64-linux.operator = forOperator "aarch64-linux";
      devShells.x86_64-darwin.operator = forOperator "x86_64-darwin";
      devShells.aarch64-darwin.operator = forOperator "aarch64-darwin";
    };
}
