# Caddy on eclair — terminates TLS locally for services hosted on the VPS
# itself, so their traffic never crosses the tailnet to sorbet.
#
# haproxy owns :80/:443, so caddy listens on 127.0.0.1:8443 and haproxy
# routes the matching SNI there (see haproxy.nix). Certificates come from
# ACME HTTP-01: the challenge rides haproxy's :80 → 8080 hop — no DNS
# credentials needed.
#
# haproxy speaks PROXY protocol to caddy (send-proxy-v2); without it caddy
# would see every client as 127.0.0.1 and CrowdSec bans would be useless.
# The wrapper only honors PROXY headers from 127.0.0.1 (fallback IGNORE),
# so a direct internet client can't spoof a client IP with a forged header.
# Per-vhost `log` directives emit JSON access logs to journald, which the
# CrowdSec agent tails (services/crowdsec.nix).
{
  lib,
  config,
  ...
}: {
  options.flake.eclairCaddyVirtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        extraConfig = lib.mkOption {
          type = lib.types.str;
          description = "Caddyfile site block body.";
        };
        name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Human-readable service name.";
        };
      };
    });
    default = {};
    description = ''
      Virtual hosts terminated by caddy on eclair rather than on sorbet.
      haproxy routes their SNI to the local caddy instead of the tailnet.
    '';
  };

  config.flake.eclairNixosModules.caddy = let
    virtualHosts = config.flake.eclairCaddyVirtualHosts;
  in
    lib.mkIf (virtualHosts != {}) {
      services.caddy = {
        enable = true;
        # CADDY_APPSEC_KEY for the AppSec forward_auth (file maintained by
        # crowdsec-caddy-appsec-register.service, see services/crowdsec.nix).
        environmentFile = "/var/lib/crowdsec-caddy-appsec/api-key.env";
        globalConfig = ''
          # haproxy holds :80/:443; it forwards the local SNIs to 8443.
          http_port 8080
          https_port 8443

          servers {
            listener_wrappers {
              proxy_protocol {
                allow 127.0.0.1/32
                fallback_policy IGNORE
              }
              tls
            }
          }
        '';
        virtualHosts =
          lib.mapAttrs (_: v: {
            extraConfig = ''
              # TLS-ALPN-01 doesn't survive the haproxy SNI hop; HTTP-01 does.
              tls {
                issuer acme {
                  disable_tlsalpn_challenge
                }
              }
              # Access logs → stderr → journald → CrowdSec agent. Explicit
              # own logger: the module's global default logger runs at level
              # ERROR (services.caddy.logFormat), which would swallow the
              # INFO-level access entries.
              log {
                output stderr
                level INFO
              }
              # CrowdSec AppSec (WAF): clone each request to the local appsec
              # listener for inspection — 2xx continues, otherwise (e.g. 403
              # from an in-band WAF rule) the response is sent to the client.
              # The engine reads the request details from dedicated headers,
              # so they are set explicitly here and a client can't spoof
              # them (header_up replaces anything the client sent). Note:
              # fail-closed — if the crowdsec agent is down, so are the
              # vhosts.
              forward_auth 127.0.0.1:7422 {
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
              ${v.extraConfig}
            '';
          })
          virtualHosts;
      };

      # The AppSec key env-file must exist before caddy parses its config
      # (the Caddyfile expands {$CADDY_APPSEC_KEY} at load time).
      systemd.services.caddy = {
        after = ["crowdsec-caddy-appsec-register.service"];
        requires = ["crowdsec-caddy-appsec-register.service"];
      };
    };
}
