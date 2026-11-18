{config, ...}: let
  healthFlags = config.flake.healthFlags;
  musicDir = "/deemix-downloads";
in {
  flake.nixosModules.deemix = _: {
    systemd.services.podman-deemix = {
      requires = ["podman-gluetun.service"];
      after = ["podman-gluetun.service"];
      partOf = ["podman-compose-gluetun-root.target"];
      wantedBy = ["podman-compose-gluetun-root.target"];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/deemix 0755 1000 100 -"
      # bind source: podman refuses to start when it is missing
      "d /home/daniel/deemix-downloads 0755 1000 100 -"
    ];

    # no published port, no vhost: aurral reaches it as gluetun:6595 on the proxy network
    virtualisation.oci-containers.containers.deemix = {
      image = "ghcr.io/bambanah/deemix:latest@sha256:aff6120619685b339a704b49bec13469684dbec2c7e39cd7bdf0014217dd1d0a";
      volumes = [
        "/var/lib/deemix:/config"
        "/home/daniel/deemix-downloads:${musicDir}"
      ];
      environment = {
        TZ = "Europe/Berlin";
        PUID = "1000";
        PGID = "100";
        UMASK_SET = "022";
        DEEMIX_SINGLE_USER = "true";
        DEEMIX_MUSIC_DIR = musicDir;
        # the music tree is large: a recursive chown on every start is wasted work
        DISABLE_OWNERSHIP_CHECK_MUSIC = "true";
      };
      extraOptions =
        [
          "--network=container:gluetun"
        ]
        ++ healthFlags {
          cmd = "wget -q -O /dev/null http://127.0.0.1:6595/";
          startPeriod = "1m";
          timeout = "10s";
        };
    };
  };
}
