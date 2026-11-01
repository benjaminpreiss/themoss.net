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
    };
}
