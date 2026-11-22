_: {
  flake.crossaintNixosModules.crossaintHardwareConfiguration = {
    lib,
    modulesPath,
    ...
  }: {
    imports = [
      (modulesPath + "/profiles/qemu-guest.nix")
    ];

    boot = {
      initrd.availableKernelModules = ["ahci" "virtio_pci" "virtio_scsi" "virtio_blk"];
      kernelParams = ["console=ttyS0"];
      loader.grub.device = "/dev/vda";
    };

    fileSystems."/" = {
      device = "/dev/disk/by-uuid/f222513b-ded1-49fa-b591-20ce86a2fe7f";
      fsType = "ext4";
    };

    swapDevices = [];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
