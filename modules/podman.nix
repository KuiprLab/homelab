{lib, ...}: let
  mkPodman = {pkgs, ...}: {
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
    };
  };

  healthFlags = {
    cmd,
    interval ? "30s",
    retries ? 3,
    startPeriod,
    timeout,
  }: [
    "--health-cmd=${cmd}"
    "--health-interval=${interval}"
    "--health-on-failure=kill"
    "--health-retries=${toString retries}"
    "--health-start-period=${startPeriod}"
    "--health-timeout=${timeout}"
  ];
in {
  options.flake.healthFlags = lib.mkOption {
    type = lib.types.functionTo (lib.types.listOf lib.types.str);
    description = ''
      Podman health-check flags for one container. Podman does not inherit the
      image's HEALTHCHECK and kills a container that fails its probe, so these
      flags always travel as a set.
    '';
  };

  config.flake = {
    inherit healthFlags;
    nixosModules.podman = mkPodman;
    eclairNixosModules.podman = mkPodman;
  };
}
