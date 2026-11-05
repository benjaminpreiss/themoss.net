{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
  in {
    nixosModules.update = import ./toolkit/update.nix;
    packages = forSystems (pkgs: {
      default = pkgs.callPackage ./toolkit/moss.nix { };
      moss = pkgs.callPackage ./toolkit/moss.nix { };
    });
  };
}
