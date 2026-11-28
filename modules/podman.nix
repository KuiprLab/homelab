_: let
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
in {
  flake.hostModules.podman = mkPodman;
}
