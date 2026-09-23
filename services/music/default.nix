# Music services flake-parts module
# Caddy virtual hosts and Gatus endpoints for music services.
# NixOS config is split across sibling *.nix files, each a standalone flake-parts module.
_: let
  # Navidrome "Externalized Authentication":
  #  - always strip any client-supplied Remote-User (trust only authelia)
  #  - forward_auth the web app
  #  - /share/* and /rest/* keep their own auth: share links work without a
  #    session, and subsonic clients (Arpeggi, koito, lastfm-discord-presence)
  #    authenticate to navidrome with subsonic u/t/s credentials — authelia
  #    cannot speak that scheme, so putting /rest behind forward_auth blocks
  #    them. Navidrome's docs endorse this split explicitly.
  #  - /healthz is a caddy-local 200 for gatus, which probes sessionless
  forwardAuth = ''
    request_header -Remote-User
    forward_auth 127.0.0.1:9091 {
      uri /api/authz/forward-auth
      copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
  '';
  toNavidrome = ''
    reverse_proxy localhost:4533 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      header_up X-Forwarded-For {remote_host}
      header_up X-Forwarded-Proto {scheme}
    }
  '';
  navidromeBlock = ''
    route /healthz {
      respond "ok" 200
    }
    route /share/* {
      request_header -Remote-User
      ${toNavidrome}
    }
    route /rest/* {
      request_header -Remote-User
      ${toNavidrome}
    }
    route {
      ${forwardAuth}
      ${toNavidrome}
    }
  '';
in {
  flake = {
    caddyVirtualHosts = {
      "music.int.kuipr.de" = {
        extraConfig = navidromeBlock;
        name = "Navidrome";
      };
      "music.ext.kuipr.de" = {
        extraConfig = navidromeBlock;
        name = "Navidrome (ext)";
      };
    };

    gatusEndpoints = [
      {
        name = "Navidrome";
        group = "Music";
        # /healthz bypasses forward auth (see music vhost above); a bare probe
        # would get a 302 from authelia and fail [STATUS] == 200.
        url = "https://music.ext.kuipr.de/healthz";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];
  };
}
