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

        # Bunny API key for DNS-01. Kept in the old pangolin dotenv (same key
        # pangolin's traefik used for the *.ext wildcard); rendered into a
        # caddy-owned env file via sops.templates.
        sops = {
          secrets."pangolin/BUNNY_API_KEY" = {
            sopsFile = ../secrets/eclair/pangolin.env;
            format = "dotenv";
            key = "BUNNY_API_KEY";
            owner = "root";
          };
          templates."caddy/env" = {
            content = "BUNNY_API_KEY=${config.sops.secrets."pangolin/BUNNY_API_KEY".path}";
            owner = "caddy";
          };
        };

        services.caddy = {
          enable = true;
          enableReload = false;
          package = pkgs.caddy.withPlugins {
            plugins = ["github.com/caddy-dns/bunny@v1.2.0"];
            hash = "sha256-92prKdGudX4MAEfUjyCrtpWoy6p5rwYxEEDnzLg2fmI=";
          };
          globalConfig = ''
            # Bunny DNS-01 for the ext wildcard; no HTTP listener needed.
            acme_dns bunny {env.BUNNY_API_KEY}
            # Propagation checks should hit public resolvers.
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
            virtualHosts;
        };

        # The Caddyfile expands {$BUNNY_API_KEY} at parse time, so the env
        # file must exist before caddy starts.
        systemd.services.caddy.serviceConfig.EnvironmentFile = [
          config.sops.templates."caddy/env".path
        ];
      };
}
