{
  lib,
  config,
  ...
}: let
  vhosts = config.flake.pangolinVirtualHosts;

  byCaddy = lib.filterAttrs (_: v: v.private && v.site == "sorbet" && !(v.extra ? mode)) vhosts;

  stray = lib.filterAttrs (_: v: v.private && v.site != "sorbet" && !(v.extra ? mode)) vhosts;

  # Upstreams come from the docker module: caddy dials whatever the container
  # carrying this selector label reports, so no host port is published.
  # containerHost is explicit because reading the containers option here would
  # recurse through the labels this module attaches.
  caddyLabelsFor = v: {
    "homelab.caddy.vhost" = v.subdomain;
    "com.caddyserver.http.enable" = "true";
    "com.caddyserver.http.upstream.port" = toString v.port;
  };

  reverseProxyFor = v:
    "reverse_proxy {\n"
    + "  dynamic docker {\n"
    + "    label homelab.caddy.vhost ${v.subdomain}\n"
    + "  }\n"
    + lib.optionalString (v.protocol == "https") (
      "  transport http {\n    tls"
      + lib.optionalString v.tlsInsecureSkipVerify "\n    tls_insecure_skip_verify"
      + "\n  }\n"
    )
    + "}";

  staticReverseProxyFor = v:
    ''reverse_proxy ${v.protocol}://${v.hostname}:${toString v.port}''
    + lib.optionalString v.tlsInsecureSkipVerify " {\n      transport http {\n        tls_insecure_skip_verify\n      }\n    }";

  pocketIdUrl = "https://id.ext.kuipr.de";
  oidcClientId = "caddy-security";

  authVhosts = lib.filterAttrs (_: v: v.auth.enable) byCaddy;

  # Authcrunch matches the redirect URL host verbatim, port included, so the
  # :443 form has to be listed as well: pangolin forwards the Host header with it.
  trustLoginRedirects = lib.concatMapStringsSep "\n        " (v:
    "trust login redirect uri domain exact ${v.subdomain} path prefix /\n        "
    + "trust login redirect uri domain exact ${v.subdomain}:443 path prefix /")
  (lib.attrValues authVhosts);

  # Bypass paths still reach the backend: the pangolin health check uses one and
  # must not be answered with a redirect to the login.
  indentBy = spaces: lib.replaceStrings ["\n"] ["\n${spaces}"];

  siteRoutesFor = proxyFor: v: let
    proxied = indentBy "  " (proxyFor v);
    bypass =
      lib.concatMapStringsSep "\n" (p: ''
        route ${p} {
          ${proxied}
        }
      '')
      v.auth.bypassPaths;
  in
    if !v.auth.enable
    then proxyFor v
    else ''
      @login path /caddy-security/*
      route @login {
        authenticate with pocketid_portal
      }
      ${bypass}
      route {
        authorize with pocketid_policy
        ${proxied}
      }
    '';

  loginConfig = ''
    order authenticate before respond
    security {
      oauth identity provider pocketid {
        realm pocketid
        driver generic
        client_id ${oidcClientId}
        client_secret {env.POCKETID_OIDC_CLIENT_SECRET}
        scopes openid email profile
        base_auth_url ${pocketIdUrl}
        metadata_url ${pocketIdUrl}/.well-known/openid-configuration
      }

      authentication portal pocketid_portal {
        crypto default token lifetime 3600
        crypto key sign-verify {env.CADDY_SECURITY_JWT_KEY}
        enable identity provider pocketid
        ${trustLoginRedirects}
        transform user {
          match realm pocketid
          action add role authp/user
        }
      }

      authorization policy pocketid_policy {
        set auth url /caddy-security/oauth2/pocketid
        crypto key verify {env.CADDY_SECURITY_JWT_KEY}
        allow roles authp/user
      }
    }
  '';
in {
  flake = {
    pangolinHostResources."int" = {
      site = "sorbet";
      name = "int (caddy edge)";
      destination = "127.0.0.1";
      alias = "*.int.kuipr.de";
      tcpPorts = "443";
      udpPorts = "";
      icmp = false;
    };

    nixosModules.caddy = {
      config,
      pkgs,
      ...
    }: let
      # Container upstreams win over static ones; technitium is a systemd service.
      usesDocker = v: v.containerHost != null;
      proxyFor = v:
        if usesDocker v
        then reverseProxyFor v
        else staticReverseProxyFor v;
      dockerVhosts = lib.filter usesDocker (lib.attrValues byCaddy);

      renderEntry = v: "<li><a href=\"https://${v.subdomain}\">${
        lib.optionalString (v.name != null) (v.name + " ")
      }(${v.subdomain})</a></li>";
      indexDir = pkgs.writeTextDir "index.html" ''
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>sorbet</title>
          <style>
            body { font-family: sans-serif; max-width: 40em; margin: 2em auto; padding: 0 1em; }
            h1 { font-size: 1.2rem; font-weight: 600; margin-bottom: 0.4em; }
            ul { list-style: none; padding: 0; }
            li { margin: 0.4em 0; }
            a { color: -webkit-link; }
          </style>
        </head>
        <body>
          <h1>sorbet</h1>
          <ul>
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: renderEntry) byCaddy)}
          </ul>
        </body>
        </html>
      '';
    in
      if stray != {}
      then
        throw "caddy: private vhosts on a non-sorbet site need an explicit pangolin extra.mode: ${
          lib.concatStringsSep ", " (lib.attrNames stray)
        }"
      else
        lib.mkIf (byCaddy != {}) {
          networking.firewall.allowedTCPPorts = [80 443];

          sops.secrets."caddy/bunny_api_key" = {
            sopsFile = ../secrets/sorbet/caddy;
            format = "binary";
            key = "";
            owner = "caddy";
          };

          sops.secrets."caddy/security" = {
            sopsFile = ../secrets/sorbet/caddy-security.env;
            format = "dotenv";
            key = "";
            owner = "caddy";
            mode = "0400";
            restartUnits = ["caddy.service"];
          };

          services.caddy = {
            enable = true;
            # Admin port is pinned to 2020, so a reload cannot pick it up.
            enableReload = false;
            package = pkgs.caddy.withPlugins {
              plugins = [
                "github.com/caddy-dns/bunny@v1.2.0"
                "github.com/greenpau/caddy-security@v1.6.2"
                "github.com/invzhi/caddy-docker-upstreams@v1.2.0"
              ];
              hash = "sha256-7LvXpl/SLLw6TNcVeAZHcZA7TMB9xtRHDmprU1f+NIc=";
            };
            globalConfig = ''
              admin localhost:2020
              ${lib.optionalString (authVhosts != {}) loginConfig}
              acme_dns bunny {env.BUNNY_API_KEY}
              # ACME TXT records are public and deliberately not in the LAN zone.
              tls_resolvers 1.1.1.1 8.8.8.8
            '';
            virtualHosts =
              lib.mapAttrs' (_: v:
                lib.nameValuePair v.subdomain {
                  extraConfig = ''
                    log {
                      output stderr
                      level INFO
                      # Query strings carry admin tokens; journald must not keep them.
                      format filter {
                        request>uri query {
                          hash token
                        }
                        request>headers>X-Csrftoken delete
                      }
                    }
                    ${siteRoutesFor proxyFor v}
                  '';
                })
              byCaddy
              // {
                "home.int.kuipr.de" = {
                  extraConfig = ''
                    root * ${indexDir}
                    file_server
                  '';
                };
              };
          };

          virtualisation.oci-containers.containers =
            lib.listToAttrs (map (v: lib.nameValuePair v.containerHost {labels = caddyLabelsFor v;}) dockerVhosts);

          assertions = [
            {
              assertion = lib.all (v: config.virtualisation.oci-containers.containers ? ${v.containerHost}) dockerVhosts;
              message = "caddy: containerHost of a vhost names no container: ${lib.concatStringsSep ", " (map (v: v.subdomain) (lib.filter (v: !(config.virtualisation.oci-containers.containers ? ${v.containerHost})) dockerVhosts))}";
            }
          ];

          # The docker module reads the podman socket at /run/podman/podman.sock.
          # Caddy fails to provision at all without it, so order the start.
          users.users.caddy.extraGroups = ["podman"];

          systemd.services.caddy = {
            requires = ["podman.socket"];
            after = ["podman.socket"];
            serviceConfig = {
              Environment = ["DOCKER_HOST=unix:///run/podman/podman.sock"];
              EnvironmentFile = [
                config.sops.secrets."caddy/bunny_api_key".path
                config.sops.secrets."caddy/security".path
              ];
            };
          };
        };
  };
}
