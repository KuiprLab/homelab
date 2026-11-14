{
  pkgs,
  baseDomain,
  dashboardDomain,
  podmanBridgeGateway,
  tolerance,
}: let
  banPage = pkgs.writeText "ban.html" ''
    <!doctype html>
    <meta charset="utf-8">
    <title>Access denied</title>
    <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#eee;font:16px/1.6 system-ui,sans-serif}main{max-width:32rem;padding:2rem;text-align:center}h1{font-size:1.5rem;font-weight:600}</style>
    <main>
      <h1>Access denied</h1>
      <p>Your address is blocked at the edge after automated behaviour analysis.</p>
      <p>The block expires automatically.</p>
    </main>
  '';

  yaml = pkgs.formats.yaml {};

  configFile = yaml.generate "config.yml" {
    app.dashboard_url = "https://${dashboardDomain}";
    domains.domain1 = {
      base_domain = baseDomain;
      prefer_wildcard_cert = true;
    };
    server = {
      external_port = 3000;
      internal_port = 3001;
      next_port = 3002;
      integration_port = 3003;
      internal_hostname = "pangolin";
      maxmind_db_path = "/var/lib/geoip/dbip-country-lite.mmdb";
      maxmind_asn_path = "/var/lib/geoip/dbip-asn-lite.mmdb";
    };
    gerbil.base_endpoint = dashboardDomain;
    offline_checker.newt_threshold_ms = tolerance * 1000;
    flags = {
      disable_signup_without_invite = true;
      enable_integration_api = false;
      allow_raw_resources = false;
    };
  };

  traefikStatic = yaml.generate "traefik_config.yml" {
    providers = {
      http = {
        endpoint = "http://pangolin:3001/api/v1/traefik-config";
        pollInterval = "5s";
      };
      file.filename = "/etc/traefik/dynamic_config.yml";
    };
    experimental.plugins = {
      badger = {
        moduleName = "github.com/fosrl/badger";
        version = "v1.7.0";
      };
      crowdsec = {
        moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin";
        version = "v1.8.1";
      };
    };
    accessLog = {};
    certificatesResolvers.letsencrypt.acme = {
      dnsChallenge.provider = "bunny";
      email = "62436912+frostplexx@users.noreply.github.com";
      storage = "/letsencrypt/acme.json";
      caServer = "https://acme-v02.api.letsencrypt.org/directory";
    };
    entryPoints = {
      web.address = ":80";
      websecure = {
        address = ":443";
        transport.respondingTimeouts.readTimeout = "30m";
        http = {
          tls.certResolver = "letsencrypt";
          middlewares = ["crowdsec@file" "sec-headers@file"];
          encodedCharacters = {
            allowEncodedSlash = true;
            allowEncodedQuestionMark = true;
          };
        };
      };
    };
    serversTransport.insecureSkipVerify = true;
  };

  traefikDynamic = yaml.generate "dynamic_config.yml" {
    http = {
      middlewares = {
        redirect-to-https.redirectScheme.scheme = "https";
        # traefik shares gerbil's netns, so it reaches the LAPI over the podman bridge.
        crowdsec.plugin.crowdsec = {
          enabled = true;
          logLevel = "INFO";
          crowdsecMode = "live";
          crowdsecLapiScheme = "http";
          crowdsecLapiHost = "${podmanBridgeGateway}:9090";
          crowdsecLapiKeyFile = "/etc/traefik/lapi-key";
          updateIntervalSeconds = 15;
          # -1 in live mode lets a request through when the LAPI is unreachable or rejects
          # the key, so a CrowdSec outage cannot take the public edge down with it.
          updateMaxFailure = -1;
          defaultDecisionSeconds = 15;
          httpTimeoutSeconds = 10;
          banHTMLFilePath = "/etc/traefik/ban.html";
        };
        sec-headers.headers = {
          stsSeconds = 31536000;
          stsIncludeSubdomains = true;
          contentTypeNosniff = true;
          referrerPolicy = "strict-origin-when-cross-origin";
          customFrameOptionsValue = "DENY";
        };
      };
      routers = {
        main-app-router-redirect = {
          rule = "Host(`${dashboardDomain}`)";
          service = "next-service";
          entryPoints = ["web"];
          middlewares = ["redirect-to-https"];
        };
        next-router = {
          rule = "Host(`${dashboardDomain}`) && !PathPrefix(`/api/v1`)";
          service = "next-service";
          entryPoints = ["websecure"];
          tls = {
            domains = [
              {main = baseDomain;}
              {sans = "*.${baseDomain}";}
            ];
            certResolver = "letsencrypt";
          };
        };
        api-router = {
          rule = "Host(`${dashboardDomain}`) && PathPrefix(`/api/v1`)";
          service = "api-service";
          entryPoints = ["websecure"];
          tls.certResolver = "letsencrypt";
        };
        ws-router = {
          rule = "Host(`${dashboardDomain}`)";
          service = "api-service";
          entryPoints = ["websecure"];
          tls.certResolver = "letsencrypt";
        };
      };
      services = {
        next-service.loadBalancer.servers = [{url = "http://pangolin:3002";}];
        api-service.loadBalancer.servers = [{url = "http://pangolin:3000";}];
      };
    };
  };
in {
  inherit
    banPage
    configFile
    traefikStatic
    traefikDynamic
    ;
}
