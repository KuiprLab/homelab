# determinate-nixd only writes /etc/nix/nix.conf when the daemon starts; it is socket-activated.
_: let
  nixDaemonConfig = {
    systemd.services.nix-daemon.wantedBy = ["multi-user.target"];
  };
in {
  flake.nixosModules.nixDaemon = nixDaemonConfig;
  flake.eclairNixosModules.nixDaemon = nixDaemonConfig;
}
