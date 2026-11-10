{
  lib,
  config,
  ...
}: let
  vhosts = config.flake.pangolinVirtualHosts;

  byCaddy = lib.filterAttrs (_: v: v.private && v.site == "sorbet" && !(v.extra ? mode)) vhosts;

  stray = lib.filterAttrs (_: v: v.private && v.site != "sorbet" && !(v.extra ? mode)) vhosts;

  reverseProxyFor = v:
    "reverse_proxy ${v.protocol}://${v.hostname}:${toString v.port}"
    + lib.optionalString v.tlsInsecureSkipVerify " {\n  transport http {\n    tls_insecure_skip_verify\n  }\n}";

  pocketIdUrl = "https://id.ext.kuipr.de";
  oidcClientId = "caddy-security";

  authVhosts = lib.filterAttrs (_: v: v.auth.enable) byCaddy;

  trustLoginRedirects =
    lib.concatMapStringsSep "\n        " (v: "trust login redirect uri domain exact ${v.subdomain} path prefix /")
    (lib.attrValues authVhosts);

  # Bypass paths still reach the backend: the pangolin health check uses one and
  # must not be answered with a redirect to the login.
  siteRoutesFor = v: let
    bypass =
      lib.concatMapStringsSep "\n" (p: ''
        route ${p} {
          ${reverseProxyFor v}
        }
      '')
      v.auth.bypassPaths;
  in
    if !v.auth.enable
    then reverseProxyFor v
    else ''
      @login path /caddy-security/*
      route @login {
        authenticate with pocketid_portal
      }
      ${bypass}
      route {
        authorize with pocketid_policy
        ${reverseProxyFor v}
      }
    '';

  loginConfig = ''
    order authenticate before respond
    security {
      oauth identity provider pocketid {
        realm pocketid
        driver generic
        client_id ${oidcClientId}
        client_secret {env.POCKETID_OIDC_CLIENT_SECRET}
        scopes openid email profile
        base_auth_url ${pocketIdUrl}
        metadata_url ${pocketIdUrl}/.well-known/openid-configuration
      }

      authentication portal pocketid_portal {
        crypto default token lifetime 3600
        crypto key sign-verify {env.CADDY_SECURITY_JWT_KEY}
        enable identity provider pocketid
        ${trustLoginRedirects}
        transform user {
          match realm pocketid
          action add role authp/user
        }
      }

      authorization policy pocketid_policy {
        set auth url /caddy-security/oauth2/pocketid
        allow roles authp/user
      }
    }
  '';
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

          sops.secrets."caddy/security" = {
            sopsFile = ../secrets/sorbet/caddy-security.env;
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
              ];
              hash = "sha256-TcG1GI0T8qiVUeha/e3izU0tz4MpSDj8S1JU51AA/ZA=";
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

          systemd.services.caddy.serviceConfig.EnvironmentFile = [
            config.sops.secrets."caddy/bunny_api_key".path
            config.sops.secrets."caddy/security".path
          ];
        };
  };
}
