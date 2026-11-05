# Optional target-side updater. Import from a consumer flake pinned by flake.lock.
{ lib, pkgs, config, ... }:
let
  cfg = config.services.themossUpdate;
  moss = pkgs.callPackage ./moss.nix { };
in {
  options.services.themossUpdate = {
    enable = lib.mkEnableOption "reviewed Git NixOS updates (never Disko)";
    timer = lib.mkEnableOption "scheduled updates (off for candidate installs)";
    repository = lib.mkOption { type = lib.types.str; description = "Root-owned local Git checkout"; };
    branch = lib.mkOption { type = lib.types.str; description = "Reviewed upstream branch"; };
    machine = lib.mkOption { type = lib.types.str; description = "Root-only private generated config directory"; };
    host = lib.mkOption { type = lib.types.str; description = "NixOS flake output name"; };
    state = lib.mkOption { type = lib.types.str; description = "Root-only known-good revision state directory"; };
    interval = lib.mkOption { type = lib.types.str; default = "daily"; };
  };
  config = lib.mkIf cfg.enable {
    # Install on candidate systems even while the timer is off: bootstrap and
    # transition invoke this binary on the target over verified SSH.
    environment.systemPackages = [ moss ];
    systemd.services.themoss-update = {
      description = "Build then switch reviewed NixOS revision";
      path = with pkgs; [ git nix openssh nixos-rebuild gnutar coreutils findutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${moss}/bin/moss update ${lib.escapeShellArg cfg.repository} ${lib.escapeShellArg cfg.branch} ${lib.escapeShellArg cfg.machine} ${lib.escapeShellArg cfg.host} ${lib.escapeShellArg cfg.state}";
      };
    };
    systemd.timers.themoss-update = lib.mkIf cfg.timer {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.interval; RandomizedDelaySec = "1h"; Persistent = true; Unit = "themoss-update.service"; };
    };
  };
}
