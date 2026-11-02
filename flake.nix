{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs = { nixpkgs, ... }:
    let
      forLinux = system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        pkgs.mkShell {
          packages = with pkgs; [ bash git jq openssh nix nixos-anywhere coreutils gnutar util-linux findutils ];
        };
    in {
      nixosModules.update = import ./toolkit/update.nix;
      devShells.x86_64-linux.operator = forLinux "x86_64-linux";
      devShells.aarch64-linux.operator = forLinux "aarch64-linux";
    };
}
