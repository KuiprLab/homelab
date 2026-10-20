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
      ++ [
        {
          action = "deny";
          match = "country";
          value = "ALL";
          priority = 1000;
        }
      ];

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
          // lib.optionalAttrs (config.flake.pangolinGeoAllow != []) {
            rules = geoRules;
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
      pkgs,
      ...
    }: {
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

      services.pangolin = {
        enable = true;
        # nixpkgs ships the wrapper with NODE_ENV=development, which breaks
        # prod SSR (renderToPipeableStream is not implemented -> 500).
        package = pkgs.fosrl-pangolin.override {
          environmentVariables = {NODE_ENV = "production";};
        };
        dashboardDomain = "pangolin.ext.kuipr.de";
        baseDomain = "kuipr.de";
        dnsProvider = "bunny";
        letsEncryptEmail = "62436912+frostplexx@users.noreply.github.com";
        environmentFile = config.sops.secrets."pangolin".path;
        openFirewall = true;
        settings = {
          # Certificates are wildcard entries (*.int.kuipr.de, *.ext.kuipr.de);
          # HTTP-01 cannot issue those, so request them via DNS-01 (bunny).
          domains.domain1.prefer_wildcard_cert = true;

          # GeoIP database for country rules (see flake.pangolinGeoAllow and
          # services/infrastructure/geoip-db.nix). Read at import time, so
          # geoip-db.service runs before pangolin.service.
          server.maxmind_db_path = "/var/lib/geoip/dbip-country-lite.mmdb";

          # Raw resources allow full domains outside baseDomain, bypassing the
          # wildcard certificate and the blueprint. Nothing here uses them.
          flags.allow_raw_resources = false;
        };
      };

      # Access log to stdout -> journald, where crowdsec's traefik parser picks
      # it up (services/infrastructure/crowdsec.nix). No file, no rotation, no
      # permissions for the agent's user to work around.
      #
      # sec-headers is attached to the websecure entrypoint instead of each
      # resource router: pangolin renders its routers from the database, so
      # there is no per-router hook to attach it to.
      services.traefik = {
        # traefik performs the DNS-01 challenge and therefore needs
        # BUNNY_API_KEY, which lives in the shared pangolin dotenv.
        environmentFiles = [config.sops.secrets."pangolin".path];
        staticConfigOptions = {
          accessLog = {};
          entryPoints.websecure.http.middlewares = ["sec-headers@file"];
        };
        dynamicConfigOptions.http.middlewares.sec-headers.headers = {
          stsSeconds = 31536000;
          stsIncludeSubdomains = true;
          contentTypeNosniff = true;
          referrerPolicy = "strict-origin-when-cross-origin";
          # Deny framing outright on the public edge: no public resource is
          # meant to be embedded, and clickjacking on the pangolin dashboard
          # or authelia login is the interesting attack.
          customFrameOptionsValue = "DENY";
        };
      };

      # Upstream creates the letsencrypt dir as 0700 and traefik writes
      # acme.json as 0600, both owned by traefik. pangolin (user pangolin,
      # group fossorial) must read acme.json for acmeCertSync, which flips
      # cert status pending -> done. The dir is therefore made pangolin-owned
      # (traefik keeps write access via the fossorial group) — systemd-tmpfiles
      # skips ACL ops on paths with mixed ownership ("unsafe path transition").
      # The default ACL makes files traefik creates/renews in this dir
      # group-readable.
      systemd.tmpfiles.settings."10-fossorial-paths" = {
        "/var/lib/pangolin/config/letsencrypt".d = {
          user = lib.mkForce "pangolin";
          group = "fossorial";
          mode = lib.mkForce "0770";
        };
        "/var/lib/pangolin/config/letsencrypt"."a+" = {
          argument = "g:fossorial:r-x,default:g:fossorial:r-x";
        };
      };

      # One-shot idempotent bootstrap after pangolin is up:
      #   1. ensure the org exists (create-if-missing, never BatchUpdate)
      #   2. ensure the sites exist, with our pinned newtId + fresh secret
      #   3. ensure the Authelia IdP is registered
      #   4. ensure SSO-only resources are reachable (role grant)
      # Safely re-runs: everything it creates already returns real statuses
      # if it already exists. Secrets come from sops, and the admin password
      # is only ever used for a localhost login.
      systemd.services."pangolin-apply" = {
        description = "Pangolin org/site bootstrap (idempotent)";
        wantedBy = ["multi-user.target"];
        after = ["pangolin.service"];
        requires = ["pangolin.service"];
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
          # A resource whose blueprint entry sets `auth.sso-enabled` is
          # unreachable until an org role is linked to it: badger's access
          # check requires a role->resource row (pangolin source,
          # server/routers/badger/verifySession.ts:1363-1435). Authelia-
          # provisioned users arrive in the org's default role.
          ssoRoleName = "Member";
          ssoResources = ["crowdsec"];
          ensureRoleAccess = niceId: roleName: ''
            rid=""
            for i in $(seq 1 30); do
              rid=$(curl -sf -b "$JAR" \
                ${api}/org/${orgId}/resource/${niceId} \
                | jq -r '.data.resourceId // empty' || true)
              if [ -n "$rid" ]; then break; fi
              sleep 2
            done
            if [ -z "$rid" ]; then
              echo "WARNING: resource ${niceId} absent, cannot grant ${roleName}" >&2
            else
              roleId=$(curl -sf -b "$JAR" ${api}/org/${orgId}/roles \
                | jq -r --arg n "${roleName}" \
                    '[.data.roles[]? | select(.name == $n)][0].roleId // empty')
              if [ -z "$roleId" ]; then
                echo "WARNING: role ${roleName} absent, cannot grant ${niceId}" >&2
              elif curl -sf -b "$JAR" ${api}/resource/"$rid"/roles \
                  | jq -e --argjson r "$roleId" \
                      '[.data.roles[]? | select(.roleId == $r)] | length > 0' >/dev/null; then
                echo "role ${roleName} already has access to ${niceId}"
              else
                curl -sf -b "$JAR" -X POST ${api}/resource/"$rid"/roles/add \
                  -H 'Content-Type: application/json' \
                  -H 'x-csrf-token: x-csrf-protection' \
                  -d "$(jq -n --argjson r "$roleId" '{roleId: $r}')" >/dev/null
                echo "granted role ${roleName} access to ${niceId}"
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
          ${lib.concatMapStringsSep "\n" (niceId:
            ensureRoleAccess niceId ssoRoleName)
          ssoResources}
        '';
      };
    };

    eclairNixosModules.newt = {config, ...}: {
      sops.secrets."newt-eclair" = {
        sopsFile = ../../secrets/eclair/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt-eclair".path;
        settings = {
          endpoint = "https://pangolin.ext.kuipr.de";
          id = "eclair";
        };
        blueprint = {
          client-resources = (clientResources "eclair") // (exitNodeResources "eclair");
          proxy-resources = proxyResources "eclair";
        };
      };

      # eclair runs public vhosts of its own (subtidal): its newt applies the
      # proxy-resources that route back to eclair's loopback services.
    };

    nixosModules.newt = {config, ...}: {
      sops.secrets."newt-sorbet" = {
        sopsFile = ../../secrets/sorbet/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt-sorbet".path;
        settings = {
          # The pangolin server runs on eclair; this module is evaluated on
          # sorbet where services.pangolin.dashboardDomain is unset ("").
          endpoint = "https://pangolin.ext.kuipr.de";
          id = "sorbet";
        };
        blueprint = {
          client-resources = (clientResources "sorbet") // (exitNodeResources "sorbet");
          proxy-resources = proxyResources "sorbet";
        };
      };
    };
  };
}
