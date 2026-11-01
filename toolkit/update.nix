# Optional target-side updater. Import from a consumer flake pinned by flake.lock.
{ lib, pkgs, config, ... }:
let cfg = config.services.themossUpdate;
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
    systemd.services.themoss-update = {
      description = "Build then switch reviewed NixOS revision";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pkgs.bash}/bin/bash ${./deploy.sh} update --repo ${lib.escapeShellArg cfg.repository} --branch ${lib.escapeShellArg cfg.branch} --machine ${lib.escapeShellArg cfg.machine} --host ${lib.escapeShellArg cfg.host} --state ${lib.escapeShellArg cfg.state}";
        Path = with pkgs; [ git nix openssh nixos-rebuild jq gnutar util-linux coreutils findutils ];
      };
    };
    systemd.timers.themoss-update = lib.mkIf cfg.timer {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.interval; RandomizedDelaySec = "1h"; Persistent = true; Unit = "themoss-update.service"; };
    };
  };
}
