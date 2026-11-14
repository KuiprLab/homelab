{constants}: {
  flake.eclairNixosModules.pangolin-server = {
    config,
    pkgs,
    ...
  }: let
    configDir = "/var/lib/pangolin/config";
    lapiKeyFile = "/var/lib/pangolin/crowdsec-lapi-key";
    files = import ./server-files.nix {
      inherit pkgs;
      inherit (constants) baseDomain dashboardDomain podmanBridgeGateway tolerance;
    };
    inherit (files) banPage configFile traefikStatic traefikDynamic;
  in {
    sops.secrets."pangolin" = {
      sopsFile = ../../../secrets/eclair/pangolin.env;
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
                image = "docker.io/fosrl/pangolin:ee-latest@sha256:c65b8b4656b3336cea3f2647fc20da955764cd18103c51b2ea6164bbb054e0de";
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
                image = "docker.io/fosrl/gerbil:1.6.0@sha256:420f5210b6d1a6d3035f15c3938b5289fee5aeff51ffdcb9b217838338908885";
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
                image = "docker.io/library/traefik:v3.7.18@sha256:9c437ac4f09ce6f4980a8544902d3475fdf70a1a7c578729581d2535dfa7d635";
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
}
