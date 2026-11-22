{
  constants,
  resources,
}: let
  inherit
    (resources)
    siteSettings
    clientResources
    exitNodeResources
    ;

  image = "docker.io/fosrl/newt:1.20.1@sha256:03561e3f3d10b94ee7839318ae46e5acf8b4431550ea1d0e15666ab60caa2e43";

  newtModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.homelab.pangolinSite;
    site = cfg.name;
    blueprint = (pkgs.formats.yaml {}).generate "blueprint-${site}.yml" {
      sites = siteSettings site;
      client-resources = (clientResources site) // (exitNodeResources site);
    };
    secret = "newt-${site}";
  in
    lib.mkIf cfg.enable {
      sops.secrets.${secret} = {
        sopsFile = cfg.newtSopsFile;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      systemd.services."podman-newt" = {
        serviceConfig =
          {
            EnvironmentFile = config.sops.secrets.${secret}.path;
          }
          // lib.optionalAttrs cfg.enforceHealthcheckTls {
            Environment = ["ENFORCE_HC_CERT=true"];
          };
        # /etc/hosts is copied into the container at creation; restart when a proxy host is added.
        restartTriggers = [
          (pkgs.writeText "podman-proxy-hosts" config.networking.extraHosts)
        ];
      };

      virtualisation.oci-containers.containers.newt = {
        inherit image;
        volumes = [
          "${blueprint}:/blueprint.yml:ro"
          "/run/podman/podman.sock:/var/run/docker.sock:ro"
        ];
        cmd = [
          "--endpoint=https://${constants.dashboardDomain}"
          "--id=${constants.sites.${site}.niceId}"
          "--blueprint-file=/blueprint.yml"
        ];
        extraOptions = [
          "--network=host"
          "--env-host"
          "--env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          "--env=DOCKER_SOCKET=unix:///var/run/docker.sock"
        ];
        log-driver = "journald";
      };
    };
in {
  flake.hostModules.newt = newtModule;
}
