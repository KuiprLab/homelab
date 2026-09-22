# Octo-Fiesta — Subsonic proxy in front of Navidrome that fills gaps from Tidal.
# https://github.com/V1ck3s/octo-fiesta
#
# Subsonic clients point here instead of at Navidrome; anything missing from the
# local library is searched on Tidal, fetched, and streamed. Runs in Cache mode
# so Tidal tracks are held in a temp store and never written into the Navidrome
# library, which stays purchased-only.
#
# Tidal auth is an OAuth device flow, so there is no token to put in sops. Log
# in once on sorbet and the tokens land in the mounted token store:
#   sudo podman run --rm -it -v /var/lib/octo-fiesta/config:/config \
#     ghcr.io/v1ck3s/octo-fiesta:latest --tidal-login
_: let
  port = 5274;
  toOctoFiesta = ''
    reverse_proxy localhost:${toString port}
  '';
in {
  flake = {
    caddyVirtualHosts = {
      "octo.int.kuipr.de" = {
        extraConfig = toOctoFiesta;
        name = "Octo-Fiesta";
      };
      "octo.ext.kuipr.de" = {
        extraConfig = toOctoFiesta;
        name = "Octo-Fiesta (ext)";
      };
    };

    gatusEndpoints = [
      {
        name = "Octo-Fiesta";
        group = "Music";
        # Subsonic ping is answered (HTTP 200, subsonic-level auth error)
        # without credentials, so it works as a sessionless probe.
        url = "https://octo.ext.kuipr.de/rest/ping.view";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.octo-fiesta = _: {
      systemd.tmpfiles.rules = [
        "d /var/lib/octo-fiesta 0755 root root - -"
        "d /var/lib/octo-fiesta/config 0755 root root - -"
        "d /var/lib/octo-fiesta/cache 0755 root root - -"
      ];

      virtualisation.oci-containers.containers.octo-fiesta = {
        image = "ghcr.io/v1ck3s/octo-fiesta:latest";
        volumes = [
          # Tidal token store; must persist or every recreate needs a new login
          "/var/lib/octo-fiesta/config:/config"
          # Cache-mode download store ($TMPDIR/octo-fiesta-cache)
          "/var/lib/octo-fiesta/cache:/cache"
        ];
        environment = {
          TZ = "Europe/Berlin";
          ASPNETCORE_ENVIRONMENT = "Production";
          # Host network: navidrome only listens on loopback, and 8080 is taken
          ASPNETCORE_URLS = "http://127.0.0.1:${toString port}";
          Subsonic__Url = "http://127.0.0.1:4533";
          Subsonic__MusicService = "Tidal";
          Subsonic__StorageMode = "Cache";
          Subsonic__CacheDurationHours = "168";
          Subsonic__EnableExternalPlaylists = "true";
          Subsonic__DownloadMode = "Track";
          # Nothing is registered in navidrome in Cache mode; skip the scan
          Subsonic__DisableLibraryScan = "true";
          Tidal__TokenStore = "/config/tidal-tokens.json";
          # Highest the subscription allows when empty (HI_RES_LOSSLESS on HiFi Plus)
          Tidal__Quality = "";
          TMPDIR = "/cache";
        };
        extraOptions = ["--network=host"];
        labels = {
          "io.containers.autoupdate" = "registry";
        };
      };
    };
  };
}
