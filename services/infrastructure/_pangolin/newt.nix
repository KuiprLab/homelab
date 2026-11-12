{resources}: let
  inherit
    (resources)
    siteSettings
    clientResources
    exitNodeResources
    ;
in {
  flake = {
    eclairNixosModules.newt = {
      config,
      pkgs,
      ...
    }: let
      blueprint = (pkgs.formats.yaml {}).generate "blueprint-eclair.yml" {
        sites = siteSettings "eclair";
        client-resources = (clientResources "eclair") // (exitNodeResources "eclair");
      };
    in {
      sops.secrets."newt-eclair" = {
        sopsFile = ../../../secrets/eclair/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      systemd.services."podman-newt".serviceConfig.EnvironmentFile = config.sops.secrets."newt-eclair".path;

      virtualisation.oci-containers.containers.newt = {
        image = "docker.io/fosrl/newt:1.20.0@sha256:2170e673c4c72d905764fa22e83d0ae0aa3239fb1ab3b9fcaefb2b00fffb2d6e";
        volumes = [
          "${blueprint}:/blueprint.yml:ro"
          "/run/podman/podman.sock:/var/run/docker.sock:ro"
        ];
        cmd = [
          "--endpoint=https://pangolin.ext.kuipr.de"
          "--id=eclair"
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

    nixosModules.newt = {
      config,
      pkgs,
      ...
    }: let
      blueprint = (pkgs.formats.yaml {}).generate "blueprint-sorbet.yml" {
        sites = siteSettings "sorbet";
        client-resources = (clientResources "sorbet") // (exitNodeResources "sorbet");
      };
    in {
      sops.secrets."newt-sorbet" = {
        sopsFile = ../../../secrets/sorbet/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      systemd.services."podman-newt".serviceConfig.EnvironmentFile = config.sops.secrets."newt-sorbet".path;
      # Health checks probe the vhost domains, so newt must verify the certificate too.
      systemd.services."podman-newt".serviceConfig.Environment = ["ENFORCE_HC_CERT=true"];

      virtualisation.oci-containers.containers.newt = {
        image = "docker.io/fosrl/newt:1.20.0@sha256:2170e673c4c72d905764fa22e83d0ae0aa3239fb1ab3b9fcaefb2b00fffb2d6e";
        volumes = [
          "${blueprint}:/blueprint.yml:ro"
          "/run/podman/podman.sock:/var/run/docker.sock:ro"
        ];
        cmd = [
          "--endpoint=https://pangolin.ext.kuipr.de"
          "--id=sorbet"
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
  };
}
