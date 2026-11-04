# Credential-free stand-in for a consumer's NixOS machine output. The build
# is deliberately tiny; it tests the caller's update/build command shape, not
# a real NixOS closure or the App-backed PR path.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      nixosConfigurations.synthetic.config.system.build.toplevel =
        pkgs.runCommand "synthetic-machine" { } ''
          echo synthetic-machine > "$out"
        '';
      nixosConfigurations.agentic = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./packages/cli/src/machine/update.nix
          ({ ... }: {
            system.stateVersion = "25.05";
            boot.loader.grub.enable = true;
            boot.loader.grub.device = "/dev/vda";
            fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };
            services.themossUpdate = {
              enable = true;
              repository = "/root/agentic";
              machine = "/root/private-machine";
              host = "agentic";
              state = "/var/lib/themoss";
            };
          })
        ];
      };
    };
}
