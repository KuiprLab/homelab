{
  labels,
  proxyIp,
}: {
  lib,
  pkgs,
  ...
}: let
  tiny-cdn = pkgs.callPackage ./_package.nix {};

  image = pkgs.dockerTools.buildLayeredImage {
    name = "tiny-cdn";
    tag = tiny-cdn.version;
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
    # Must match the repository:tag inside image.tar, or podman pulls instead of loading.
    image = "tiny-cdn:${tiny-cdn.version}";
    imageFile = pkgs.runCommand "tiny-cdn-image.tar" {} ''
      ln -s ${image} $out
    '';
    volumes = [
      "/var/lib/tiny-cdn:/data"
      "${./authorized.pub}:/authorized.pub:ro"
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
}
