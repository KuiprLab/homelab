{config, ...}: let
  constants = config.flake.constants;
  proxyIp = "10.89.0.40";
  vhost = config.flake.pangolinVirtualHosts."unifi";
  traefikLabels = config.flake.sorbetTraefikLabels "unifi" vhost;
in {
  flake = {
    podmanProxyHosts.unifi-os-server.ip = proxyIp;

    pangolinVirtualHosts."unifi" = {
      site = "sorbet";
      name = "UniFi";
      subdomain = "unifi.int.kuipr.de";
      hostname = "unifi-os-server";
      protocol = "https";
      port = 443;
      serversTransport = "unifi-insecure@file";
    };

    nixosModules.unifi = _: {
      # SSH into device with username/password: ubnt/ubnt
      # set-inform http://192.168.0.85:8080/inform
      virtualisation.oci-containers = {
        backend = "podman";
        containers.unifi-os-server = {
          labels = traefikLabels;
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
            # LAN IP, not loopback: device adoption talks to UOS_SYSTEM_IP.
            "${constants.lanIp}:5005:5005"
            "${constants.lanIp}:9543:9543"
            "${constants.lanIp}:6789:6789"
            "${constants.lanIp}:8080:8080"
            "${constants.lanIp}:8443:8443"
            "${constants.lanIp}:9080:9080"
            "${constants.lanIp}:8444:8444"
            "${constants.lanIp}:3478:3478/udp"
            "${constants.lanIp}:5514:5514/udp"
            "${constants.lanIp}:10003:10003/udp"
            "${constants.lanIp}:11084:11084"
            "${constants.lanIp}:5671:5671"
            "${constants.lanIp}:8880:8880"
            "${constants.lanIp}:8881:8881"
            "${constants.lanIp}:8882:8882"
          ];
          privileged = true;
          environment = {
            TZ = "Europe/Berlin";
            UOS_SYSTEM_IP = constants.lanIp;
          };

          image = "ghcr.io/lemker/unifi-os-server:latest@sha256:c0136d42d238b9574d93676aada3f61971ffb6bcbe2a3050627a9fa7ced7c878";
          # The image has no curl/wget; a failed check aborts activation, so retry with /dev/tcp.
          extraOptions = [
            "--network=proxy:ip=${proxyIp}"
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
