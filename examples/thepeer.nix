# Add to thepeer.stream relay's modules; source locked by deployment/flake.lock.
# The private machine module MUST set timer=false for candidate installs.
{ inputs, ... }: {
  imports = [ inputs.themoss.nixosModules.update ];
  services.themossUpdate = {
    enable = true;
    timer = false; # enable only AFTER merge to main and operator verification
    repository = "/var/lib/thepeer-relay/source";
    branch = "main";
    machine = "/var/lib/thepeer-relay";
    host = "relay";
    state = "/var/lib/thepeer-relay/update";
    interval = "daily";
  };
}
