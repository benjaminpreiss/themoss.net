# Add to thepeer.stream relay's modules; source locked by deployment/flake.lock.
# Timer is always active; bootstrap pins commit:SHA until a reviewed transition
# selects branch:main (or another consumer-approved branch).
{ inputs, ... }: {
  imports = [ inputs.themoss.nixosModules.update ];
  services.themossUpdate = {
    enable = true;
    repository = "/var/lib/thepeer-relay/source";
    machine = "/var/lib/thepeer-relay";
    host = "relay";
    state = "/var/lib/thepeer-relay/update";
    interval = "daily";
  };
}
