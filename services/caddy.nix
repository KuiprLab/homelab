{
  lib,
  config,
  ...
}: let
  vhosts = config.flake.pangolinVirtualHosts;

  byCaddy = lib.filterAttrs (_: v: v.private && v.site == "sorbet" && !(v.extra ? mode)) vhosts;

  stray = lib.filterAttrs (_: v: v.private && v.site != "sorbet" && !(v.extra ? mode)) vhosts;
in {
  flake = {
    pangolinHostResources."int" = {
      site = "sorbet";
      name = "int (caddy edge)";
      destination = "127.0.0.1";
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

          sops.secrets."caddy/bunny_api_key" = {
            sopsFile = ../secrets/sorbet/caddy;
            format = "binary";
            key = "";
            owner = "caddy";
          };

          services.caddy = {
            enable = true;
            # Admin port is pinned to 2020, so a reload cannot pick it up.
            enableReload = false;
            package = pkgs.caddy.withPlugins {
              plugins = ["github.com/caddy-dns/bunny@v1.2.0"];
              hash = "sha256-ymMx2tSs9hgRji+KalPig/rdPiFqbjaLO3UFwZYPggI=";
            };
            globalConfig = ''
              admin localhost:2020
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
