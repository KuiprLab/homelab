# systemd-journald size caps for both hosts.
# Hard limits prevent runaway growth even if everything else fails.
# Currently sorbet's journal sits at 2.4GB — capping at 500MB forces vacuum.
_: let
  journalConfig = {
    services.journald.extraConfig = ''
      SystemMaxUse=500M
      SystemKeepFree=2G
      SystemMaxFileSize=50M
      MaxRetentionSec=7day
      Compress=yes
      ForwardToSyslog=no
    '';
  };
in {
  flake.nixosModules.journald = _: journalConfig;
  flake.eclairNixosModules.journald = _: journalConfig;
}
