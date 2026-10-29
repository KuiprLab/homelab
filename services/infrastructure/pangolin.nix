{
  lib,
  config,
  ...
}: let
  orgId = "kuiprde";
  orgName = "kuipr.de";
  orgSubnet = "100.90.128.0/20";
  orgUtilitySubnet = "100.96.128.0/20";
  apiUrl = "http://127.0.0.1:3000/api/v1";
  dashboardDomain = "pangolin.ext.kuipr.de";
  baseDomain = "kuipr.de";
  oidcIssuer = "https://auth.ext.kuipr.de";
  # niceId is also the newt --id; secretEnv names the variable in secrets/eclair/pangolin-apply.env.
  sites = {
    eclair = {
      niceId = "eclair";
      secretEnv = "NEWT_SECRET_ECLAIR";
    };
    sorbet = {
      niceId = "sorbet";
      secretEnv = "NEWT_SECRET_SORBET";
    };
  };
in {
  options.flake = {
    pangolinVirtualHosts = lib.mkOption {
      description = ''
        Declarative Pangolin proxy resources. Each entry declares one resource
        served through the pangolin tunnel network. Attribute names become the
        blueprint niceIds (the key blueprint application upserts on), so treat
        them as stable identifiers.

        Apply happens without any eclair-side code: the nixosModules.newt /
        eclairNixosModules.newt definitions below turn matching entries into
        services.newt.blueprint attrsets, which the nixpkgs newt module renders
        to a blueprint.yml. Newt watches that file and pushes the blueprint to
        pangolin over its websocket (source NEWT) whenever it changes.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          site = lib.mkOption {
            type = lib.types.str;
            description = "Pangolin site (newt) this resource belongs to.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            description = "Human readable resource name.";
          };
          subdomain = lib.mkOption {
            type = lib.types.str;
            description = "Full domain to route through pangolin (e.g. paperless.int.kuipr.de).";
          };
          private = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              true  -> int service: served by caddy on sorbet
                       (services/caddy.nix), reached through the wildcard
                       flake.pangolinHostResources route and, on the LAN,
                       directly. `site` must be "sorbet" unless `extra.mode`
                       is set.
              false -> public proxy-resource routed by pangolin's traefik.
              Either way, an explicit `extra.mode` (ssh, exit-node) makes it a
              pangolin client-resource instead of a caddy vhost.
            '';
          };
          protocol = lib.mkOption {
            type = lib.types.enum ["http" "https"];
            default = "http";
            description = "Scheme used for the connection from the tunnel endpoint to the backend.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "Backend port on the site's host.";
          };
          hostname = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Backend host as seen from the site's newt.";
          };
          healthcheck = lib.mkOption {
            type = lib.types.submodule {
              options = {
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                };
                interval = lib.mkOption {
                  type = lib.types.int;
                  default = 30;
                  description = "Seconds between successful health probes.";
                };
                "unhealthy-interval" = lib.mkOption {
                  type = lib.types.int;
                  default = 30;
                  description = "Seconds between failed health probes.";
                };
              };
            };
            description = "Per-target health check passed to pangolin.";
          };
          extra = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            default = {};
            description = "Escape hatch: merged into the blueprint resource entry verbatim.";
          };
        };
      });
      default = {};
    };

    pangolinExitNodes = lib.mkOption {
      description = ''
        Declarative Pangolin exit-node client-resources (full-tunnel mode):
        outlines one resource per attribute; its site's newt creates it in the
        blueprint, giving authorized pangolin clients a wireguard peer that
        routes their entire traffic through the site. Replaces tailscale's
        subnet-router role. Toggle per-client in the pangolin client app.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          site = lib.mkOption {
            type = lib.types.str;
            description = "Pangolin site whose network the client tunnels into.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            description = "Human readable resource name.";
          };
          users = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Pangolin user emails allowed to use this exit node.";
          };
          roles = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Pangolin role ids allowed to use this exit node.";
          };
          extra = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            default = {};
            description = "Escape hatch: merged into the blueprint resource entry verbatim.";
          };
        };
      });
      default = {};
    };

    pangolinHostResources = lib.mkOption {
      description = ''
        Declarative Pangolin host client-resources: one single-host route per
        attribute, optionally carrying a (wildcard) alias. Used to funnel a
        whole hostname range into one LAN TLS edge instead of enumerating a
        pangolin resource per service. Aliases support wildcards but CIDRs do
        not, so a wildcard alias must sit on a host resource
        (PrivateResourceSchema, mode "host").
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          site = lib.mkOption {
            type = lib.types.str;
            description = "Pangolin site whose newt applies the resource.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            description = "Human readable resource name.";
          };
          destination = lib.mkOption {
            type = lib.types.str;
            description = ''
              Single IP or FQDN as seen from the site. 127.0.0.1 means the site
              host itself (requires an alias, since loopback on the client
              would mean the client's own machine).
            '';
          };
          alias = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              FQDN handed out to clients through pangolin's DNS. Wildcards
              allowed (e.g. *.int.kuipr.de); never matches the apex itself.
            '';
          };
          tcpPorts = lib.mkOption {
            type = lib.types.str;
            default = "443";
            description = ''
              Allowed TCP ports: "443", "80,443,8000-9000" or "*" for all.
              Empty string allows none.
            '';
          };
          udpPorts = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Allowed UDP ports, same syntax as tcpPorts.";
          };
          icmp = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Allow ICMP to the destination.";
          };
          extra = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            default = {};
            description = "Escape hatch: merged into the blueprint resource entry verbatim.";
          };
        };
      });
      default = {};
    };

    pangolinGeoAllow = lib.mkOption {
      description = ''
        Country allow-list (ISO 3166-1 alpha-2) enforced on every public
        (traefik) resource through blueprint resource rules: listed countries
        get a `pass` rule (normal auth checks continue), everything else hits a
        final catch-all `deny`. Local, private and CGNAT sources are exempt in
        the engine itself, so LAN hairpin traffic is never blocked.

        Rules are only emitted when server.maxmind_db_path exists (see
        services/infrastructure/geoip-db.nix). Set to [] to disable, or
        override per resource via `extra.rules`.
      '';
      type = lib.types.listOf lib.types.str;
      default = [
        "AT"
        "BE"
        "BG"
        "HR"
        "CY"
        "CZ"
        "DK"
        "EE"
        "FI"
        "FR"
        "DE"
        "GR"
        "HU"
        "IE"
        "IT"
        "LV"
        "LT"
        "LU"
        "MT"
        "NL"
        "PL"
        "PT"
        "RO"
        "SK"
        "SI"
        "ES"
        "SE"
      ];
    };

    pangolinAsnDeny = lib.mkOption {
      description = ''
        ASN deny-list enforced on every public (traefik) resource through
        blueprint resource rules: one `deny` rule per ASN, evaluated ahead of
        the country catch-all. Blocking is exact — the engine compares the
        looked-up ASN to one value, so there is no wildcard. Hosting, cloud and
        VPN providers live here: they are never residential clients, and
        scanners/credential stuffers run from them. Local, private and CGNAT
        sources are unaffected.

        Requires server.maxmind_asn_path (see
        services/infrastructure/geoip-db.nix). Set to [] to disable, or
        override per resource via `extra.rules`. Clients that browse through a
        commercial VPN match these ASNs and lose access to public resources;
        the dashboard is not a blueprint resource and stays reachable.
      '';
      type = lib.types.listOf lib.types.ints.positive;
      default = [
        9009 # M247 Europe — VPN/anti-detect hosting
        60068 # Datacamp (CDN77)
        136787 # PacketHub (NordVPN)
        212238 # Datacamp (NordVPN/ExpressVPN ranges)
        62240 # Clouvider — VPN-friendly hosting
        210644 # AEZA — bulletproof hosting
        197068 # HLL (Qrator) — abuse host
        14061 # DigitalOcean
        63949 # Akamai (Linode)
        20473 # The Constant Company (Vultr)
        51167 # Contabo
        12876 # Scaleway
        16276 # OVH
        24940 # Hetzner
      ];
    };

    pangolinServer = lib.mkOption {
      description = ''
        Server-side identifiers that otherwise only exist in pangolin's
        database. Consumed by apps/pangolin-apply, which creates the org, the
        sites and the IdP registration idempotently.
      '';
      type = lib.types.submodule {
        options = {
          apiUrl = lib.mkOption {
            type = lib.types.str;
            description = "Pangolin API base URL, reachable from eclair itself.";
          };
          orgId = lib.mkOption {
            type = lib.types.str;
            description = "Pangolin org id: the URL segment and database key.";
          };
          orgName = lib.mkOption {
            type = lib.types.str;
            description = "Human readable org name.";
          };
          orgSubnet = lib.mkOption {
            type = lib.types.str;
            description = "Tunnel subnet handed to the org (pangolin's default range).";
          };
          orgUtilitySubnet = lib.mkOption {
            type = lib.types.str;
            description = "Utility subnet handed to the org (pangolin's default range).";
          };
          dashboardDomain = lib.mkOption {
            type = lib.types.str;
            description = "Domain the dashboard and API are served on.";
          };
          oidcIssuer = lib.mkOption {
            type = lib.types.str;
            description = "Authelia base URL used as the OIDC issuer.";
          };
          sites = lib.mkOption {
            description = "Pangolin tunnel sites, one newt each.";
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                niceId = lib.mkOption {
                  type = lib.types.str;
                  description = "Site niceId, which is also the newt --id.";
                };
                secretEnv = lib.mkOption {
                  type = lib.types.str;
                  description = "Variable in secrets/eclair/pangolin-apply.env holding the newt secret.";
                };
              };
            });
          };
        };
      };
    };
  };

  config.flake = let
    vhosts = config.flake.pangolinVirtualHosts;
    hostRoutes = config.flake.pangolinHostResources;
    exitNodes = config.flake.pangolinExitNodes;

    forSite = site: lib.filterAttrs (_nick: v: v.site == site) vhosts;

    # Priorities must be unique; 1000 leaves room for hand-written rules.
    geoRules =
      lib.imap0 (i: cc: {
        action = "pass";
        match = "country";
        value = cc;
        priority = i + 1;
      })
      config.flake.pangolinGeoAllow
      ++ lib.optional (config.flake.pangolinGeoAllow != []) {
        action = "deny";
        match = "country";
        value = "ALL";
        priority = 1000;
      };

    # One rule per ASN: the engine matches a single value, there is no wildcard.
    asnRules =
      lib.imap0 (i: asn: {
        action = "deny";
        match = "asn";
        value = "AS${toString asn}";
        priority = 500 + i;
      })
      config.flake.pangolinAsnDeny;

    labelsFor = edge: site: ["edge:${edge}" "site:${site}"];

    healthcheckFor = {
      hostname,
      port,
      protocol,
      hc,
    }: {
      enabled = true;
      inherit hostname;
      inherit port;
      scheme = protocol;
      inherit (hc) path;
      mode = "http";
      method = "GET";
      inherit (hc) interval;
      "unhealthy-interval" = hc."unhealthy-interval";
      "follow-redirects" = true;
    };

    hostResourcesFor = site:
      lib.mapAttrs (_nick: r:
        {
          inherit (r) name;
          mode = "host";
          inherit (r) destination;
          "tcp-ports" = r.tcpPorts;
          "udp-ports" = r.udpPorts;
          "disable-icmp" = !r.icmp;
          labels = labelsFor "int" r.site;
        }
        // lib.optionalAttrs (r.alias != null) {inherit (r) alias;}
        // r.extra)
      (lib.filterAttrs (_: r: r.site == site) hostRoutes);

    # Plain private vhosts are served by caddy on sorbet; only explicit modes are real client-resources.
    clientResources = site:
      lib.mapAttrs (_nick: vh:
        lib.recursiveUpdate
        {
          inherit (vh) name;
          mode = "http";
          destination = vh.hostname;
          "destination-port" = vh.port;
          scheme = vh.protocol;
          "full-domain" = vh.subdomain;
          labels = labelsFor "int" vh.site;
        }
        vh.extra)
      (lib.filterAttrs (_: vh: vh.private && vh.extra ? mode) (forSite site))
      // hostResourcesFor site;

    proxyResources = site:
      lib.mapAttrs (_nick: vh:
        lib.recursiveUpdate
        ({
            inherit (vh) name;
            mode = "http";
            "full-domain" = vh.subdomain;
            labels = labelsFor "public" vh.site;
            targets = [
              ({
                  inherit (vh) hostname;
                  inherit (vh) port;
                  healthcheck = healthcheckFor {
                    inherit (vh) hostname;
                    inherit (vh) port;
                    inherit (vh) protocol;
                    hc = vh.healthcheck;
                  };
                }
                // lib.optionalAttrs (vh.protocol != null) {
                  method = vh.protocol;
                })
            ];
          }
          // lib.optionalAttrs (asnRules != [] || geoRules != []) {
            rules = asnRules ++ geoRules;
          })
        vh.extra)
      (lib.filterAttrs (_: vh: !vh.private) (forSite site));

    exitNodeResources = site:
      lib.mapAttrs (_nick: en:
        {
          inherit (en) name;
          mode = "exit-node";
          sites = [site];
          inherit (en) users;
          roles = en.roles or [];
          labels = labelsFor "exit" site;
        }
        // (en.extra or {}))
      (lib.filterAttrs (_: en: en.site == site) exitNodes);
  in {
    pangolinServer = {
      inherit
        apiUrl
        orgId
        orgName
        orgSubnet
        orgUtilitySubnet
        dashboardDomain
        oidcIssuer
        sites
        ;
    };

    eclairNixosModules.pangolin-server = {
      config,
      pkgs,
      ...
    }: let
      configDir = "/var/lib/pangolin/config";
      lapiKeyFile = "/var/lib/pangolin/crowdsec-lapi-key";

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
              crowdsecLapiHost = "10.88.0.1:9090";
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
      sops.secrets."pangolin" = {
        sopsFile = ../../secrets/eclair/pangolin.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      imports = [
        {
          boot.kernelModules = ["wireguard"];

          networking.firewall.allowedUDPPorts = [51820];

          systemd = {
            services = {
              "podman-pangolin".serviceConfig.EnvironmentFile = config.sops.secrets."pangolin".path;
              "podman-traefik" = {
                after = ["crowdsec-traefik-bouncer.service"];
                wants = ["crowdsec-traefik-bouncer.service"];
                serviceConfig.EnvironmentFile = config.sops.secrets."pangolin".path;
              };

              # The key file is the source of truth: cscli keeps no copy of an issued key.
              crowdsec-traefik-bouncer = {
                description = "Register the CrowdSec bouncer that pangolin's traefik uses";
                wantedBy = ["multi-user.target"];
                after = ["crowdsec.service"];
                wants = ["crowdsec.service"];
                path = [
                  config.services.crowdsec.package
                  pkgs.openssl
                  pkgs.systemd
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  set -eu

                  if [ -s ${lapiKeyFile} ]; then
                    if cscli bouncers inspect traefik-bouncer >/dev/null 2>&1; then
                      exit 0
                    fi
                    # Re-add with the stored key, or a running traefik is left holding a dead one.
                    cscli bouncers add traefik-bouncer --key "$(cat ${lapiKeyFile})" >/dev/null
                    exit 0
                  fi

                  key=$(openssl rand -hex 32)
                  cscli bouncers delete traefik-bouncer >/dev/null 2>&1 || true
                  cscli bouncers add traefik-bouncer --key "$key" >/dev/null
                  printf '%s' "$key" > ${lapiKeyFile}
                  chmod 0400 ${lapiKeyFile}

                  if systemctl is-active --quiet podman-traefik.service; then
                    systemctl --no-block restart podman-traefik.service
                  fi
                '';
              };
            };

            tmpfiles.settings."10-pangolin-paths" = {
              "/var/lib/pangolin".d = {
                user = "root";
                group = "root";
                mode = "0750";
              };
              "${configDir}".d = {
                user = "root";
                group = "root";
                mode = "0750";
              };
              "${configDir}/db".d = {
                user = "root";
                group = "root";
                mode = "0750";
              };
              "${configDir}/letsencrypt".d = {
                user = "root";
                group = "root";
                mode = "0700";
              };
              # Must exist before the container starts, or podman creates a directory here.
              "${lapiKeyFile}".f = {
                user = "root";
                group = "root";
                mode = "0400";
              };
            };
          };

          virtualisation = {
            containers.enable = true;

            podman = {
              enable = true;
              extraPackages = [pkgs.podman-compose];
              dockerCompat = true;
              dockerSocket.enable = true;
              defaultNetwork.settings = {
                ipv6_enabled = true;
                dns_enabled = true;
              };
              autoPrune = {
                enable = true;
                dates = "weekly";
                flags = ["--all"];
              };
            };

            oci-containers = {
              backend = "podman";
              containers = {
                pangolin = {
                  image = "docker.io/fosrl/pangolin:ee-1.25.3@sha256:f2c0fc54e1b59efcd23b8685e8df84350f363e14ebe1c13ce88a681f181ca49e";
                  volumes = [
                    "${configDir}:/app/config"
                    "${configFile}:/app/config/config.yml:ro"
                    "/var/lib/geoip:/var/lib/geoip:ro"
                  ];
                  ports = ["127.0.0.1:3000:3000"];
                  extraOptions = [
                    "--env-host"
                    "--env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                    "--env=ENABLE_SQLITE_WAL_MODE=true"
                    "--memory-reservation=450m"
                  ];
                  log-driver = "journald";
                };
                gerbil = {
                  image = "docker.io/fosrl/gerbil:1.5.2@sha256:1f6e64eaba7997282c7067ba19922fc7e46b5f73e1a27add3dd66a591d50512f";
                  volumes = ["${configDir}:/var/config"];
                  ports = [
                    "80:80"
                    "443:443"
                    "51820:51820/udp"
                    "21820:21820/udp"
                  ];
                  cmd = [
                    "--reachableAt=http://gerbil:3004"
                    "--generateAndSaveKeyTo=/var/config/key"
                    "--remoteConfig=http://pangolin:3001/api/v1/"
                  ];
                  extraOptions = ["--cap-add=NET_ADMIN" "--cap-add=SYS_MODULE"];
                  dependsOn = ["pangolin"];
                  log-driver = "journald";
                };
                traefik = {
                  image = "docker.io/library/traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65";
                  volumes = [
                    "${traefikStatic}:/etc/traefik/traefik_config.yml:ro"
                    "${traefikDynamic}:/etc/traefik/dynamic_config.yml:ro"
                    "${configDir}/letsencrypt:/letsencrypt"
                    "${banPage}:/etc/traefik/ban.html:ro"
                    "${lapiKeyFile}:/etc/traefik/lapi-key:ro"
                  ];
                  cmd = ["--configFile=/etc/traefik/traefik_config.yml"];
                  extraOptions = ["--network=container:gerbil" "--env=BUNNY_API_KEY"];
                  dependsOn = ["pangolin" "gerbil"];
                  log-driver = "journald";
                };
              };
            };
          };
        }
      ];
    };

    eclairNixosModules.newt = {
      config,
      pkgs,
      ...
    }: let
      blueprint = (pkgs.formats.yaml {}).generate "blueprint-eclair.yml" {
        client-resources = (clientResources "eclair") // (exitNodeResources "eclair");
        proxy-resources = proxyResources "eclair";
      };
    in {
      sops.secrets."newt-eclair" = {
        sopsFile = ../../secrets/eclair/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      systemd.services."podman-newt".serviceConfig.EnvironmentFile = config.sops.secrets."newt-eclair".path;

      virtualisation.oci-containers.containers.newt = {
        image = "docker.io/fosrl/newt:1.19.1@sha256:c89f01cb387bf6c598959036cbf56306b068a43e8784345bee7398b7af8ee2e1";
        volumes = ["${blueprint}:/blueprint.yml:ro"];
        cmd = [
          "--endpoint=https://pangolin.ext.kuipr.de"
          "--id=eclair"
          "--blueprint-file=/blueprint.yml"
        ];
        extraOptions = [
          "--network=host"
          "--env-host"
          "--env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ];
        log-driver = "journald";
      };
    };

    nixosModules.newt = {
      config,
      pkgs,
      ...
    }: let
      blueprint = (pkgs.formats.yaml {}).generate "blueprint-sorbet.yml" {
        client-resources = (clientResources "sorbet") // (exitNodeResources "sorbet");
        proxy-resources = proxyResources "sorbet";
      };
    in {
      sops.secrets."newt-sorbet" = {
        sopsFile = ../../secrets/sorbet/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      systemd.services."podman-newt".serviceConfig.EnvironmentFile = config.sops.secrets."newt-sorbet".path;

      virtualisation.oci-containers.containers.newt = {
        image = "docker.io/fosrl/newt:1.19.1@sha256:c89f01cb387bf6c598959036cbf56306b068a43e8784345bee7398b7af8ee2e1";
        volumes = ["${blueprint}:/blueprint.yml:ro"];
        cmd = [
          "--endpoint=https://pangolin.ext.kuipr.de"
          "--id=sorbet"
          "--blueprint-file=/blueprint.yml"
        ];
        extraOptions = [
          "--network=host"
          "--env-host"
          "--env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ];
        log-driver = "journald";
      };
    };
  };
}
