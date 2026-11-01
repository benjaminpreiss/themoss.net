# Add to agentic's nixosConfigurations.agentic.modules; source is a flake input
# locked by agentic/nixos/flake.lock. Manual-only policy.
{ inputs, ... }: {
  imports = [ inputs.themoss.nixosModules.update ];
  services.themossUpdate = {
    enable = true;
    timer = false;
    repository = "/var/lib/agentic/source";
    branch = "main";
    machine = "/var/lib/agentic/machine";
    host = "agentic";
    state = "/var/lib/agentic/update";
  };
}
