{lib, ...}: {
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
            description = "Backend port as seen from the site: the container's own port, not a published one.";
          };
          hostname = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = ''
              Backend host as seen from the site. Container names on the podman
              proxy network resolve for both caddy and newt; 127.0.0.1 stays for
              host-networked services (technitium, homeassistant, upsnap).
            '';
          };
          containerHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Container whose labels carry this public resource. Defaults to
              `hostname`; set it when the vhost points at 127.0.0.1 because the
              container is host-networked.
            '';
          };
          tlsInsecureSkipVerify = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Let caddy skip TLS verification of an https backend. Only for
              backends that serve a self-signed certificate.
            '';
          };
          healthcheck = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Whether pangolin probes this vhost's backend.";
                };
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
          auth = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Serve this vhost behind the Pocket ID login in caddy
                    (services/caddy.nix). Applies to private vhosts on sorbet,
                    which are the ones caddy serves.
                  '';
                };
                bypassPaths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = ''
                    Paths that skip the login check and reach the backend
                    directly. Use for unauthenticated health endpoints and
                    point the pangolin health check at the same path.
                  '';
                };
              };
            };
            default = {};
            description = "Login gate for this vhost.";
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
            description = "Pocket ID base URL used as the OIDC issuer.";
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
          standaloneHealthChecks = lib.mkOption {
            description = ''
              Site-scoped health checks that exist only as pangolin rows (the
              alerting page's "standalone" checks). Blueprints carry a health
              check per proxy-resource target only, so private resources are
              reconciled here instead. Consumed by apps/pangolin-apply.
            '';
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Reconcile key: a check with this name is created, updated or deleted.";
                };
                siteNiceId = lib.mkOption {type = lib.types.str;};
                hcHostname = lib.mkOption {type = lib.types.str;};
                hcPort = lib.mkOption {type = lib.types.port;};
                hcScheme = lib.mkOption {type = lib.types.enum ["http" "https"];};
                hcPath = lib.mkOption {type = lib.types.str;};
                hcInterval = lib.mkOption {type = lib.types.int;};
                hcUnhealthyInterval = lib.mkOption {type = lib.types.int;};
                hcUnhealthyThreshold = lib.mkOption {type = lib.types.int;};
              };
            });
            default = [];
          };
        };
      };
    };
  };
}
