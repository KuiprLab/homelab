# Caddy on eclair — terminates TLS locally for services hosted on the VPS
# itself, so their traffic never crosses the tailnet to sorbet.
#
# haproxy owns :80/:443, so caddy listens on 127.0.0.1:8443 and haproxy
# routes the matching SNI there (see haproxy.nix). Certificates come from
# ACME TLS-ALPN-01: the challenge handshake carries the same SNI, so haproxy
# passes it straight through to caddy — no DNS credentials needed.
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
        globalConfig = ''
          # haproxy holds :80/:443; it forwards the local SNIs to 8443.
          http_port 8080
          https_port 8443
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
              ${v.extraConfig}
            '';
          })
          virtualHosts;
      };
    };
}
