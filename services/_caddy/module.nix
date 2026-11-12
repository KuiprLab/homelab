{
  lib,
  vhosts,
}: let
  inherit
    (import ./caddyfile.nix {inherit lib vhosts;})
    byCaddy
    stray
    authVhosts
    dockerVhosts
    caddyLabelsFor
    siteRoutesFor
    loginConfig
    ;
in
  {
    config,
    pkgs,
    ...
  }: let
    renderEntry = v: "<li><a href=\"https://${v.subdomain}\">${
      lib.optionalString (v.name != null) (v.name + " ")
    }(${v.subdomain})</a></li>";
    indexDir = pkgs.writeTextDir "index.html" ''
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>sorbet</title>
        <style>
          body { font-family: sans-serif; max-width: 40em; margin: 2em auto; padding: 0 1em; }
          h1 { font-size: 1.2rem; font-weight: 600; margin-bottom: 0.4em; }
          ul { list-style: none; padding: 0; }
          li { margin: 0.4em 0; }
          a { color: -webkit-link; }
        </style>
      </head>
      <body>
        <h1>sorbet</h1>
        <ul>
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: renderEntry) byCaddy)}
        </ul>
      </body>
      </html>
    '';
  in
    if stray != {}
    then
      throw "caddy: private vhosts on a non-sorbet site need an explicit pangolin extra.mode: ${
        lib.concatStringsSep ", " (lib.attrNames stray)
      }"
    else
      lib.mkIf (byCaddy != {}) {
        networking.firewall.allowedTCPPorts = [80 443];

        sops.secrets."caddy/bunny_api_key" = {
          sopsFile = ../../secrets/sorbet/caddy;
          format = "binary";
          key = "";
          owner = "caddy";
        };

        sops.secrets."caddy/security" = {
          sopsFile = ../../secrets/sorbet/caddy-security.env;
          format = "dotenv";
          key = "";
          owner = "caddy";
          mode = "0400";
          restartUnits = ["caddy.service"];
        };

        services.caddy = {
          enable = true;
          # Admin port is pinned to 2020, so a reload cannot pick it up.
          enableReload = false;
          package = pkgs.caddy.withPlugins {
            plugins = [
              "github.com/caddy-dns/bunny@v1.2.0"
              "github.com/greenpau/caddy-security@v1.6.2"
              "github.com/invzhi/caddy-docker-upstreams@v1.2.0"
            ];
            hash = "sha256-7LvXpl/SLLw6TNcVeAZHcZA7TMB9xtRHDmprU1f+NIc=";
          };
          globalConfig = ''
            admin localhost:2020
            ${lib.optionalString (authVhosts != {}) loginConfig}
            acme_dns bunny {env.BUNNY_API_KEY}
            # ACME TXT records are public and deliberately not in the LAN zone.
            tls_resolvers 1.1.1.1 8.8.8.8
          '';
          virtualHosts =
            lib.mapAttrs' (_: v:
              lib.nameValuePair v.subdomain {
                extraConfig = ''
                  log {
                    output stderr
                    level INFO
                    # Query strings carry admin tokens; journald must not keep them.
                    format filter {
                      request>uri query {
                        hash token
                      }
                      request>headers>X-Csrftoken delete
                    }
                  }
                  ${siteRoutesFor v}
                '';
              })
            byCaddy
            // {
              "home.int.kuipr.de" = {
                extraConfig = ''
                  root * ${indexDir}
                  file_server
                '';
              };
            };
        };

        virtualisation.oci-containers.containers =
          lib.listToAttrs (map (v: lib.nameValuePair v.containerHost {labels = caddyLabelsFor v;}) dockerVhosts);

        assertions = [
          {
            assertion = lib.all (v: config.virtualisation.oci-containers.containers ? ${v.containerHost}) dockerVhosts;
            message = "caddy: containerHost of a vhost names no container: ${lib.concatStringsSep ", " (map (v: v.subdomain) (lib.filter (v: !(config.virtualisation.oci-containers.containers ? ${v.containerHost})) dockerVhosts))}";
          }
        ];

        # The docker module reads the podman socket at /run/podman/podman.sock.
        # Caddy fails to provision at all without it, so order the start.
        users.users.caddy.extraGroups = ["podman"];

        systemd.services.caddy = {
          requires = ["podman.socket"];
          after = ["podman.socket"];
          serviceConfig = {
            Environment = ["DOCKER_HOST=unix:///run/podman/podman.sock"];
            EnvironmentFile = [
              config.sops.secrets."caddy/bunny_api_key".path
              config.sops.secrets."caddy/security".path
            ];
          };
        };
      }
