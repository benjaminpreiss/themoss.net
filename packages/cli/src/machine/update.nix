# Optional target-side updater. Import from a consumer flake pinned by flake.lock.
{ lib, pkgs, config, ... }:
let
  cfg = config.services.themossUpdate;
  moss = pkgs.callPackage ../../rust/package.nix { };

in {
  options.services.themossUpdate = {
    enable = lib.mkEnableOption "reviewed Git NixOS updates (never Disko)";
    repository = lib.mkOption { type = lib.types.str; description = "Root-owned local Git checkout"; };
    machine = lib.mkOption { type = lib.types.str; description = "Root-only private generated config directory"; };
    host = lib.mkOption { type = lib.types.str; description = "NixOS flake output name"; };
    state = lib.mkOption { type = lib.types.str; description = "Root-only known-good revision state directory"; };
    interval = lib.mkOption { type = lib.types.str; default = "daily"; };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ moss ];
    systemd.services.themoss-update = {
      description = "Build then switch reviewed NixOS revision";
      path = with pkgs; [ git nix openssh nixos-rebuild jq gnutar util-linux coreutils findutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${moss}/bin/moss internal poll ${lib.escapeShellArg cfg.repository} ${lib.escapeShellArg cfg.machine} ${lib.escapeShellArg cfg.host} ${lib.escapeShellArg cfg.state}";
      };
    };
    systemd.timers.themoss-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.interval; RandomizedDelaySec = "1h"; Persistent = true; Unit = "themoss-update.service"; };
    };
  };
}
