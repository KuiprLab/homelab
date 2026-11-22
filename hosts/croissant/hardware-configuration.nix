_: {
  flake.croissantNixosModules.croissantHardwareConfiguration = {
    lib,
    modulesPath,
    ...
  }: {
    imports = [
      (modulesPath + "/profiles/qemu-guest.nix")
    ];

    boot = {
      initrd.availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "sr_mod" "virtio_blk"];
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };
    };

    # Placeholder: replace the UUIDs with nixos-generate-config output.
    fileSystems."/" = {
      device = "/dev/disk/by-uuid/REPLACE-ROOT-UUID";
      fsType = "ext4";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-uuid/REPLACE-BOOT-UUID";
      fsType = "vfat";
      options = ["fmask=0077" "dmask=0077"];
    };

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
