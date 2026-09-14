# Multi-scrobbler — monitors music activity from sources and scrobbles to clients.
# https://github.com/FoxxMD/multi-scrobbler
#
# Config: full config.json encrypted with sops at secrets/sorbet/multi-scrobbler.
# Auth sessions (spotify tokens, last.fm sessions) stored in podman volume.
_: {
  flake = {
    caddyVirtualHosts."scrobble.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:9078
      '';
      name = "Multi Scrobbler";
      authelia = {
        enable = true;
        # gatus probes this vhost sessionless; /healthz bypasses forward auth.
        bypassPaths = ["/healthz"];
      };
    };

    gatusEndpoints = [
      {
        name = "Multi-Scrobbler";
        group = "Music";
        url = "https://scrobble.int.kuipr.de/healthz";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.multi-scrobbler = {config, ...}: {
      sops.secrets."multi-scrobbler/config" = {
        sopsFile = ../../../secrets/sorbet/multi-scrobbler;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0444";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/multi-scrobbler 0755 root root - -"
      ];

      # Dedicated bridge network with IPv6, so the container can reach
      # api.listenbrainz.org over IPv6 (IPv4 to that host fails on this
      # network). Kept separate from the default podman network, so other
      # containers are not reconfigured.
      systemd.services.podman-network-msv6 = {
        description = "Ensure podman msv6 network (IPv6) exists";
        before = ["podman-multi-scrobbler.service"];
        wantedBy = ["podman-multi-scrobbler.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${config.virtualisation.podman.package}/bin/podman network exists msv6 || \
            ${config.virtualisation.podman.package}/bin/podman network create --ipv6 msv6
        '';
      };

      virtualisation.oci-containers.containers.multi-scrobbler = {
        image = "ghcr.io/foxxmd/multi-scrobbler:edge";
        volumes = [
          "multi-scrobbler-config:/config"
          "${config.sops.secrets."multi-scrobbler/config".path}:/config/config.json:ro"
        ];
        environment = {
          TZ = "Europe/Berlin";
          # Used as base for OAuth redirect URIs (Spotify, Last.fm).
          BASE_URL = "https://scrobble.int.kuipr.de";
          NODE_OPTIONS = "--dns-result-order=ipv6first";
        };
        ports = ["127.0.0.1:9078:9078"];
        extraOptions = [
          "--network=podman"
          "--network=msv6"
        ];
        labels = {
          "io.containers.autoupdate" = "registry";
        };
      };
    };
  };
}
