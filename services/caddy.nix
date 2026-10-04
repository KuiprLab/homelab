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
          description = ''
            Caddyfile site block body. Injected as a vhost extraConfig.
          '';
        };
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Human-readable service name for the auto-generated index page.
            Falls back to the hostname when null.
          '';
        };

        authelia = lib.mkOption {
          type = lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Protect this vhost with Authelia forward auth. Caddy checks
                  the session against authelia on 127.0.0.1:9091 before the
                  backend receives the request.
                '';
              };
              bypassPaths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = ''
                  Paths that skip forward auth and answer HTTP 200 directly.
                  Use for sessionless health checks, for example gatus probing
                  its own dashboard.
                '';
              };
            };
          };
          default = {};
          description = ''
            Authelia forward-auth settings for this vhost.
          '';
        };
      };
    });
    default = {};
    description = ''
      Caddy virtual host configurations contributed by service modules.
      Keys are hostnames, values are submodules with extraConfig and
      optional name (shown on the index page at home.int.kuipr.de).
    '';
  };

  config.flake = {
    # Placeholder entries for auto-generated vhosts (overridden by NixOS module
    # where pkgs is available). Keeps the hostname registered so gatus/caddy
    # can reference it.
    caddyVirtualHosts = {
      "home.int.kuipr.de" = {
        extraConfig = ''
          templates
          file_server
        '';
        name = "sorbet";
      };
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
      virtualHosts = config.flake.caddyVirtualHosts;

      # Render one vhost's Caddyfile site block. With authelia enabled, wrap
      # the service config in a route group so forward_auth runs before the
      # backend directives. Bypass paths become sibling route blocks that
      # answer 200 directly — sibling routes match first-come, so a bypassed
      # path never reaches forward_auth.
      siteConfig = v: let
        bypassBlocks =
          lib.concatMapStringsSep "\n" (p: ''
            route ${p} {
              respond "ok" 200
            }
          '')
          v.authelia.bypassPaths;
      in
        if !v.authelia.enable
        then v.extraConfig
        else ''
          ${bypassBlocks}
          route {
            forward_auth 127.0.0.1:9091 {
                    uri /api/authz/forward-auth
                    copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
            }
            ${v.extraConfig}
          }
        '';
    in
      {
        pkgs,
        config,
        ...
      }: let
        indexDir = pkgs.writeTextDir "index.html" ''
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>sorbet</title>
            <style>
              body { font-family: sans-serif; max-width: 40em; margin: 2em auto; padding: 0 1em; }
              h1 { font-size: 1.2rem; font-weight: 600; margin-bottom: 1em; }
              ul { list-style: none; padding: 0; }
              li { margin: 0.4em 0; }
              a { color: -webkit-link; }
              .domain { color: #666; font-size: 0.85em; }
              hr { margin: 1.5em 0; border: none; border-top: 1px solid #ccc; }
            </style>
          </head>
          <body>
            <h1>sorbet</h1>
            <ul>
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (host: v: let
              displayName =
                if v.name != null
                then v.name
                else host;
              hasDomain = v.name != null;
            in ''
              <li><a href="https://${host}">${displayName}</a>${
                if hasDomain
                then " <span class='domain'>(${host})</span>"
                else ""
              }</li>
            '')
            virtualHosts)}
            </ul>
            <hr>
          </body>
          </html>
        '';
      in {
        networking.firewall.allowedTCPPorts = [80 443 3001];

        sops.secrets."caddy/bunny_api_key" = {
          sopsFile = ../secrets/sorbet/caddy;
          format = "binary";
          key = "";
          owner = "caddy";
        };

        services.caddy = {
          enable = true;
          package = pkgs.caddy.withPlugins {
            plugins = ["github.com/caddy-dns/bunny@v1.2.0"];
            hash = "sha256-zKqfJW6ScRsrYTwUTyGkj46G5//RwHITd+a/mDj/6FQ=";
          };
          globalConfig = ''
            acme_dns bunny {env.BUNNY_API_KEY}
          '';
          virtualHosts =
            lib.mapAttrs (_: v: {extraConfig = siteConfig v;}) virtualHosts
            // {
              "home.int.kuipr.de" = {
                extraConfig = ''
                  root * ${indexDir}
                  file_server
                '';
              };
            };
        };

        systemd.services.caddy.serviceConfig.EnvironmentFile =
          config.sops.secrets."caddy/bunny_api_key".path;
      };
  };
}
