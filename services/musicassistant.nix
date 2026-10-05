_: {
  flake = {
    caddyVirtualHosts."mus.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:8095
      '';
      name = "Music Assistant";
    };

    gatusEndpoints = [
      {
        name = "Music Assistant";
        group = "Home";
        url = "https://mus.int.kuipr.de";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    nixosModules.musicassistant = _: {
      # Enable chromecast ports
      networking.firewall = {
        allowedTCPPorts = [
          8008
          8009
          8443
        ];

        allowedUDPPorts = [
          10008
          5353
        ];
      };

      virtualisation.oci-containers = {
        containers.musicassistant = {
          volumes = ["music-assistant:/data"];
          environment.TZ = "Europe/Berlin";
          image = "ghcr.io/music-assistant/server:latest"; # Warning: if the tag does not change, the image will not be updated
          environment = {
            "LOG_LEVEL" = "info";
          };
          labels = {
            "io.containers.autoupdate" = "registry";
          };

          # wget is installed by the image's base (Dockerfile.base); probe the
          # web UI root, retrying for up to ~75s: podman's first check fires
          # immediately at start and a failed transient-unit check aborts NixOS
          # activations. Unhealthy → podman kills; systemd's Restart recreates.
          extraOptions = [
            "--health-cmd=sh -c 'n=0; until wget -q --spider http://127.0.0.1:8095/; do n=$((n+1)); [ $n -ge 15 ] && exit 1; sleep 5; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=2m"
            "--health-timeout=100s"
            "--network=host"
          ];
        };
      };
    };
  };
}
