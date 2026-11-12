{
  lib,
  config,
  ...
}: let
  vhosts = config.flake.pangolinVirtualHosts;
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

    nixosModules.caddy = import ./_caddy/module.nix {inherit lib vhosts;};
  };
}
