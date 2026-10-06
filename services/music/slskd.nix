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
        image = "docker.io/slskd/slskd:latest@sha256:ecd4026d4f8fb504e2cc55323efa2c1f5b56d20d3686b018249cc36b48ea17a6";
        # Podman does not inherit image HEALTHCHECKs — mirror the upstream
        # one explicitly (wget → localhost:5030/health; it is a static 200
        # liveness probe, and the 60m start period covers Soulseek login).
        # Unhealthy → podman kills the container; systemd's Restart recreates it.
        extraOptions = [
          # Retry inside the command: podman's first check fires immediately at
          # start, and a failed transient-unit check aborts NixOS activations.
          "--health-cmd=sh -c 'n=0; until wget -q -O /dev/null http://localhost:5030/health; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'"
          "--health-interval=60s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=60m"
          "--health-timeout=50s"
          "--network=container:gluetun"
        ];
      };
    };
  };
}
