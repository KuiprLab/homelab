{
  lib,
  config,
  ...
}: let
  # Server-side identifiers that would otherwise only exist in the pangolin
  # database. Everything below is created once by pangolin-apply.service on
  # eclair (see below) and must match the values newts use to connect.
  # Rotating newt secrets is the only piece that needs a manual sops edit;
  # newt IDs are stable by design.
  orgId = "kuiprde";
  orgName = "kuipr.de";
  # Default ranges shipped by pangolin (pick-org-defaults endpoint).
  orgSubnet = "100.90.128.0/20";
  orgUtilitySubnet = "100.96.128.0/20";
  # blueprint niceIds: the attribute names of flake.pangolinVirtualHosts
  # become the resource niceIds on the pangolin server. NiceIds are the key
  # the blueprint upsert matches on, so renaming an attribute = new resource.
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
  };

  config.flake = let
    vhosts = config.flake.pangolinVirtualHosts;
    hostRoutes = config.flake.pangolinHostResources;
    exitNodes = config.flake.pangolinExitNodes;

    forSite = site: lib.filterAttrs (_nick: v: v.site == site) vhosts;

    # Country allow-list as blueprint resource rules: `pass` keeps the normal
    # auth flow for allowed countries, the trailing `deny` catches the rest.
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

    # ASN deny-list as blueprint resource rules. One rule per ASN: the engine
    # compares the looked-up ASN against a single value
    # (isIpInAsn in server/routers/badger/verifySession.ts), so there is no
    # wildcard. 500+ keeps these ahead of the country catch-all.
    asnRules =
      lib.imap0 (i: asn: {
        action = "deny";
        match = "asn";
        value = "AS${toString asn}";
        priority = 500 + i;
      })
      config.flake.pangolinAsnDeny;

    # Dashboard labels, so resources can be filtered/grouped in pangolin's UI.
    labelsFor = edge: site: ["edge:${edge}" "site:${site}"];

    # exit-node client-resources for a site: full-tunnel access for pangolin
    # clients (replaces a tailscale subnet router). Schema: mode "exit-node"
    # (server.mjs PrivateResourceSchema, alias of "gateway") — no destination
    # required, all TCP/UDP ports + ICMP always allowed; users are email
    # addresses, roles are org role ids. Admins always have access.

    # Shared rendering bits
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

    # host client-resources: raw L4 routes to one machine on the site's
    # network. The alias (wildcards allowed) is what clients resolve; the
    # wildcard route into caddy is the reason these exist.
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

    # > private: moderately-documented client-resources; applied through the
    # newt of the site listed in vh.site. Plain private vhosts are not
    # included: caddy on sorbet serves those (services/caddy.nix) and the
    # wildcard host resource above routes them. Only entries with an explicit
    # pangolin mode (ssh) remain real client-resources.
    clientResources = site:
      lib.mapAttrs (_nick: vh:
        lib.recursiveUpdate
        {
          inherit (vh) name;
          # client (site) resources in http mode: pangolin terminates TLS for
          # the full domain and forwards through the site's newt connection.
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
    eclairNixosModules.pangolin-server = {
      config,
      lib,
      pkgs,
      ...
    }: let
      dashboardDomain = "pangolin.ext.kuipr.de";
      baseDomain = "kuipr.de";
      configDir = "/var/lib/pangolin/config";

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
        experimental.plugins.badger = {
          moduleName = "github.com/fosrl/badger";
          version = "v1.7.0";
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
              middlewares = ["sec-headers@file"];
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

      # Admin credentials + one newt secret per site, used exclusively by
      # pangolin-apply.service to bootstrap org/sites. See gitops notes.
      sops.secrets."pangolin-apply" = {
        sopsFile = ../../secrets/eclair/pangolin-apply.env;
        format = "dotenv";
        key = "";
      };

      imports = [
        {
          boot.kernelModules = ["wireguard"];

          networking.firewall.allowedUDPPorts = [51820];

          systemd = {
            services."podman-pangolin".serviceConfig.EnvironmentFile = config.sops.secrets."pangolin".path;
            services."podman-traefik".serviceConfig.EnvironmentFile = config.sops.secrets."pangolin".path;
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
                  image = "docker.io/fosrl/pangolin:1.25.3@sha256:5039d0e64a2e57ac52c4833a838f8c015c153f8ab4234c2b3efe95ab4db0b90a";
                  volumes = [
                    "${configDir}:/app/config"
                    "${configFile}:/app/config/config.yml:ro"
                    "/var/lib/geoip:/var/lib/geoip:ro"
                  ];
                  ports = ["127.0.0.1:3000:3000"];
                  extraOptions = [
                    "--env-host"
                    "--env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                    # Upstream knob (dist/server.mjs): journal_mode=WAL plus
                    # synchronous=NORMAL. Without it the DB runs a rollback journal,
                    # so every session write creates and fsyncs one. journal_mode is
                    # stored in the DB header, so this survives restarts either way.
                    "--env=ENABLE_SQLITE_WAL_MODE=true"
                    # Memory soft limit = memory.low on the container cgroup, i.e. the
                    # Next.js bundles and the node heap stay resident while smaller
                    # neighbours get reclaimed. A systemd MemoryLow on the unit does
                    # nothing: podman puts the container in
                    # machine.slice/libpod-<id>.scope/container, not in the unit's
                    # cgroup. Measured with it: after 7 min idle RSS held at 206 MB and
                    # swap fell 119->97 MB, and dashboard requests 2 and 3 read 0 MB
                    # from disk (0.16 s instead of 0.58 s).
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
      # One-shot idempotent bootstrap after pangolin is up:
      #   1. ensure the org exists (create-if-missing, never BatchUpdate)
      #   2. ensure the sites exist, with our pinned newtId + fresh secret
      #   3. ensure the Authelia IdP is registered
      # Safely re-runs: everything it creates already returns real statuses
      # if it already exists. Secrets come from sops, and the admin password
      # is only ever used for a localhost login.
      systemd.services."pangolin-apply" = {
        description = "Pangolin org/site bootstrap (idempotent)";
        wantedBy = ["multi-user.target"];
        after = ["podman-pangolin.service"];
        requires = ["podman-pangolin.service"];
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "pangolin-apply";
          RuntimeDirectoryMode = "0700";
          EnvironmentFile = config.sops.secrets."pangolin-apply".path;
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "15s";
        };
        path = with pkgs; [curl jq];
        script = let
          api = "http://127.0.0.1:3000/api/v1";
          siteIds = {
            eclair = {
              niceId = "eclair";
              secretEnv = "NEWT_SECRET_ECLAIR";
            };
            sorbet = {
              niceId = "sorbet";
              secretEnv = "NEWT_SECRET_SORBET";
            };
          };
          # Authelia (services/infrastructure/authelia.nix) is the OIDC issuer.
          # Its `pangolin` client hardcodes the redirect URL, which embeds the
          # idpId assigned here (1 on a fresh DB).
          oidcIssuer = "https://auth.ext.kuipr.de";
          expectedRedirect = "https://pangolin.ext.kuipr.de/auth/idp/1/oidc/callback";
          ensureIdp = ''
            if curl -sf -b "$JAR" ${api}/idp \
                | jq -e --arg n "$PANGOLIN_IDP_NAME" \
                    '[.data.idps[]? | select(.name == $n)] | length > 0' >/dev/null; then
              echo "idp $PANGOLIN_IDP_NAME already registered"
            else
              echo "registering idp $PANGOLIN_IDP_NAME"
              created=$(curl -sf -b "$JAR" -X PUT ${api}/idp/oidc \
                -H 'Content-Type: application/json' \
                -H 'x-csrf-token: x-csrf-protection' \
                -d "$(jq -n \
                  --arg name "$PANGOLIN_IDP_NAME" \
                  --arg clientId "$PANGOLIN_IDP_CLIENT_ID" \
                  --arg clientSecret "$PANGOLIN_IDP_CLIENT_SECRET" \
                  '{name: $name, clientId: $clientId,
                    clientSecret: $clientSecret,
                    authUrl: "${oidcIssuer}/api/oidc/authorization",
                    tokenUrl: "${oidcIssuer}/api/oidc/token",
                    identifierPath: "sub",
                    emailPath: "email",
                    namePath: "name",
                    scopes: "openid profile email",
                    autoProvision: true,
                    variant: "oidc"}')")
              redirect=$(printf '%s' "$created" | jq -r '.data.redirectUrl')
              echo "registered idp $(printf '%s' "$created" | jq -r '.data.idpId'), redirect $redirect"
              if [ "$redirect" != "${expectedRedirect}" ]; then
                echo "WARNING: redirect $redirect != authelia redirect_uris ${expectedRedirect}" >&2
              fi
            fi
          '';
          ensureSite = _: v: ''
            code=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" \
              ${api}/org/${orgId}/site/${v.niceId} || true)
            if [ "$code" != "200" ]; then
              echo "creating site ${v.niceId}"
              curl -sf -b "$JAR" -X PUT ${api}/org/${orgId}/site \
                -H 'Content-Type: application/json' \
                -H 'x-csrf-token: x-csrf-protection' \
                -d "$(jq -n \
                  --arg name ${v.niceId} \
                  --arg niceId ${v.niceId} \
                  --arg newtId ${v.niceId} \
                  --arg secret "${"$"}${v.secretEnv}" \
                  '{name: $name, niceId: $niceId, newtId: $newtId,
                    secret: $secret, type: "newt"}')" >/dev/null
            fi
          '';
        in ''
          set -euo pipefail
          JAR=$(mktemp)
          trap 'rm -f "$JAR"' EXIT

          # Wait for the API to answer (pangolin boots before it is ready).
          for i in $(seq 1 60); do
            if curl -sf -o /dev/null ${api}/; then break; fi
            sleep 2
          done
          curl -sf -o /dev/null ${api}/ || {
            echo "pangolin API not reachable" >&2
            exit 1
          }

          echo "logging in as $PANGOLIN_ADMIN_EMAIL"
          curl -sf -c "$JAR" -X POST ${api}/auth/login \
            -H 'Content-Type: application/json' \
            -H 'x-csrf-token: x-csrf-protection' \
            -d "$(jq -n --arg e "$PANGOLIN_ADMIN_EMAIL" \
                     --arg p "$PANGOLIN_ADMIN_PASSWORD" \
                     '{email: $e, password: $p}')" >/dev/null

          code=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" \
            ${api}/org/${orgId} || true)
          if [ "$code" != "200" ]; then
            echo "creating org ${orgId}"
            curl -sf -b "$JAR" -X PUT ${api}/org \
              -H 'Content-Type: application/json' \
              -H 'x-csrf-token: x-csrf-protection' \
              -d "$(jq -n \
                --arg orgId ${orgId} \
                --arg name ${orgName} \
                --arg subnet ${orgSubnet} \
                --arg utilitySubnet ${orgUtilitySubnet} \
                '{orgId: $orgId, name: $name, subnet: $subnet,
                  utilitySubnet: $utilitySubnet}')" >/dev/null
          fi

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList ensureSite siteIds)}
          ${ensureIdp}
        '';
      };
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
