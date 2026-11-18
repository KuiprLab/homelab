{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
in {
  flake = {
    pangolinVirtualHosts."up" = {
      site = "sorbet";
      name = "Upsnap";
      subdomain = "up.int.kuipr.de";
      port = 8090;
    };

    nixosModules.upsnap = {pkgs, ...}: {
      # Bound to the bridge gateway for the edge container; nothing listens on the
      # LAN address, so allowing the port exposes nothing to the LAN.
      networking.firewall.allowedTCPPorts = [8090];

      virtualisation.oci-containers.containers.upsnap = {
        volumes = [
          "upsnap-data:/app/pb_data"
        ];
        user = "1000:100";
        # Host networking is needed for LAN scanning; the bind address comes from UPSNAP_HTTP_LISTEN.
        environment = {
          TZ = "Europe/Berlin";
          UPSNAP_HTTP_LISTEN = "${constants.proxyGateway}:8090";
        };
        image = "ghcr.io/seriousm4x/upsnap:latest@sha256:e01e61ac6bfbf34a2003364e1499faf2da0fba0a485e0f4b31c49b6576b95e9d";
        # Podman does not inherit image HEALTHCHECKs.
        extraOptions =
          [
            "--dns=${constants.lanIp}"
            "--cap-add=NET_RAW"
            "--network=host"
          ]
          ++ healthFlags {
            cmd = "curl -fsS --retry 10 --retry-delay 2 --retry-connrefused http://${constants.proxyGateway}:8090/api/health >/dev/null";
            interval = "10s";
            startPeriod = "30s";
            timeout = "30s";
          };
      };

      # Binds the bridge gateway, so the network must exist first.
      systemd.services."podman-upsnap" = {
        requires = ["podman-create-network-proxy.service"];
        after = ["podman-create-network-proxy.service"];
      };

      systemd.services = {
        "podman-volume-upsnap-data" = {
          serviceConfig.Type = "oneshot";
          script = "${pkgs.podman}/bin/podman volume create upsnap-data || true";
          wantedBy = ["multi-user.target"];
        };
      };
    };
  };
}
