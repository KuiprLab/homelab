{
  config,
  lib,
  ...
}: let
  constants = config.flake.constants;
  proxyIp = "10.89.0.10";
in {
  imports = [./_sorbet-traefik/options.nix];

  flake = {
    sorbetTraefikLabels = import ./_sorbet-traefik/labels.nix {inherit lib;};
    podmanProxyHosts.sorbet-traefik.ip = proxyIp;

    # The edge is a container, so newt reaches it by name: podmanProxyHosts puts
    # sorbet-traefik in /etc/hosts, which is what newt resolves it through.
    pangolinHostResources."int" = {
      site = "sorbet";
      name = "int (traefik edge)";
      destination = "sorbet-traefik";
      alias = "*.${constants.intDomain}";
      tcpPorts = "443";
      udpPorts = "";
      icmp = false;
    };

    nixosModules.sorbetTraefik = {
      config,
      pkgs,
      ...
    }: let
      yaml = pkgs.formats.yaml {};
      staticConfig = yaml.generate "sorbet-traefik-static.yml" (import ./_sorbet-traefik/static.nix {inherit constants;});
      dynamicConfig = yaml.generate "sorbet-traefik-dynamic.yml" (import ./_sorbet-traefik/dynamic.nix {inherit constants;});
    in {
      networking.firewall.allowedTCPPorts = [80 443];

      sops.secrets."traefik/bunny_api_key" = {
        # Reused from the previous edge; the file holds BUNNY_API_KEY=...
        sopsFile = ../../secrets/sorbet/caddy;
        format = "binary";
        key = "";
        owner = "root";
        restartUnits = ["podman-sorbet-traefik.service"];
      };

      # Only one value of the client definition is secret: the plugin reads it from
      # a file, so extract exactly that path from the file the provisioner applies.
      sops.secrets."traefik/oidc_client_secret" = {
        sopsFile = ../../secrets/sorbet/pocketid/clients.json;
        format = "json";
        key = "sorbet-forward-auth/secret";
        owner = "root";
        restartUnits = ["podman-sorbet-traefik.service"];
      };

      virtualisation.oci-containers.containers.sorbet-traefik = {
        image = "docker.io/library/traefik:v3.7.18@sha256:9c437ac4f09ce6f4980a8544902d3475fdf70a1a7c578729581d2535dfa7d635";
        volumes = [
          "${staticConfig}:/etc/traefik/traefik.yml:ro"
          "${dynamicConfig}:/etc/traefik/dynamic/dynamic.yml:ro"
          "${config.sops.secrets."traefik/oidc_client_secret".path}:/run/secrets/oidc-client-secret:ro"
          "/run/podman/podman.sock:/var/run/docker.sock:ro"
          "sorbet-traefik-acme:/data"
          "sorbet-traefik-plugins:/plugins-storage"
        ];
        # 80/443 stay published: LAN clients reach the edge on 192.168.0.85, which a
        # bridged container can only serve through a host publish.
        ports = [
          "80:80"
          "443:443"
        ];
        # The oidc plugin insists on a 32-character session key. base64 of 24 bytes
        # is exactly that; keep it in the volume so a restart does not log everyone out.
        entrypoint = "/bin/sh";
        cmd = [
          "-c"
          "test -s /data/oidc-session-secret || head -c 24 /dev/urandom | base64 > /data/oidc-session-secret; exec traefik"
        ];
        log-driver = "journald";
        extraOptions = [
          "--network=proxy:ip=${proxyIp}"
          "--env-file=${config.sops.secrets."traefik/bunny_api_key".path}"
        ];
      };

      systemd.services."podman-sorbet-traefik" = {
        requires = [
          "podman.socket"
          "podman-create-network-proxy.service"
        ];
        after = [
          "podman.socket"
          "podman-create-network-proxy.service"
        ];
      };
    };
  };
}
