# Start nix-daemon at boot on both hosts.
#
# Determinate's determinate-nixd writes /etc/nix/nix.conf when it starts, and
# that generated file is the only one that includes /etc/nix/nix.custom.conf
# (i.e. everything declared through nix.settings). The unit ships
# socket-activated only (WantedBy= is empty), and root's nix talks to the store
# directly instead of through the daemon socket. On eclair nothing ever touched
# that socket, so /etc/nix/nix.conf never appeared and nix silently ran on its
# builtin defaults: substituters = cache.nixos.org only, every cachix cache
# ignored, host-specific derivations (e.g. podman with podman-compose from
# extraPackages) rebuilt from source.
_: let
  nixDaemonConfig = {
    systemd.services.nix-daemon.wantedBy = ["multi-user.target"];
  };
in {
  flake.nixosModules.nixDaemon = nixDaemonConfig;
  flake.eclairNixosModules.nixDaemon = nixDaemonConfig;
}
