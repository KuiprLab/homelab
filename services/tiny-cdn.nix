{config, ...}: let
  proxyIp = "10.89.0.70";
  vhost = config.flake.pangolinVirtualHosts."tiny-cdn";
  labels =
    config.flake.pangolinRuleLabels "tiny-cdn"
    // config.flake.pangolinHealthcheckLabels "tiny-cdn" vhost
    // {
      "pangolin.proxy-resources.tiny-cdn.name" = vhost.name;
      "pangolin.proxy-resources.tiny-cdn.full-domain" = vhost.subdomain;
      "pangolin.proxy-resources.tiny-cdn.mode" = "http";
      "pangolin.proxy-resources.tiny-cdn.labels[0]" = "edge:public";
      "pangolin.proxy-resources.tiny-cdn.labels[1]" = "site:${vhost.site}";
      "pangolin.proxy-resources.tiny-cdn.targets[0].hostname" = vhost.hostname;
      "pangolin.proxy-resources.tiny-cdn.targets[0].port" = toString vhost.port;
      "pangolin.proxy-resources.tiny-cdn.targets[0].method" = vhost.protocol;
    };
in {
  flake = {
    podmanProxyHosts.tiny-cdn.ip = proxyIp;

    pangolinVirtualHosts."tiny-cdn" = {
      site = "sorbet";
      name = "tiny-cdn";
      subdomain = "cdn.ext.kuipr.de";
      private = false;
      hostname = "tiny-cdn";
      port = 3030;
      healthcheck.path = "/health";
    };

    nixosModules.tiny-cdn = {
      lib,
      pkgs,
      ...
    }: let
      tiny-cdn = pkgs.callPackage ../apps/tiny-cdn/_package.nix {};

      image = pkgs.dockerTools.buildLayeredImage {
        name = "tiny-cdn";
        tag = "1.0.0";
        contents = pkgs.buildEnv {
          name = "tiny-cdn-root";
          paths = [tiny-cdn pkgs.bash];
          pathsToLink = ["/bin"];
        };
        config = {
          Cmd = [
            "/bin/tiny-cdn"
            "--bind"
            "0.0.0.0"
            "--port"
            "3030"
            "-s"
            "/data"
            "-p"
            "/authorized.pub"
          ];
          User = "10001:10001";
          WorkingDir = "/data";
        };
      };
    in {
      systemd.tmpfiles.rules = [
        "d /var/lib/tiny-cdn 0750 10001 10001 - -"
      ];

      virtualisation.oci-containers.containers.tiny-cdn = {
        inherit labels;
        image = "tiny-cdn:1.0.0";
        imageFile = pkgs.runCommand "tiny-cdn-image.tar" {} ''
          ln -s ${image} $out
        '';
        volumes = [
          "/var/lib/tiny-cdn:/data"
          "${../apps/tiny-cdn/authorized.pub}:/authorized.pub:ro"
        ];
        log-driver = "journald";
        extraOptions = [
          "--network=proxy:ip=${proxyIp}"
          "--health-cmd=bash -c 'exec 3<>/dev/tcp/127.0.0.1/3030'"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=10s"
          "--health-timeout=5s"
        ];
      };

      systemd.services."podman-tiny-cdn".serviceConfig.Restart = lib.mkOverride 90 "always";
    };
  };
}
