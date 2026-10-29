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
          image = "ghcr.io/home-assistant/home-assistant:stable@sha256:23f4dfbb69ce76315dbc4de7915504f1c2dcecd7ca2648113a493a385972e133";
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
