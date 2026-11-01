# Optional read-only GitHub App ruleset audit; consumer owns secret files.
{ lib, pkgs, config, ... }:
let cfg = config.services.themossAppAudit;
in {
  options.services.themossAppAudit = {
    enable = lib.mkEnableOption "periodic GitHub App repository ruleset audit";
    appId = lib.mkOption { type = lib.types.str; description = "Public numeric App ID"; };
    installationId = lib.mkOption { type = lib.types.str; description = "Public numeric installation ID"; };
    keyFile = lib.mkOption { type = lib.types.str; description = "Absolute runtime path to root-only PEM, never a Nix store path"; };
    policyFile = lib.mkOption { type = lib.types.str; description = "Absolute runtime path to consumer policy JSON"; };
    interval = lib.mkOption { type = lib.types.str; default = "daily"; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = lib.hasPrefix "/" cfg.keyFile && !(lib.hasPrefix "/nix/store/" cfg.keyFile); message = "themossAppAudit.keyFile must be outside the Nix store"; }
      { assertion = lib.hasPrefix "/" cfg.policyFile && !(lib.hasPrefix "/nix/store/" cfg.policyFile); message = "themossAppAudit.policyFile must be a runtime path outside the Nix store"; }
    ];
    systemd.services.themoss-app-audit = {
      description = "Read-only audit of GitHub App installation and repository rules";
      path = with pkgs; [ bash curl jq openssl coreutils ];
      environment.THEMOSS_AUDIT_POLICY_JQ = toString ./audit-policy.jq;
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${pkgs.bash}/bin/bash ${./audit-app.sh} ${lib.escapeShellArg cfg.appId} ${lib.escapeShellArg cfg.installationId} ${lib.escapeShellArg cfg.keyFile} ${lib.escapeShellArg cfg.policyFile}";
      };
    };
    systemd.timers.themoss-app-audit = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = cfg.interval; RandomizedDelaySec = "1h"; Persistent = true; Unit = "themoss-app-audit.service"; };
    };
  };
}
