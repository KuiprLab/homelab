# Copy of the OrbStack-generated /etc/nixos/orbstack.nix on the dev machine.
# OrbStack rewrites the original on upgrade, so keep this copy in sync by hand.
{lib, ...}: {
  environment.shellInit = ''
    . /opt/orbstack-guest/etc/profile-early

    # add your customizations here

    . /opt/orbstack-guest/etc/profile-late
  '';

  documentation = {
    man.enable = true;
    doc.enable = true;
    info.enable = true;
  };

  # OrbStack owns the resolver; its own file is the only one that resolves machine names.
  services.resolved.enable = false;
  networking.resolvconf.enable = false;
  environment.etc."resolv.conf".source = "/opt/orbstack-guest/etc/resolv.conf";

  networking.dhcpcd.extraConfig = ''
    noarp
    noipv6
  '';

  # OrbStack does not implement the systemd watchdog; those units restart without it.
  systemd.services =
    lib.genAttrs [
      "systemd-oomd"
      "systemd-userdbd"
      "systemd-udevd"
      "systemd-timesyncd"
      "systemd-timedated"
      "systemd-portabled"
      "systemd-nspawn@"
      "systemd-machined"
      "systemd-localed"
      "systemd-logind"
      "systemd-journald@"
      "systemd-journald"
      "systemd-journal-remote"
      "systemd-journal-upload"
      "systemd-importd"
      "systemd-hostnamed"
      "systemd-homed"
      "systemd-networkd"
    ] (_: {
      serviceConfig.WatchdogSec = 0;
    });

  programs.ssh.extraConfig = ''
    Include /opt/orbstack-guest/etc/ssh_config
  '';

  nix.settings.extra-platforms = [
    "x86_64-linux"
    "i686-linux"
  ];

  users.groups.orbstack.gid = 67278;
}
