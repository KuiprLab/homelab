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
          image = "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
          labels = {
            "io.containers.autoupdate" = "registry";
          };
          extraOptions = [
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
