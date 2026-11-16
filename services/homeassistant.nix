_: {
  flake = {
    pangolinVirtualHosts."has" = {
      site = "sorbet";
      name = "Home Assistant";
      subdomain = "has.int.kuipr.de";
      port = 8123;
    };

    nixosModules.homeassistant = {config, ...}: {
      # Binary sops: YAML mode re-serializes and breaks HA config semantics.
      sops.secrets."homeassistant/configuration" = {
        sopsFile = ../secrets/sorbet/homeassistant/configuration;
        format = "binary";
        key = "";
        restartUnits = ["podman-homeassistant.service"];
      };

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
          volumes = [
            "home-assistant:/config"
            "/run/dbus:/run/dbus:ro"
            "${config.sops.secrets."homeassistant/configuration".path}:/config/configuration.yaml:ro"
          ];
          environment.TZ = "Europe/Berlin";
          image = "ghcr.io/home-assistant/home-assistant:stable@sha256:493a07e8f6530fc640223f4a0a5248f20a61ca2f718bb1d31efbf08a2c5ea28f";
          # A failed transient-unit check aborts activation; HA needs minutes to boot.
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
