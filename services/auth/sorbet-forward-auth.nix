_: let
  proxyIp = "10.89.0.11";
in {
  flake = {
    podmanProxyHosts.sorbet-forward-auth.ip = proxyIp;

    nixosModules.sorbetForwardAuth = {
      config,
      pkgs,
      ...
    }: let
      clientSecret = config.sops.secrets."sorbet-forward-auth".path;
      # The image is distroless nonroot (uid 65532), so the rendered file has to
      # be owned by that uid; root-owned 0600 makes the process exit on start.
      configUid = "65532";
      writeConfig = pkgs.writeShellScript "sorbet-forward-auth-config" ''
        set -eu
        install -d -m 0755 -o ${configUid} -g ${configUid} /run/sorbet-forward-auth

        # The app takes no secrets from the environment, so the file is rendered
        # from the sops dotenv at start instead of living in the store.
        set -a
        . ${clientSecret}
        set +a
        : ''${POCKETID_CLIENT_SECRET:?POCKETID_CLIENT_SECRET missing from sorbet-forward-auth.env}

        cat >/run/sorbet-forward-auth/config.yaml <<EOF
        server:
          domains:
            - domain: "int.kuipr.de"
              authHost: "auth.int.kuipr.de"
        portals:
          - name: main
            providers:
              - pocketID:
                  endpoint: "https://id.ext.kuipr.de"
                  clientID: "sorbet-forward-auth"
                  clientSecret: "\$POCKETID_CLIENT_SECRET"
        EOF

        chown ${configUid}:${configUid} /run/sorbet-forward-auth/config.yaml
        chmod 0400 /run/sorbet-forward-auth/config.yaml
      '';
    in {
      sops.secrets."sorbet-forward-auth" = {
        sopsFile = ../../secrets/sorbet/sorbet-forward-auth.env;
        format = "dotenv";
        key = "";
        owner = "root";
        restartUnits = ["podman-sorbet-forward-auth.service"];
      };

      virtualisation.oci-containers.containers.sorbet-forward-auth = {
        # The login endpoint itself stays outside the gate, or the redirect loops.
        labels = {
          "traefik.enable" = "true";
          "traefik.docker.network" = "proxy";
          "traefik.http.routers.auth.rule" = "Host(`auth.int.kuipr.de`)";
          "traefik.http.routers.auth.entrypoints" = "websecure";
          "traefik.http.routers.auth.tls.certresolver" = "letsencrypt";
          "traefik.http.routers.auth.service" = "sorbet-forward-auth";
          "traefik.http.routers.auth.middlewares" = "sec-headers@file";
          "traefik.http.services.sorbet-forward-auth.loadbalancer.server.port" = "4181";
        };
        image = "ghcr.io/italypaleale/traefik-forward-auth:4";
        volumes = [
          "/run/sorbet-forward-auth:/etc/traefik-forward-auth:ro"
        ];
        log-driver = "journald";
        extraOptions = [
          "--network=proxy:ip=${proxyIp}"
        ];
      };

      systemd.services."podman-sorbet-forward-auth" = {
        requires = ["podman-create-network-proxy.service"];
        after = ["podman-create-network-proxy.service"];
        serviceConfig.ExecStartPre = writeConfig;
      };
    };
  };
}
