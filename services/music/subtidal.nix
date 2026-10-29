_: {
  flake = {
    pangolinVirtualHosts."subtidal" = {
      site = "sorbet";
      name = "Subtidal";
      subdomain = "subtidal.ext.kuipr.de";
      port = 4234;
      private = false;
    };

    nixosModules.subtidal = {config, ...}: let
      # pinned, not auto-allocated: 986 is unused on sorbet and is not 1000 (daniel)
      uid = 986;
      gid = 986;
    in {
      users.groups.subtidal.gid = gid;
      users.users.subtidal = {
        isSystemUser = true;
        inherit uid;
        group = "subtidal";
      };

      sops.secrets."subtidal" = {
        sopsFile = ../../secrets/sorbet/subtidal.toml;
        format = "binary";
        key = "";
        owner = "subtidal";
        mode = "0400";
        restartUnits = ["podman-subtidal.service"];
      };

      virtualisation = {
        oci-containers.backend = "podman";
        oci-containers.containers.subtidal = {
          image = "ghcr.io/frostplexx/subtidal:latest@sha256:c1cc682ef0e1db824c16d256fe739a3ba8bd599e77c29f8bebd8902b4199c291";
          volumes = [
            "/var/lib/subtidal:/data:rw"
            "${config.sops.secrets."subtidal".path}:/config/subtidal/settings.toml:ro"
          ];
          user = "${toString uid}:${toString gid}";
          ports = ["127.0.0.1:4234:8000"];
          environment = {
            TZ = "Europe/Berlin";
            XDG_CONFIG_HOME = "/config";
            SUBTIDAL_TOKEN_FILE = "/data/tokens.json";
            RUST_LOG = "info";
          };
          # podman ignores image HEALTHCHECK; retry the first check or activation fails
          extraOptions = [
            "--health-cmd=curl -fsS --retry 6 --retry-delay 2 --retry-connrefused http://127.0.0.1:8000/rest/ping >/dev/null"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=30s"
            "--health-timeout=20s"
          ];
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/subtidal 0755 ${toString uid} ${toString gid} -"
      ];
    };
  };
}
