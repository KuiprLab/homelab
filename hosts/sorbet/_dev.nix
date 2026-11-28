{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    ./_orbstack.nix
  ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # OrbStack wires eth0 itself; NetworkManager would fight systemd-networkd for it.
  networking = {
    networkmanager.enable = lib.mkForce false;
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # orb runs commands as uid 501 of the macOS user; the group carries the file shares.
  users.users.daniel.extraGroups = ["orbstack"];
  security.sudo.wheelNeedsPassword = false;

  # modprobe cannot load modules: the container borrows the OrbStack kernel.
  boot.kernelModules = lib.mkForce [];

  # kubectl verifies the API cert, so both addresses used from the Mac must be SANs.
  services.k3s.extraFlags = [
    "--tls-san=nixos.orb.local"
    "--tls-san=192.168.139.139"
  ];

  # No age key is exported to the VM; a throwaway one keeps sops-nix activation green.
  sops.age.generateKey = lib.mkForce true;

  homelab = {
    rex.enable = false;
    heartbeat.enable = false;
  };

  services.comin.enable = lib.mkForce false;
}
