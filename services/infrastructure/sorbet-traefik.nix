_: let
  proxyIp = "10.89.0.10";
in {
  flake = {
    podmanProxyHosts.sorbet-traefik.ip = proxyIp;

    # The edge is a container, so newt reaches it by name: podmanProxyHosts puts
    # sorbet-traefik in /etc/hosts, which is what newt resolves it through.
    pangolinHostResources."int" = {
      site = "sorbet";
      name = "int (traefik edge)";
      destination = "sorbet-traefik";
      alias = "*.int.kuipr.de";
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
      staticConfig = yaml.generate "sorbet-traefik-static.yml" (import ./_sorbet-traefik/static.nix);
      dynamicConfig = yaml.generate "sorbet-traefik-dynamic.yml" (import ./_sorbet-traefik/dynamic.nix);
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

      # The plugin reads its client secret from a file, so only that one value is
      # extracted here instead of the whole dotenv file.
      sops.secrets."traefik/oidc_client_secret" = {
        sopsFile = ../../secrets/sorbet/sorbet-forward-auth.env;
        format = "dotenv";
        key = "POCKETID_CLIENT_SECRET";
        owner = "root";
        restartUnits = ["podman-sorbet-traefik.service"];
      };

      virtualisation.oci-containers.containers.sorbet-traefik = {
        image = "docker.io/library/traefik:v3.7.18@sha256:f4bb143d1135a579b630ed491e17ec50f6f7c9c6a30585ff3d385471d2a86f5a";
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
