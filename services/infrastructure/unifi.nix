_: {
  flake = {
    nixosModules.unifi = _: {
      imports = [../../pkgs/unifi-os-server-image/module.nix];

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
            # LAN IP, not loopback: device adoption talks to UOS_SYSTEM_IP.
            "192.168.0.85:5005:5005"
            "192.168.0.85:9543:9543"
            "192.168.0.85:6789:6789"
            "192.168.0.85:8080:8080"
            "192.168.0.85:8443:8443"
            "192.168.0.85:9080:9080"
            "192.168.0.85:8444:8444"
            "192.168.0.85:3478:3478/udp"
            "192.168.0.85:5514:5514/udp"
            "192.168.0.85:10003:10003/udp"
            "192.168.0.85:11084:11084"
            "192.168.0.85:5671:5671"
            "192.168.0.85:8880:8880"
            "192.168.0.85:8881:8881"
            "192.168.0.85:8882:8882"
          ];
          privileged = true;
          environment = {
            TZ = "Europe/Berlin";
            UOS_SYSTEM_IP = "192.168.0.85";
          };

          image = "ghcr.io/lemker/unifi-os-server:latest@sha256:c0136d42d238b9574d93676aada3f61971ffb6bcbe2a3050627a9fa7ced7c878";
          # The image has no curl/wget; a failed check aborts activation, so retry with /dev/tcp.
          extraOptions = [
            "--health-cmd=bash -c 'n=0; until (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; do n=$((n+1)); [ $n -ge 30 ] && exit 1; sleep 5; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=5m"
            "--health-timeout=180s"
            "--cgroupns=host"
            "--cap-add=NET_RAW"
            "--cap-add=NET_ADMIN"
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
