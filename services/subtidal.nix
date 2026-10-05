# Subtidal — hosted on eclair (public VPS) for faster connection speeds.
# Traffic terminates on eclair (haproxy SNI → local caddy → container) and
# never touches sorbet.
_: {
  flake = {
    eclairCaddyVirtualHosts."subtidal.ext.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:4234
      '';
      name = "Subtidal";
    };

    eclairNixosModules.subtidal = {config, ...}: {
      sops.secrets."subtidal" = {
        sopsFile = ../secrets/eclair/subtidal.toml;
        format = "binary";
        key = "";
        mode = "0444";
      };

      virtualisation = {
        podman = {
          enable = true;
          autoPrune = {
            enable = true;
            dates = "weekly";
            flags = ["--all"];
          };
        };
        oci-containers.backend = "podman";
        oci-containers.containers.subtidal = {
          image = "ghcr.io/frostplexx/subtidal:latest";
          volumes = [
            "/var/lib/subtidal:/data:rw"
            "${config.sops.secrets."subtidal".path}:/config/subtidal/settings.toml:ro"
          ];
          user = "1000:100";
          ports = ["127.0.0.1:4234:8000"];
          environment = {
            TZ = "Europe/Berlin";
            XDG_CONFIG_HOME = "/config";
            SUBTIDAL_TOKEN_FILE = "/data/tokens.json";
            RUST_LOG = "info";
          };
          labels = {
            "io.containers.autoupdate" = "registry";
          };
          # Podman does not inherit image HEALTHCHECKs — mirror the upstream
          # one explicitly (curl → 127.0.0.1:8000/rest/ping).
          # Unhealthy → podman kills the container; systemd's Restart recreates it.
          extraOptions = [
            "--health-cmd=curl -fsS http://127.0.0.1:8000/rest/ping >/dev/null"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=30s"
            "--health-timeout=3s"
          ];
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/subtidal 0755 1000 100 -"
      ];
    };
  };
}
