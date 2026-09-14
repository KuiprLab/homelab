# slskd container (Soulseek daemon) — VPN-routed via gluetun.
# Reverse-proxied by caddy as slskd.int.kuipr.de.
#
# Note: this file used to bundle the upstream "soulbeet" web UI alongside
# slskd. soulbeet has been replaced by ./harvest.nix; only slskd remains here.
_: {
  flake = {
    caddyVirtualHosts."slskd.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:5030
      '';
      name = "SLSKD";
    };

    nixosModules.slskd = {config, ...}: {
      sops.secrets."slskd" = {
        sopsFile = ../../../secrets/sorbet/slskd.yml;
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

      virtualisation.oci-containers.containers.slskd = {
        volumes = [
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
