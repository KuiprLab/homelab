# Music services flake-parts module
# Caddy virtual hosts and Gatus endpoints for music services.
# NixOS config is split across sibling *.nix files, each a standalone flake-parts module.
_: {
  flake = {
    caddyVirtualHosts = {
      "music.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:4533 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        '';
        name = "Navidrome";
      };
      "music.ext.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:4533 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        '';
        name = "Navidrome (ext)";
      };
      "musai.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:8000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        '';
        name = "Audiomuse AI";
      };
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
