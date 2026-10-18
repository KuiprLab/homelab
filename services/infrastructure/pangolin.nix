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
  options.flake.pangolinVirtualHosts = lib.mkOption {
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
            true  -> client-resource under the site (pangolin generates a site
                     resource with certs on pangolin; only reachable through
                     the tunnel network / VPN clients).
            false -> public proxy-resource routed by pangolin's traefik.
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

  config.flake = let
    vhosts = config.flake.pangolinVirtualHosts;

    forSite = site: lib.filterAttrs (_nick: v: v.site == site) vhosts;

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

    # > private: moderately-documented client-resources; applied through the
    # newt of the site listed in vh.site.
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
        }
        vh.extra)
      (lib.filterAttrs (_: vh: vh.private) (forSite site));

    proxyResources = site:
      lib.mapAttrs (_nick: vh:
        lib.recursiveUpdate
        {
          inherit (vh) name;
          mode = "http";
          "full-domain" = vh.subdomain;
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
        vh.extra)
      (lib.filterAttrs (_: vh: !vh.private) (forSite site));
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
        # Certificates are wildcard entries (*.int.kuipr.de, *.ext.kuipr.de);
        # HTTP-01 cannot issue those, so request them via DNS-01 (bunny).
        settings.domains.domain1.prefer_wildcard_cert = true;
      };

      # traefik performs the DNS-01 challenge and therefore needs
      # BUNNY_API_KEY, which lives in the shared pangolin dotenv.
      services.traefik.environmentFiles = [config.sops.secrets."pangolin".path];

      # Upstream creates the letsencrypt dir as 0700 and traefik writes
      # acme.json as 0600, both owned by traefik. pangolin (user pangolin,
      # group fossorial) must read acme.json for acmeCertSync, which flips
      # cert status pending -> done. Grant fossorial read via ACLs; the
      # default ACL covers files traefik recreates on renewal.
      systemd.tmpfiles.settings."10-fossorial-paths" = {
        "/var/lib/pangolin/config/letsencrypt".d = {
          user = "traefik";
          group = "fossorial";
          mode = lib.mkForce "0750";
        };
        "/var/lib/pangolin/config/letsencrypt"."-a+" = {
          user = "-";
          group = "-";
          argument = "g:fossorial:r-x,default:g:fossorial:r-x";
        };
        "/var/lib/pangolin/config/letsencrypt/acme.json"."-a+" = {
          user = "-";
          group = "-";
          argument = "g:fossorial:r--";
        };
      };

      # One-shot idempotent bootstrap after pangolin is up:
      #   1. ensure the org exists (create-if-missing, never BatchUpdate)
      #   2. ensure the sites exist, with our pinned newtId + fresh secret
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
          client-resources = clientResources "eclair";
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
          client-resources = clientResources "sorbet";
          proxy-resources = proxyResources "sorbet";
        };
      };
    };
  };
}
