{config, ...}: let
  healthFlags = config.flake.healthFlags;
in {
  flake = {
    pangolinVirtualHosts."slskd" = {
      site = "sorbet";
      name = "slskd";
      subdomain = "slskd.int.kuipr.de";
      # slskd shares gluetun's netns, so the proxy network sees it as gluetun
      hostname = "gluetun";
      port = 5030;
      healthcheck.path = "/health";
      auth = {
        enable = true;
        bypassPaths = ["/health" "/api/*"];
      };
    };

    nixosModules.slskd = {config, ...}: {
      sops.secrets."slskd" = {
        sopsFile = ../../secrets/sorbet/slskd.yml;
        format = "yaml";
        key = "";
        uid = 1000;
      };

      systemd.services.podman-slskd = {
        requires = ["podman-gluetun.service"];
        after = ["podman-gluetun.service"];
        partOf = ["podman-compose-gluetun-root.target"];
        wantedBy = ["podman-compose-gluetun-root.target"];
      };

      systemd.tmpfiles.rules = ["d /var/lib/slskd 0755 1000 100 -"];

      virtualisation.oci-containers.containers.slskd = {
        volumes = [
          "/var/lib/slskd:/app"
          "/home/daniel/slskd-downloads:/app/downloads"
          "${config.sops.secrets."slskd".path}:/app/slskd.yml:ro"
        ];
        user = "1000:100";
        environment = {
          TZ = "Europe/Berlin";
          SLSKD_REMOTE_CONFIGURATION = "true";
        };
        image = "docker.io/slskd/slskd:latest@sha256:d0963a3e5b16facd295bf4f2156dad0182f246b1b21a032cae12f5494c694843";
        # podman ignores image HEALTHCHECK: mirror the upstream wget probe, retried
        extraOptions =
          [
            "--network=container:gluetun"
          ]
          ++ healthFlags {
            cmd = "sh -c 'n=0; until wget -q -O /dev/null http://localhost:5030/health; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'";
            interval = "60s";
            startPeriod = "60m";
            timeout = "50s";
          };
      };
    };
  };
}
