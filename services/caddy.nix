# Caddy on sorbet: the LAN TLS edge for *.int.kuipr.de.
#
# Reintroduced as part of the Pangolin→NetBird migration: Pangolin used to
# serve every vhost until caddy was removed (commit 0c119ed) and everything
# moved behind pangolin's traefik. Now *.int terminates here again:
# LAN clients hit it directly (dnsmasq wildcard *.int.kuipr.de →
# 192.168.0.85), and NetBird-routed traffic (phone off-LAN) reaches it
# through sorbet's masqueraded LAN route — same FQDN, same cert, same
# app session in both cases.
#
# Certificates via bunny DNS-01 (names like has.int.kuipr.de aren't
# internet-reachable over HTTP), same acme_dns setup as eclair — caddy
# with the caddy-dns/bunny plugin.
{
  lib,
  config,
  ...
}: {
  options.flake.caddyVirtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        extraConfig = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Caddyfile site block body.";
        };
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Human-readable service name for the index page.";
        };
      };
    });
    default = {};
    description = ''
      Virtual hosts served by caddy on sorbet. Keys are hostnames
      (*.int.kuipr.de), values carry the site block body.
    '';
  };

  config.flake = {
    # Index page listing all vhosts.
    caddyVirtualHosts."home.int.kuipr.de" = {
      name = "sorbet";
    };

    gatusEndpoints = [
      {
        name = "Sorbet Index";
        group = "Infrastructure";
        url = "https://home.int.kuipr.de";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.caddy = let
      # Captured from the flake-parts module scope (config here is the
      # dendritic module's config, not the NixOS module's).
      virtualHosts = config.flake.caddyVirtualHosts;
    in
      {
        config,
        pkgs,
        ...
      }: let
        renderEntry = host: v: "<li><a href=\"https://${host}\">${
          lib.optionalString (v.name != null) (v.name + " ")
        }(${host})</a></li>";
        entryList = hosts:
          lib.concatStringsSep "\n" (lib.mapAttrsToList renderEntry hosts);
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
              ${entryList virtualHosts}
            </ul>
          </body>
          </html>
        '';
      in
        lib.mkIf (virtualHosts != {}) {
          networking.firewall.allowedTCPPorts = [80 443];

          sops.secrets."caddy/bunny_api_key" = {
            sopsFile = ../secrets/sorbet/caddy;
            format = "dotenv";
            key = "";
            owner = "caddy";
          };

          services.caddy = {
            enable = true;
            # enableReload (default) makes activation do a `caddy reload` — but a
            # reload cannot change the admin endpoint. The admin port is moved to
            # 2020 for the Tidal Connect binary
            # (services/music/tidal-connect.nix), so activation must restart.
            enableReload = false;
            package = pkgs.caddy.withPlugins {
              plugins = ["github.com/caddy-dns/bunny@v1.2.0"];
              hash = "sha256-MSUCHg7Ej7xSmfn5Y5JZtttOWOHcXqnrpmHlhoS4KLQ=";
            };
            globalConfig = ''
              # Port 2019 is the default admin endpoint, but the iFi Tidal
              # Connect binary hard-codes 2019 for its control websocket.
              admin localhost:2020
              # Bunny DNS-01: no listener needed, names resolve only on LAN.
              acme_dns bunny {env.BUNNY_API_KEY}
              # DNS-01 propagation checks must hit public resolvers, not the
              # system ones (resolv.conf → dnsmasq): dnsmasq hangs on CNAME
              # queries under its address=/.int.kuipr.de/ wildcard and can't
              # see the public TXT records anyway.
              tls_resolvers 1.1.1.1 8.8.8.8
            '';
            virtualHosts =
              lib.mapAttrs (_: v: {
                extraConfig = ''
                  log {
                    output stderr
                    level INFO
                  }
                  ${v.extraConfig}
                '';
              })
              virtualHosts
              // {
                "home.int.kuipr.de" = {
                  extraConfig = ''
                    root * ${indexDir}
                    file_server
                  '';
                };
              };
          };

          # The Caddyfile expands {$BUNNY_API_KEY} at parse time, so the env
          # file must exist before caddy starts.
          systemd.services.caddy.serviceConfig.EnvironmentFile = [
            config.sops.secrets."caddy/bunny_api_key".path
          ];
        };
  };
}
