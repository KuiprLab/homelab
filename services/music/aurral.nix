{config, ...}: let
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.24";
  vhost = config.flake.pangolinVirtualHosts."aurral";
  traefikLabels = config.flake.sorbetTraefikLabels "aurral" vhost;
  trialDir = "/media/data/trial/aurral";
in {
  flake = {
    podmanProxyHosts.aurral.ip = proxyIp;

    pangolinVirtualHosts."aurral" = {
      site = "sorbet";
      name = "Aurral (trial)";
      subdomain = "aurral.int.kuipr.de";
      hostname = "aurral";
      port = 3001;
      healthcheck.path = "/api/health/bootstrap";
      auth = {
        enable = true;
        bypassPaths = ["/api/health/bootstrap"];
      };
    };

    nixosModules.aurral = {config, ...}: {
      virtualisation.oci-containers.containers.aurral = {
        labels = traefikLabels;
        image = "ghcr.io/lklynet/aurral:latest@sha256:75dd06805e3daefd49eb4f91d19f4110f0ef6eb1d2b13e48ae36120d113b48f0";
        volumes = [
          "${trialDir}/config:/config"
          "${trialDir}/media:/data"
          "/home/daniel/slskd-downloads:/downloads"
        ];
        environment = {
          TZ = "Europe/Berlin";
          PUID = "1000";
          PGID = "100";
        };
        # the image ships no curl; node is the only HTTP client in it
        extraOptions =
          [
            "--network=proxy:ip=${proxyIp}"
          ]
          ++ healthFlags {
            cmd = ''node -e "fetch('http://127.0.0.1:3001/api/health/bootstrap').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"'';
            startPeriod = "2m";
            timeout = "15s";
          };
      };

      systemd.tmpfiles.rules = [
        "d ${trialDir}/config 0755 daniel users - -"
        "d ${trialDir}/media 0755 daniel users - -"
      ];
    };
  };
}
