_: {
  flake = {
    caddyVirtualHosts."has.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:8123 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
      name = "Home Assistant";
    };

    gatusEndpoints = [
      {
        name = "Home Assistant";
        group = "Home";
        url = "https://has.int.kuipr.de";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    # https://nixos.wiki/wiki/Home_Assistant#NixOS_Module
    nixosModules.homeassistant = _: {
      networking.firewall.allowedTCPPorts = [
        8123
        5353
        1900
        8097
        51827
      ];

      virtualisation.oci-containers = {
        backend = "podman";
        containers.homeassistant = {
          volumes = ["home-assistant:/config"];
          environment.TZ = "Europe/Berlin";
          image = "ghcr.io/home-assistant/home-assistant:stable@sha256:1b64d38f38d922bf9d59336451fd6453e1d614f934456af4ee3d2a51061be3a4";
          # Digest-pinned; renovate bumps the digest.
          # busybox wget ships with the alpine image; probe the frontend root,
          # retrying for up to ~2min: podman's first check fires immediately at
          # start and a failed transient-unit check aborts NixOS activations,
          # while HA takes minutes to boot its integrations.
          # Unhealthy → podman kills the container; systemd's Restart recreates it.
          extraOptions = [
            "--health-cmd=sh -c 'n=0; until wget -q --spider http://127.0.0.1:8123/; do n=$((n+1)); [ $n -ge 24 ] && exit 1; sleep 5; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=5m"
            "--health-timeout=150s"
            "--network=host"

            "--cap-add=SYS_ADMIN"
            "--cap-add=NET_ADMIN"
            "--cap-add=NET_RAW"
            "--cap-add=DAC_READ_SEARCH"
          ];
        };
      };
    };
  };
}
