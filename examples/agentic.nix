# Add to agentic's nixosConfigurations.agentic.modules; source is a flake input
# locked by agentic/nixos/flake.lock. Pin a candidate with
# `deploy REPO commit:FULL_SHA MACHINE HOST STATE`; its timer polls as a no-op.
# After review, `transition` can explicitly select branch:candidate (or main).
{ inputs, ... }: {
  imports = [ inputs.themoss.nixosModules.update ];
  services.themossUpdate = {
    enable = true;
    repository = "/var/lib/agentic/source";
    machine = "/var/lib/agentic/machine";
    host = "agentic";
    state = "/var/lib/agentic/update";
  };
}
