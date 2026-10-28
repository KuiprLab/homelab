# Subtidal — runs on sorbet.
#
# It used to live on eclair "for faster connection speeds" (traffic terminated on
# the VPS and never crossed the house uplink). Measured 2026-10-28: 127 MB of
# egress in 4 days, so the rationale did not hold, and it was the largest swapped
# consumer on a 1 GB box (193 MB of pages vs 27 MB resident). Stream traffic now
# goes eclair → pangolin tunnel → sorbet's uplink.
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
      # Pinned, not auto-allocated: the data directory and the config secret are
      # owned by this uid, and NixOS system users without an explicit uid can
      # shift when another module adds one. uid/gid 986 are unused on sorbet.
      # Not 1000 — that is `daniel` here, an interactive account.
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
        # 0400 + owner: readable only by the container user, not world-readable.
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
          # Podman does not inherit image HEALTHCHECKs — mirror the upstream
          # one explicitly (curl → 127.0.0.1:8000/rest/ping).
          # Unhealthy → podman kills the container; systemd's Restart recreates it.
          extraOptions = [
            # Retry inside the command: podman's first check fires immediately at
            # start, and a failed transient-unit check aborts NixOS activations
            # (this actually failed a deploy — Rust boot is slower than the check).
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
