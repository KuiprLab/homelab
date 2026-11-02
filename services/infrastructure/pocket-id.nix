_: let
  baseUrl = "http://127.0.0.1:1411";
  apiUrl = "${baseUrl}/api";
  dataDir = "/var/lib/pocket-id";

  # Beszel derives the redirect from window.location.origin, and the hub answers on both names.
  clients = {
    beszel = {
      name = "Beszel";
      launchURL = "https://monitoring.ext.kuipr.de";
      callbackURLs = [
        "https://mon.int.kuipr.de/api/oauth2-redirect"
        "https://monitoring.ext.kuipr.de/api/oauth2-redirect"
      ];
      secretEnv = "BESZEL_CLIENT_SECRET";
    };
  };

  # Pinned id: Pocket ID generates ids, and the reconciler must stay stateless.
  users = [
    {
      id = "0270e7ff-3293-42a0-bd06-0d9b07680e16";
      username = "daniel";
      firstName = "Daniel";
      displayName = "Daniel";
      isAdmin = true;
    }
  ];
in {
  flake.pangolinVirtualHosts."pocketId" = {
    site = "sorbet";
    name = "Pocket ID";
    subdomain = "id.ext.kuipr.de";
    port = 1411;
    private = false;
  };

  flake.nixosModules.pocketId = {
    config,
    lib,
    ...
  }: {
    imports = [
      (import ../../apps/pocket-id-converge/_module.nix {
        inherit apiUrl baseUrl clients users;
        appUrl = "https://id.ext.kuipr.de";
      })
    ];

    sops.secrets."pocket-id/env" = {
      sopsFile = ../../secrets/sorbet/pocket-id.env;
      format = "dotenv";
      key = "";
      owner = "root";
      mode = "0400";
      restartUnits = ["podman-pocket-id.service"];
    };

    systemd.tmpfiles.rules = ["d ${dataDir} 0700 1000 1000 - -"];

    virtualisation.oci-containers.containers.pocket-id = {
      image = "ghcr.io/pocket-id/pocket-id:v2.19.1@sha256:f085157f0b6ea4b2e8aa5ecfd99eada0d83a4960f3a3dcfd46014097d0ef7ab5";
      volumes = ["${dataDir}:/app/data"];
      ports = ["127.0.0.1:1411:1411"];
      environment = {
        APP_URL = "https://id.ext.kuipr.de";
        APP_NAME = "kuipr";
        # No SMTP is configured, so an address would only block user creation.
        REQUIRE_USER_EMAIL = "false";
        # Settings come from this file's env; the admin UI shows them read-only.
        UI_CONFIG_DISABLED = "true";
        SESSION_DURATION = "1440";
        # Pinned now, so the v3 default flip cannot break the internal http clients later.
        ALLOW_INSECURE_CALLBACK_URLS = "false";
        TRUST_PROXY = "10.88.0.1/32";
        ANALYTICS_DISABLED = "true";
        VERSION_CHECK_DISABLED = "true";
        ICON_LIBRARY_URL = "disabled";
        # Converge owns client secrets; a generated one would outrank the sops value.
        AUTO_CREATE_OIDC_CLIENT_SECRET = "false";
      };
      environmentFiles = [config.sops.secrets."pocket-id/env".path];
      log-driver = "journald";
      extraOptions = [
        # The v3 image is distroless: drop the sh wrapper and keep only podman's retries.
        "--health-cmd=sh -c 'n=0; until /app/pocket-id healthcheck; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'"
        "--health-interval=30s"
        "--health-on-failure=kill"
        "--health-retries=3"
        "--health-start-period=1m"
        "--health-timeout=30s"
      ];
    };

    systemd.services."podman-pocket-id".serviceConfig.Restart = lib.mkOverride 90 "always";
  };
}
