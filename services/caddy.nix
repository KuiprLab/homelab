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
      #
      # External (*.ext.kuipr.de) vhosts additionally clone every request to
      # eclair's CrowdSec AppSec engine over the tailnet (WAF inspection;
      # see services/crowdsec.nix on eclair). AppSec runs BEFORE authelia so
      # obvious junk is blocked before touching the session store. Note:
      # fail-closed — if eclair's crowdsec agent is down, these vhosts are
      # down. Internal (*.int.kuipr.de) vhosts are LAN-only and skip it.
      siteConfig = host: v: let
        appsecAuth =
          if !lib.hasSuffix ".ext.kuipr.de" host
          then ""
          else ''
            forward_auth 100.99.168.34:7422 {
              # the appsec reads the real URI from a header; this is just
              # the wire path (a required subdirective in caddy 2.11).
              uri /
              header_up X-Crowdsec-Appsec-Ip {remote_host}
              header_up X-Crowdsec-Appsec-Verb {method}
              header_up X-Crowdsec-Appsec-Uri {uri}
              header_up X-Crowdsec-Appsec-Host {host}
              header_up X-Crowdsec-Appsec-User-Agent {header.User-Agent}
              header_up X-Crowdsec-Appsec-Api-Key {$CADDY_APPSEC_KEY}
            }
          '';
        bypassBlocks =
          lib.concatMapStringsSep "\n" (p: ''
            route ${p} {
              respond "ok" 200
            }
          '')
          v.authelia.bypassPaths;
        # Access logs → stderr → journald → rsyslog ships them to eclair's
        # CrowdSec (services/crowdsec-shipping.nix). Own logger: the module's
        # global default logger runs at ERROR (services.caddy.logFormat),
        # which would swallow the INFO-level access entries.
        accessLog = ''
          log {
            output stderr
            level INFO
          }
        '';
      in
        if !v.authelia.enable
        then accessLog + appsecAuth + v.extraConfig
        else ''
          ${accessLog}
          ${bypassBlocks}
          route {
            ${appsecAuth}
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
        # Index page lists vhosts split by hostname suffix: *.int.kuipr.de
        # (LAN dnsmasq) under "Internal", everything else (*.ext.kuipr.de,
        # the public VPS) under "External".
        renderEntry = host: v: let
          displayName =
            if v.name != null
            then v.name
            else host;
          hasDomain = v.name != null;
        in
          "<li><a href=\"https://${host}\">${displayName}</a>"
          + (
            if hasDomain
            then " <span class='domain'>(${host})</span>"
            else ""
          )
          + "</li>";
        entryList = hosts:
          lib.concatStringsSep "\n" (lib.mapAttrsToList renderEntry hosts);
        internalHosts = lib.filterAttrs (host: _: lib.hasSuffix ".int.kuipr.de" host) virtualHosts;
        externalHosts = lib.filterAttrs (host: _: !lib.hasSuffix ".int.kuipr.de" host) virtualHosts;

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
              h2 { font-size: 1rem; font-weight: 600; margin: 1.4em 0 0.3em; }
              ul { list-style: none; padding: 0; }
              li { margin: 0.4em 0; }
              a { color: -webkit-link; }
              .domain { color: #666; font-size: 0.85em; }
              hr { margin: 1.5em 0; border: none; border-top: 1px solid #ccc; }
            </style>
          </head>
          <body>
            <h1>sorbet</h1>
            <h2>Internal</h2>
            <ul>
              ${entryList internalHosts}
            </ul>
            <h2>External</h2>
            <ul>
              ${entryList externalHosts}
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

        # Shared with eclair: the API key sorbet's caddy sends to eclair's
        # AppSec listener (registered as `sorbet-caddy-appsec` there).
        sops.secrets."caddy/crowdsec-appsec" = {
          sopsFile = ../secrets/sorbet/crowdsec-appsec;
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
            # DNS-01 propagation checks must hit public resolvers, not the
            # system ones (resolv.conf -> dnsmasq): dnsmasq hangs on CNAME
            # queries under its address=/.int.kuipr.de/ wildcard, which
            # aborts caddy 2.11's mandatory propagation check, and it can't
            # see the public TXT records anyway.
            tls_resolvers 1.1.1.1 8.8.8.8
            # eclair's haproxy speaks PROXY protocol on the tailnet hop so
            # caddy sees real client IPs (authelia attributes via XFF, and
            # the access logs are shipped to eclair's CrowdSec). The wrapper
            # only honors PROXY headers from eclair; direct LAN clients
            # connect without one (fallback IGNORE), same pattern as
            # services/eclair-caddy.nix on the VPS.
            servers {
              listener_wrappers {
                proxy_protocol {
                  allow 100.99.168.34/32
                  fallback_policy IGNORE
                }
                tls
              }
            }
          '';
          virtualHosts =
            lib.mapAttrs (host: v: {extraConfig = siteConfig host v;}) virtualHosts
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
          # CADDY_APPSEC_KEY for the AppSec forward_auth on *.ext vhosts
          # (expanded at Caddyfile parse time, like the bunny key).
          config.sops.secrets."caddy/crowdsec-appsec".path
        ];
      };
  };
}
