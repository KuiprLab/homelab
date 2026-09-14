# Glances — system monitoring web UI on sorbet.
# LAN-only via caddy (glances.int.kuipr.de), same no-auth trust model as
# gatus/upsnap. Bound to loopback; caddy is the only entry point.
_: {
  flake = {
    caddyVirtualHosts."glances.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:61208
      '';
      name = "Glances";
    };

    gatusEndpoints = [
      {
        name = "Glances";
        group = "Monitoring";
        url = "https://glances.int.kuipr.de";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
          "[RESPONSE_TIME] < 1500"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.glances = _: {
      services.glances = {
        enable = true;
        # extraArgs replaces the module default (["--webserver"]), so both
        # flags are explicit. --bind keeps the no-auth UI on loopback only;
        # openFirewall stays off.
        extraArgs = [
          "--webserver"
          "--bind"
          "127.0.0.1"
        ];
      };
    };
  };
}
