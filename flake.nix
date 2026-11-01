{
  description = "themoss.net deployment toolkit (consumer pins this flake in its own lock)";
  outputs = _: {
    nixosModules.update = import ./toolkit/update.nix;
  };
}
