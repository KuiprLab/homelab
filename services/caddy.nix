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

        anubis = lib.mkOption {
          type = lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Protect this vhost with Anubis (PoW bot challenge).
                  *.ext.kuipr.de only: the public site block stops at a
                  per-vhost Anubis instance (unix socket), which proxies
                  accepted traffic to an auto-generated loopback site
                  carrying this vhost's normal config (authelia wrap,
                  routes, headers).
                '';
              };
            };
          };
          default = {};
          description = ''
            Anubis PoW-challenge settings for this vhost.
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
      #
      # Anubis-protected vhosts (anubis.enable): Anubis has a single
      # TARGET, so there is one instance per vhost. The public site block
      # stops at the per-vhost anubis unix socket; the service config
      # (authelia wrap, routes, headers) moves verbatim to an
      # auto-generated loopback site that is the instance's TARGET. Anubis
      # forwards the original Host header, so the loopback sites use
      # port-only addresses with `bind 127.0.0.1` (empty host matcher).
      # Request order on *.ext vhosts: crowdsec appsec (edge, forward_auth
      # runs before reverse_proxy in caddy's directive order) → anubis →
      # authelia → backend.
      anubisVhosts = lib.filterAttrs (_: v: v.anubis.enable) virtualHosts;
      anubisHosts = lib.sort lib.lessThan (lib.attrNames anubisVhosts);
      # One deterministic loopback port per protected vhost. 41000+ is not
      # used by any service in this repo; binds are loopback-only.
      anubisPorts =
        lib.listToAttrs
        (lib.imap1 (i: host: lib.nameValuePair host (toString (40999 + i))) anubisHosts);

      # The service part of a site block: authelia wrap and the vhost's own
      # extraConfig. Runs at the edge for plain vhosts, and inside the
      # loopback site for anubis-protected ones.
      serviceConfig = v: let
        # Bypassed paths are still reverse-proxied to the app (extraConfig),
        # so sessionless gatus probes exercise the backend instead of getting
        # a synthetic 200 from caddy that could never fail regardless of
        # whether the app is actually healthy.
        bypassBlocks =
          lib.concatMapStringsSep "\n" (p: ''
            route ${p} {
              ${v.extraConfig}
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

      # Edge-facing site block: access log and crowdsec appsec (ext only,
      # caddy runs forward_auth before route/reverse_proxy), then either the
      # anubis hop (chain ends here, service part moves to the loopback
      # site) or the service part directly.
      edgeConfig = host: v: let
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
        accessLog
        + appsecAuth
        + (
          if v.anubis.enable
          then ''
            reverse_proxy unix//run/anubis/anubis-${host}/anubis.sock {
              header_up X-Real-IP {remote_host}
              header_up X-Http-Version {http.request.proto}
              header_up X-TLS-SNI-Name {tls_server_name}
            }
          ''
          else serviceConfig v
        );
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
            hash = "sha256-MSUCHg7Ej7xSmfn5Y5JZtttOWOHcXqnrpmHlhoS4KLQ=";
          };
          globalConfig = ''
            # Port 2019 is the default admin endpoint, but the iFi Tidal
            # Connect binary (services/music/tidal-connect.nix) hard-codes
            # 2019 for its control websocket on the host network and the
            # phone's TIDAL app connects to the port advertised over mDNS.
            admin localhost:2020
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
            # Global trusted_proxies: the anubis loopback hop (127.0.0.1) is
            # trusted so the edge's X-Forwarded-Proto/Host/For survive the
            # loopback re-entry; untrusted, caddy would strip them and
            # re-set X-Forwarded-Proto to http, making authelia's
            # forward-auth reject every wrapped path with a plain-text 400
            # (insecure scheme). Safe globally: the :41000 loopback ports
            # bind-restricted to anubis, and no public-listener client ever
            # connects from 127.0.0.1. (Per-site `servers` blocks are only
            # supported in caddy >= 2.13; sorbet runs 2.11.)
            servers {
              listener_wrappers {
                proxy_protocol {
                  allow 100.99.168.34/32
                  fallback_policy IGNORE
                }
                tls
              }
              trusted_proxies static 127.0.0.1/32
            }
          '';
          virtualHosts =
            lib.mapAttrs (host: v: {extraConfig = edgeConfig host v;}) virtualHosts
            # Anubis TARGETs: loopback sites carrying the normal service
            # config. `bind` keeps them off the LAN; the port-only address
            # keeps the host matcher empty because anubis forwards the
            # original Host header. logFormat discard: the edge site already
            # logs each request once (the nixpkgs module would otherwise
            # give these a file logger with the port in the path).
            // (lib.mapAttrs' (host: _:
              lib.nameValuePair "http://:${anubisPorts.${host}}" {
                logFormat = "output discard";
                extraConfig = ''
                  bind 127.0.0.1
                  ${serviceConfig anubisVhosts.${host}}
                '';
              })
            anubisVhosts)
            // {
              "home.int.kuipr.de" = {
                extraConfig = ''
                  root * ${indexDir}
                  file_server
                '';
              };
            };
        };

        # Anubis instances for protected vhosts. Policy = upstream defaults
        # (deny known AI crawlers, PoW-challenge browser-like traffic, pass
        # weight-0 clients such as API clients with unknown UAs) plus an
        # explicit ALLOW for gatus so sessionless probes keep working.
        services.anubis.instances =
          lib.mapAttrs (host: _: {
            settings.TARGET = "http://127.0.0.1:${anubisPorts.${host}}";
            policy.extraBots = [
              {
                name = "gatus-health-probes";
                user_agent_regex = "(?i)gatus";
                action = "ALLOW";
              }
            ];
          })
          anubisVhosts;

        # caddy connects to the anubis unix sockets (SOCKET_MODE 0770, group
        # anubis) — same pattern as the nginx example in the nixpkgs anubis
        # module docs.
        users.users.caddy.extraGroups = lib.mkIf (anubisHosts != []) ["anubis"];

        assertions =
          lib.mapAttrsToList (host: _: {
            assertion = lib.hasSuffix ".ext.kuipr.de" host;
            message = "anubis.enable is only supported on *.ext.kuipr.de vhosts (${host})";
          })
          anubisVhosts;

        # Bring the anubis sockets up with caddy so the edge proxy never
        # 502s against a missing socket after boot.
        systemd.services.caddy = {
          wants = map (h: "anubis-${h}.service") anubisHosts;
          after = map (h: "anubis-${h}.service") anubisHosts;
          serviceConfig.EnvironmentFile = [
            config.sops.secrets."caddy/bunny_api_key".path
            # CADDY_APPSEC_KEY for the AppSec forward_auth on *.ext vhosts
            # (expanded at Caddyfile parse time, like the bunny key).
            config.sops.secrets."caddy/crowdsec-appsec".path
          ];
        };
      };
  };
}
