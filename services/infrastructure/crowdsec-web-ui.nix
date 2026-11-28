_: let
  # Eclair's loopback carries this address so the pangolin tunnel can reach the
  # LAPI without an alias, which would drag the client into DNS.
  lapiTunnelAddress = "10.90.0.1";
in {
  flake.eclairNixosModules.crowdsecWebUi = {
    config,
    pkgs,
    ...
  }: let
    cscli = "${config.services.crowdsec.package}/bin/cscli";

    mkForwarder = port: {
      description = "Expose CrowdSec port ${toString port} on the tunnel address";
      wantedBy = ["multi-user.target"];
      after = ["crowdsec.service" "network-addresses-lo.service"];
      wants = ["crowdsec.service"];
      requires = ["network-addresses-lo.service"];
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString port},bind=${lapiTunnelAddress},fork,reuseaddr TCP:127.0.0.1:${toString port}";
        Restart = "always";
        RestartSec = 3;
      };
    };
  in {
    sops.secrets."crowdsec-web-ui" = {
      sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
      format = "dotenv";
      key = "";
      owner = "root";
    };

    networking.interfaces.lo.ipv4.addresses = [
      {
        address = lapiTunnelAddress;
        prefixLength = 32;
      }
    ];

    systemd.services = {
      # network.target carries RefuseManualStart, so a switch never starts its new wants.
      network-addresses-lo.wantedBy = ["multi-user.target"];
      crowdsec-tunnel-lapi = mkForwarder 9090;
      crowdsec-tunnel-metrics = mkForwarder 6060;
    };

    systemd.services.crowdsec-web-ui-machine = {
      description = "Register the CrowdSec Web UI as a CrowdSec machine";
      wantedBy = ["multi-user.target"];
      after = ["crowdsec.service" "sops-install-secrets.service"];
      wants = ["crowdsec.service"];
      path = [config.services.crowdsec.package];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        set -a
        . ${config.sops.secrets."crowdsec-web-ui".path}
        set +a

        if ${cscli} machines inspect crowdsec-web-ui >/dev/null 2>&1; then
          echo "machine crowdsec-web-ui already registered"
        else
          ${cscli} machines add crowdsec-web-ui \
            --password "$CONFIG_INSTANCES_0_LAPI_AUTH_PASSWORD" -f /dev/null
        fi
      '';
    };
  };
}
