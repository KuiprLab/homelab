_: {
  flake.nixosModules.sorbetHardwareConfiguration = {
    lib,
    pkgs,
    modulesPath,
    ...
  }: {
    imports = [
      # Include the results of the hardware scan.
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

    # Boot loader
    boot = {
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };

      # Use latest kernel.
      kernelPackages = pkgs.linuxPackages_latest;

      initrd = {
        availableKernelModules = [
          "xhci_pci"
          "ahci"
          "nvme"
          "usb_storage"
          "usbhid"
          "sd_mod"
        ];
        kernelModules = [];
      };
      kernelModules = ["kvm-intel"];
      extraModulePackages = [];
    };

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-uuid/82c51ce1-bd98-46e5-85be-2185b36572b2";
        fsType = "ext4";
      };

      "/boot" = {
        device = "/dev/disk/by-uuid/382A-C4BF";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };

      "/media/data" = {
        device = "/dev/disk/by-uuid/00189421-0f9c-4f62-8fb8-6d3745c6805f";
        fsType = "btrfs";
        options = [
          "defaults"
          "nofail"
        ];
      };
    };

    swapDevices = [];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
