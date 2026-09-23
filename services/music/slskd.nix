# slskd container (Soulseek daemon) — VPN-routed via gluetun.
# Shares gluetun's network namespace, so port 5030 is published by the gluetun
# container (see ../gluetun.nix); caddy proxies it as slskd.int.kuipr.de.
_: {
  flake = {
    caddyVirtualHosts."slskd.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:5030
      '';
      name = "SLSKD";
      # slskd has no SSO of its own; authelia gates the vhost and slskd's
      # built-in login is disabled in slskd.yml (web.authentication.disabled).
      authelia.enable = true;
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
          # Image requires /app writable by its user (slskd state: db, logs).
          "/var/lib/slskd:/app"
          "/home/daniel/slskd-downloads:/app/downloads"
          "${config.sops.secrets."slskd".path}:/app/slskd.yml:ro"
        ];
        user = "1000:100";
        environment = {
          TZ = "Europe/Berlin";
          SLSKD_REMOTE_CONFIGURATION = "true";
        };
        image = "docker.io/slskd/slskd:latest";
        labels = {
          "io.containers.autoupdate" = "registry";
        };
        extraOptions = [
          "--network=container:gluetun"
        ];
      };
    };
  };
}
