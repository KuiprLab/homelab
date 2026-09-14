_: {
  flake = {
    gatusEndpoints = [
      {
        name = "UniFi";
        url = "https://unifi.int.kuipr.de";
        group = "Home";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    caddyVirtualHosts."unifi.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy https://localhost:11443 {
          transport http {
            tls_insecure_skip_verify
          }
          # Required for UniFi WebSocket connections
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
      name = "UniFi";
    };

    nixosModules.unifi = _: {
      imports = [../../pkgs/unifi-os-server-image/module.nix];

      # services.unifi-os-server = {
      #   enable = true;
      #   package = pkgs.callPackage ../../pkgs/unifi-os-server-image {
      #     sha256 = "sha256-2xdlbyItNx2l+W7RBOM1A74WynVYF/EmQJtn2ACbFBk=";
      #   };
      #   systemIp = "192.168.0.85";
      #   openFirewall = true;
      # };

      # Important:
      # SSH into device with username/password: ubnt/ubnt
      # set-inform http://192.168.0.85:8080/inform
      virtualisation.oci-containers = {
        backend = "podman";
        containers.unifi-os-server = {
          volumes = [
            "/sys/fs/cgroup:/sys/fs/cgroup:rw"
            "unifi-os-server--persistent:/persistent"
            "unifi-os-server--var-log:/var/log"
            "unifi-os-server--data:/data"
            "unifi-os-server--srv:/srv"
            "unifi-os-server--var-lib-unifi:/var/lib/unifi"
            "unifi-os-server--var-lib-mongodb:/var/lib/mongodb"
            "unifi-os-server--etc-rabbitmq-ssl:/etc/rabbitmq/ssl"
          ];
          ports = [
            "127.0.0.1:11443:443"
            "5005:5005"
            "9543:9543"
            "6789:6789"
            "8080:8080"
            "8443:8443"
            "9080:9080"
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
          privileged = true;
          environment = {
            TZ = "Europe/Berlin";
            UOS_SYSTEM_IP = "192.168.0.85";
          };
          labels = {
            "io.containers.autoupdate" = "registry";
          };

          image = "ghcr.io/lemker/unifi-os-server:latest";
          extraOptions = [
            "--cgroupns=host"
            "--cap-add=NET_RAW"
            "--cap-add=NET_ADMIN"
            # tmpfs mounts
            "--tmpfs=/run:exec"
            "--tmpfs=/run/lock"
            "--tmpfs=/tmp:exec"
            "--tmpfs=/var/lib/journal"
            "--tmpfs=/var/opt/unifi/tmp:size=64m"
          ];
        };
      };
    };
  };
}
