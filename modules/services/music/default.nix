# Music services flake-parts module
# Caddy virtual hosts and Gatus endpoints for music services.
# NixOS config is split across sibling *.nix files, each a standalone flake-parts module.
_: {
  flake = {
    caddyVirtualHosts = {
      "music.ext.kuipr.de" = ''
        request_header -Remote-User

        @protected {
          not path /share/*
          not {
            path /rest/*
            not query c=NavidromeUI
          }
        }
        forward_auth @protected localhost:9091 {
          uri /api/authz/forward-auth?rd=https://auth.ext.kuipr.de/
          copy_headers Remote-User
        }

        reverse_proxy localhost:4533 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
      "tagger.int.kuipr.de" = ''
        reverse_proxy localhost:8099 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
      "musai.int.kuipr.de" = ''
        reverse_proxy localhost:8000 {
          header_up Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };

    gatusEndpoints = [
      {
        name = "Navidrome";
        group = "Music";
        url = "https://music.ext.kuipr.de";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
      {
        name = "Audiomuse AI";
        url = "https://musai.int.kuipr.de";
        group = "Music";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];
  };
}
