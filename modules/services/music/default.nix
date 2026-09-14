# Music services flake-parts module
# Caddy virtual hosts and Gatus endpoints for music services.
# NixOS config is split across sibling *.nix files, each a standalone flake-parts module.
_: let
  # Navidrome "Externalized Authentication":
  #  - always strip any client-supplied Remote-User (trust only authelia)
  #  - forward_auth the web app
  #  - /share/* keeps its own auth so share links work without a session
  #  - /rest/* also sits behind forward_auth: authelia authenticates subsonic
  #    clients via BasicAuth (the subsonic u/t/s scheme is meaningless to
  #    authelia) and hands over Remote-User, so third-party apps get SSO too
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
      forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        @error status 1xx 3xx 4xx 5xx
        handle_response @error {
          respond <<SUBSONICERR
            <subsonic-response xmlns="http://subsonic.org/restapi" status="failed" version="1.16.1" type="proxy-auth" serverVersion="n/a" openSubsonic="true">
              <error code="40" message="Invalid credentials or unsupported client"></error>
            </subsonic-response>
            SUBSONICERR 200
        }
      }
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
      "musai.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:8000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        '';
        authelia = {
          enable = true;
          # gatus probes this vhost sessionless; /healthz bypasses forward auth.
          bypassPaths = ["/healthz"];
        };
        name = "Audiomuse AI";
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
