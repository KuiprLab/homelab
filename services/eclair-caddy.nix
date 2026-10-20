# Caddy on eclair: public TLS edge for *.ext.kuipr.de and the NetBird
# control plane (netbird.kuipr.de). With pangolin's traefik gone, caddy owns
# :80/:443 directly — bunny DNS-01, no HTTP-01 listener needed.
#
# Migration note: this file was removed in commit 0c119ed ("chore: remove
# caddy hosts") when everything moved behind pangolin; it is reintroduced
# stripped of the haproxy SNI hop, PROXY protocol, and CrowdSec AppSec
# forward_auth (all of those stacks are gone).
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
          default = "";
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
      Virtual hosts terminated by caddy on eclair (the public VPS). Keys are
      hostnames, values are Caddyfile site-block bodies.
    '';
  };

  config.flake.eclairNixosModules.caddy = let
    virtualHosts = config.flake.eclairCaddyVirtualHosts;
  in
    {
      lib,
      config,
      pkgs,
      ...
    }:
      lib.mkIf (virtualHosts != {}) {
        networking.firewall.allowedTCPPorts = [80 443];

        # Bunny API key for DNS-01. The old pangolin dotenv is decrypted as
        # a whole (key = "") so the file itself is the BUNNY_API_KEY=...
        # dotenv, consumed directly as caddy's EnvironmentFile.
        sops.secrets."pangolin/BUNNY_API_KEY" = {
          sopsFile = ../secrets/eclair/pangolin.env;
          format = "dotenv";
          key = "";
          owner = "caddy";
        };

        services.caddy = {
          enable = true;
          enableReload = false;
          package = pkgs.caddy.withPlugins {
            plugins = [
              "github.com/caddy-dns/bunny@v1.2.0"
              "github.com/mholt/caddy-l4@v0.1.2"
            ];
            hash = "sha256-l3ul/9sHBCA2oInyyCZd1ufHIp8rlkVcOy9uCHL5J8Y="; # empirically verified (caddy-l4 v0.1.2 + bunny v0.1.4)
          };
          globalConfig = ''
            # Bunny DNS-01 for the ext wildcard; no HTTP listener needed.
            acme_dns bunny {env.BUNNY_API_KEY}
            # Propagation checks should hit public resolvers.
            tls_resolvers 1.1.1.1 8.8.8.8
            # Route *.ext.kuipr.de TLS to the NetBird reverse proxy (127.0.0.1:8443)
            # without terminating; everything else terminates in the normal HTTP
            # server via the trailing `tls` wrapper (caddy-l4 pattern from
            # docs/examples/combining_apps.md).
            servers :443 {
              listener_wrappers {
                layer4 {
                  @prx tls sni *.ext.kuipr.de
                  route @prx {
                    proxy 127.0.0.1:8443
                  }
                }
                tls
              }
            }
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
            virtualHosts;
        };

        # The Caddyfile expands {$BUNNY_API_KEY} at parse time, so the env
        # file must exist before caddy starts.
        systemd.services.caddy.serviceConfig.EnvironmentFile = [
          config.sops.secrets."pangolin/BUNNY_API_KEY".path
        ];
      };
}
