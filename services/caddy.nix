# Caddy on sorbet: the LAN TLS edge for *.int.kuipr.de.
#
# int services are not enumerated in pangolin. One pangolin host
# client-resource (flake.pangolinHostResources."int", declared below) carries
# every *.int.kuipr.de name over the tunnel to caddy's loopback:443, where TLS
# terminates and the request is proxied to the backend named in the matching
# flake.pangolinVirtualHosts entry. LAN clients reach the same listener
# directly (pihole answers *.int.kuipr.de with 192.168.0.85), so no pangolin
# client is needed at home — same FQDN, same certificate, same app session
# either way.
#
# Certificates come from bunny DNS-01: the names do not resolve publicly, so
# HTTP-01 cannot work. Previously pangolin's traefik issued one certificate
# per int client-resource; terminating here keeps int traffic off the tunnel
# and makes a new int service work off-LAN with no pangolin entry at all.
{
  lib,
  config,
  ...
}: let
  vhosts = config.flake.pangolinVirtualHosts;

  # Private http vhosts are served here. Entries carrying an explicit
  # pangolin mode (ssh-sorbet) stay client-resources in pangolin.nix.
  byCaddy = lib.filterAttrs (_: v: v.private && v.site == "sorbet" && !(v.extra ? mode)) vhosts;

  # A private vhost on another site would be served by neither side: caddy
  # only runs on sorbet, and pangolin resources now need an explicit mode.
  stray = lib.filterAttrs (_: v: v.private && v.site != "sorbet" && !(v.extra ? mode)) vhosts;
in {
  flake = {
    pangolinHostResources."int" = {
      site = "sorbet";
      name = "int (caddy edge)";
      # Loopback of the site host: independent of the LAN address, so the
      # route keeps working if caddy stops listening on the LAN interface or
      # sorbet changes address.
      destination = "127.0.0.1";
      # Wildcard aliases are only allowed on single-host resources (not CIDR)
      # and do not match the apex int.kuipr.de itself (schema:
      # PrivateResourceSchema, alias regex).
      alias = "*.int.kuipr.de";
      tcpPorts = "443";
      udpPorts = "";
      icmp = false;
    };

    nixosModules.caddy = {
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

          # Raw `BUNNY_API_KEY=...` line (binary sops file): caddy expands
          # {env.BUNNY_API_KEY} at Caddyfile parse time, so the env file must
          # exist before the unit starts.
          sops.secrets."caddy/bunny_api_key" = {
            sopsFile = ../secrets/sorbet/caddy;
            format = "binary";
            key = "";
            owner = "caddy";
          };

          services.caddy = {
            enable = true;
            # A reload cannot change the admin endpoint. The admin port is
            # moved to 2020 for the Tidal Connect binary
            # (services/music/tidal-connect.nix), so activation must restart.
            enableReload = false;
            package = pkgs.caddy.withPlugins {
              plugins = ["github.com/caddy-dns/bunny@v1.2.0"];
              hash = "sha256-92prKdGudX4MAEfUjyCrtpWoy6p5rwYxEEDnzLg2fmI=";
            };
            globalConfig = ''
              # Port 2019 is the default admin endpoint, but the iFi Tidal
              # Connect binary hard-codes 2019 for its control websocket.
              admin localhost:2020
              # Bunny DNS-01: no listener needed, names resolve only on LAN.
              acme_dns bunny {env.BUNNY_API_KEY}
              # DNS-01 propagation checks must hit public resolvers, not the
              # system ones (resolv.conf → dnsmasq): dnsmasq hangs on CNAME
              # queries under its address=/.int.kuipr.de/ wildcard and cannot
              # see the public TXT records anyway.
              tls_resolvers 1.1.1.1 8.8.8.8
            '';
            virtualHosts =
              lib.mapAttrs' (_: v:
                lib.nameValuePair v.subdomain {
                  extraConfig = ''
                    log {
                      output stderr
                      level INFO
                    }
                    reverse_proxy ${v.protocol}://${v.hostname}:${toString v.port}
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

          systemd.services.caddy.serviceConfig.EnvironmentFile = [
            config.sops.secrets."caddy/bunny_api_key".path
          ];
        };
  };
}
