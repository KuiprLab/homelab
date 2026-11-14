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

  image = "docker.io/fosrl/newt:1.20.0@sha256:2170e673c4c72d905764fa22e83d0ae0aa3239fb1ab3b9fcaefb2b00fffb2d6e";

  mkNewtModule = {
    site,
    sopsFile,
    serviceEnvironment ? [],
  }: {
    config,
    lib,
    pkgs,
    ...
  }: let
    blueprint = (pkgs.formats.yaml {}).generate "blueprint-${site}.yml" {
      sites = siteSettings site;
      client-resources = (clientResources site) // (exitNodeResources site);
    };
    secret = "newt-${site}";
  in {
    sops.secrets.${secret} = {
      inherit sopsFile;
      format = "dotenv";
      key = "";
      owner = "root";
    };

    systemd.services."podman-newt".serviceConfig =
      {
        EnvironmentFile = config.sops.secrets.${secret}.path;
      }
      // lib.optionalAttrs (serviceEnvironment != []) {
        Environment = serviceEnvironment;
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
  flake = {
    eclairNixosModules.newt = mkNewtModule {
      site = "eclair";
      sopsFile = ../../../secrets/eclair/newt.env;
    };

    nixosModules.newt = mkNewtModule {
      site = "sorbet";
      sopsFile = ../../../secrets/sorbet/newt.env;
      # Health checks probe the vhost domains, so newt must verify the certificate too.
      serviceEnvironment = ["ENFORCE_HC_CERT=true"];
    };
  };
}
