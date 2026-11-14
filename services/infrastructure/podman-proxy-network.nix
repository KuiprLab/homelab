{
  lib,
  config,
  ...
}: let
  constants = config.flake.constants;
  hosts = config.flake.podmanProxyHosts;
  names = lib.attrNames hosts;
  addresses = map (name: hosts.${name}.ip) names;
in {
  options.flake.podmanProxyHosts = lib.mkOption {
    description = ''
      Containers on the shared podman `proxy` network, keyed by container name.
      Addresses are pinned because newt runs on the host, outside podman's DNS:
      /etc/hosts hands it the same names the containers resolve inside the
      network, so containers need no published port to be addressable by name.
    '';
    type = lib.types.attrsOf (lib.types.submodule {
      options.ip = lib.mkOption {
        type = lib.types.str;
        description = "Static address in 10.89.0.0/24, below the network's .128 dynamic range.";
      };
    });
    default = {};
  };

  config.flake.nixosModules.podmanProxyNetwork = {config, ...}: let
    containers = lib.filter (name: config.virtualisation.oci-containers.containers ? ${name}) names;
  in {
    assertions = [
      {
        assertion = lib.length addresses == lib.length (lib.unique addresses);
        message = "podmanProxyHosts: a pinned IP is used twice";
      }
    ];

    networking.extraHosts = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: host: "${host.ip} ${name}") hosts);

    systemd.services =
      {
        podman-create-network-proxy = {
          description = "Create the shared podman proxy network";
          wantedBy = ["multi-user.target"];
          path = [config.virtualisation.podman.package];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # The dynamic range keeps auto-allocation clear of the pinned addresses.
          script = ''
            podman network exists proxy ||
              podman network create --subnet ${constants.proxySubnet} --ip-range ${constants.proxyDynamicRange} proxy
          '';
        };
      }
      // lib.genAttrs (map (name: "podman-${name}") containers) (_: {
        requires = ["podman-create-network-proxy.service"];
        after = ["podman-create-network-proxy.service"];
      });
  };
}
