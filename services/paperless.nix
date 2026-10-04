_: {
  flake = {
    caddyVirtualHosts = {
      "paperless.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:28981
        '';
        name = "Paperless";
        authelia = {
          enable = true;
          # gatus probes this vhost sessionless; /healthz bypasses forward auth.
          bypassPaths = ["/healthz"];
        };
      };
    };

    gatusEndpoints = [
      {
        name = "Paperless";
        group = "Home";
        url = "https://paperless.int.kuipr.de/healthz";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.paperless = {config, ...}: {
      # OIDC client secret for Authelia. The allauth provider config has no
      # env-var indirection for the secret, so the whole
      # PAPERLESS_SOCIALACCOUNT_PROVIDERS JSON (single line, quotes
      # systemd-escaped) lives in this sops file.
      sops.secrets."paperless/oidc" = {
        sopsFile = ../secrets/sorbet/paperless-oidc;
        format = "binary";
        key = "";
      };

      services.paperless = {
        enable = true;
        consumptionDir = "/var/lib/paperless/media";
        mediaDir = "/media/data/data/Paperless-data"; # Where to store the documents
        domain = "paperless.int.kuipr.de"; # The domain to use for the Paperless web interface
        dataDir = "/var/lib/paperless"; # Where to store the database and other state
        environmentFile = config.sops.secrets."paperless/oidc".path;
        configureTika = true; # Whether to configure Tika and Gotenberg to process Office and e-mail files with OCR.
        settings = {
          PAPERLESS_OCR_LANGUAGE = "deu+eng"; # Languages to use for OCR (Tesseract)
          PAPERLESS_TIME_ZONE = "Europe/Berlin"; # Time zone for the Paperless web interface
          PAPERLESS_PAGINATION = "50"; # Number of documents per page in the web interface
          PAPERLESS_PAGINATION_MAX = "100"; # Maximum number of documents per page in the web interface
          PAPERLESS_PAGINATION_MIN = "10"; # Minimum number of documents per page in the web interface
          PAPERLESS_TIKA_ENABLED = true; # Whether to enable Tika for processing Office and e-mail files
          PAPERLESS_URL = "https://paperless.int.kuipr.de"; # The URL to use for the Paperless web interface
          PAPERLESS_LOGOUT_REDIRECT_URL = "https://auth.ext.kuipr.de/logout";
          PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
          PAPERLESS_ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https";
          PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = "none"; # no mail server
          PAPERLESS_SOCIAL_AUTO_SIGNUP = true; # auto-create account on first login
        };
      };
    };
  };
}
