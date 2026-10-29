{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.unifi-os-server;
  stateDir = "/var/lib/unifi-os";

  # The container journal is root-only; capture unifi-core output to files.
  ucoreDebug = pkgs.writeText "unifi-core-debug.conf" ''
    [Service]
    StandardOutput=append:/data/unifi-core/logs/stdout.log
    StandardError=append:/data/unifi-core/logs/stderr.log
  '';

  ucorePreStartFix = pkgs.writeText "unifi-core-prestart-fix.conf" ''
    [Service]
    ExecStartPre=-/bin/mkdir -p /data/unifi-core/config/http
    ExecStartPre=-/bin/mkdir -p /var/log/nginx
  '';

  # MongoDB needs writable log and data dirs; + runs as root regardless of User=
  mongoPreStartFix = pkgs.writeText "mongodb-prestart-fix.conf" ''
    [Service]
    ExecStartPre=+/bin/bash -c "mkdir -p /var/log/mongodb && chown mongodb:mongodb /var/log/mongodb /var/lib/mongodb"
  '';

  # Must match the repository:tag inside image.tar.
  imageTag = "uosserver:0.0.56";
in {
  options.services.unifi-os-server = {
    enable = mkEnableOption "UniFi OS Server container (podman)";

    package = mkOption {
      type = types.package;
      description = ''
        Package containing the extracted UniFi OS Server OCI archive at
        `image.tar`.  Build with:
        `pkgs.callPackage ./package.nix { sha256 = "…"; }`
      '';
    };

    systemIp = mkOption {
      type = types.str;
      default = "";
      example = "unifi.example.com";
      description = ''
        Hostname or IP address for the UniFi OS Server inform URL (UOS_SYSTEM_IP).
        Devices will use this to reach the controller. Set to your host's
        externally reachable hostname or IP.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether or not to open all UniFi OS Server ports on the firewall.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional environment variables for the container.";
    };

    extraVolumes = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["/etc/ssl/certs:/etc/rabbitmq/ssl:ro"];
      description = "Additional bind mounts beyond the defaults.";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra arguments passed to podman.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation = {
      podman.enable = true;
      oci-containers.backend = "podman";
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [
        8080
        5005
        9543
        6789
        8443
        8444
        11084
        5671
        8880
        8881
        8882
      ];
      allowedUDPPorts = [
        3478
        5514
        10003
      ];
    };

    systemd.services.podman-unifi-os-server = {
      restartTriggers = [cfg.package];

      serviceConfig = {
        StateDirectory = [
          "unifi-os"
          "unifi-os/persistent"
          "unifi-os/data"
          "unifi-os/srv"
          "unifi-os/unifi"
          "unifi-os/mongodb"
        ];
        LogsDirectory = "unifi-os";
      };

      preStart = lib.mkAfter ''
        uuid_file="${stateDir}/data/uos_uuid"
        # The Java controller requires exactly a v5 UUID; derive it from machine-id.
        if ! grep -qP '^[0-9a-f]{8}-[0-9a-f]{4}-5' "$uuid_file" 2>/dev/null; then
          ${pkgs.util-linux}/bin/uuidgen -s -n @dns -N "$(cat /etc/machine-id)" > "$uuid_file"
        fi

      '';
    };

    virtualisation.oci-containers.containers.unifi-os-server = {
      image = imageTag;
      imageFile = pkgs.runCommand "unifi-os-image.tar" {} ''
        ln -s ${cfg.package}/image.tar $out
      '';
      autoStart = true;
      privileged = true;

      ports = [
        "11443:443"
        "8080:8080"
        "5005:5005"
        "9543:9543"
        "6789:6789"
        "8443:8443"
        "8444:8444"
        "3478:3478/udp"
        "5514:5514/udp"
        "10003:10003/udp"
        "11084:11084"
        "5671:5671"
        "8880:8880"
        "8881:8881"
        "8882:8882"
      ];

      environment =
        {
          UOS_SYSTEM_IP = cfg.systemIp;
          UOS_SERVER_VERSION = cfg.package.version;
          FIRMWARE_PLATFORM =
            if pkgs.stdenv.hostPlatform.isAarch64
            then "linux-arm64"
            else "linux-x64";
        }
        // cfg.environment;

      volumes =
        [
          "${stateDir}/persistent:/persistent"
          "/var/log/unifi-os:/var/log"
          "${stateDir}/data:/data"
          "${stateDir}/srv:/srv"
          "${stateDir}/unifi:/var/lib/unifi"
          "${stateDir}/mongodb:/var/lib/mongodb"
          "${ucoreDebug}:/etc/systemd/system/unifi-core.service.d/debug.conf:ro"
          "${ucorePreStartFix}:/etc/systemd/system/unifi-core.service.d/prestart-fix.conf:ro"
          "${mongoPreStartFix}:/etc/systemd/system/mongodb.service.d/prestart-fix.conf:ro"
        ]
        ++ cfg.extraVolumes;

      extraOptions =
        [
          "--systemd=always"
          "--add-host=host.docker.internal:host-gateway"
          "--cap-add=SYS_ADMIN"
          "--cap-add=DAC_READ_SEARCH"
        ]
        ++ cfg.extraOptions;
    };
  };
}
