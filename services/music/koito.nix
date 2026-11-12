_: let
  proxyIp = "10.89.0.21";
  presenceIp = "10.89.0.23";
in {
  flake = {
    podmanProxyHosts = {
      koito.ip = proxyIp;
      last-fm-presence.ip = presenceIp;
    };

    pangolinVirtualHosts."koito" = {
      site = "sorbet";
      name = "Koito";
      subdomain = "koito.int.kuipr.de";
      hostname = "koito";
      port = 4110;
      healthcheck.path = "/apis/web/v1/health";
      auth = {
        enable = true;
        bypassPaths = ["/apis/web/v1/health"];
      };
    };

    nixosModules.koito = {config, ...}: {
      sops.secrets = {
        "last-fm-presence" = {
          sopsFile = ../../secrets/sorbet/last-fm-presence.env;
          format = "dotenv";
          key = "";
        };
      };

      virtualisation.oci-containers.containers = {
        koito = {
          image = "docker.io/gabehf/koito:latest@sha256:3011de405ba2a5c56270928c2b0391add8aa3b3ed68363531b3c64b61f238857";
          volumes = [
            "koito-data:/etc/koito"
          ];
          environment = {
            TZ = "Europe/Berlin";
            KOITO_DEFAULT_USERNAME = "daniel";
          };
          # bookworm-slim image ships no curl/wget: TCP probe via bash /dev/tcp
          # podman's first health check fires immediately; retry or activation fails
          # pinned IP + --dns bypass aardvark-dns so the query log keeps per-container attribution
          extraOptions = [
            "--health-cmd=bash -c 'n=0; until exec 3<>/dev/tcp/127.0.0.1/4110 2>/dev/null; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=5s"
            "--network=proxy:ip=${proxyIp}"
            "--dns=192.168.0.85"
          ];
        };

        last-fm-presence = {
          image = "ghcr.io/frostplexx/lastfm-discord-presence:main@sha256:ba64784e5bdcfd232de2dea7edf36bc7d6dd0929c8b9c23850cb0805dfa32d9a";
          volumes = [];
          environmentFiles = [config.sops.secrets."last-fm-presence".path];
          extraOptions = [
            "--network=proxy:ip=${presenceIp}"
            "--dns=192.168.0.85"
          ];
        };
      };
    };
  };
}
