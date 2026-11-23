_: let
  journalConfig = {
    services.journald.settings.Journal = {
      SystemMaxUse = "500M";
      SystemKeepFree = "2G";
      SystemMaxFileSize = "50M";
      MaxRetentionSec = "7day";
      Compress = "yes";
      ForwardToSyslog = "no";
    };
  };
in {
  flake.hostModules.journald = journalConfig;
}
