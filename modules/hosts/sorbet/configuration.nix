_: let
  user = "daniel";
in {
  flake.nixosModules.sorbetConfiguration = {pkgs, ...}: {
    system.stateVersion = "24.05";

    environment.systemPackages = with pkgs; [
      # Base system
      neovim
      git
      just
      curl
    ];

    sops = {
      age.keyFile = "/var/lib/sops/age-key.txt";
      age.generateKey = false;
      secrets = {
        "deploy_webhook" = {
          sopsFile = ../../../secrets/shared/deploy-webhook;
          format = "binary";
          key = "";
          owner = "root";
        };
      };
    };

    services.hardware.openrgb = {
      enable = true;
    };

    networking = {
      firewall.trustedInterfaces = ["incusbr0"];
      nftables.enable = true;
    };

    virtualisation = {
      incus = {
        enable = true;
        ui.enable = true;
        agent.enable = true;
      };

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
      # Enable container features
      containers.enable = true;
    };

    # Networking
    networking = {
      firewall.enable = true;
      hostName = "sorbet";
      networkmanager.enable = true;
      useDHCP = false; # disable global DHCP
      interfaces."enp0s31f6" = {
        wakeOnLan.enable = true;
        ipv4.addresses = [
          {
            address = "192.168.0.85";
            prefixLength = 24;
          }
        ];
      };
      defaultGateway = "192.168.0.1";
      nameservers = [
        "1.1.1.1"
        "127.0.0.1"
      ];
    };

    # Nix settings
    nix = {
      channel.enable = false;
      extraOptions = ''
        experimental-features = nix-command flakes
        warn-dirty = false
      '';
      settings = {
        # Cap build parallelism so deploys don't peg the machine.
        max-jobs = 4;
        cores = 2;
        substituters = [
          "https://cache.nixos.org/"
          "https://sorbet.cachix.org"
          "https://nix-community.cachix.org"
          "https://frostplexx.cachix.org"
          "https://nvf.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "sorbet.cachix.org-1:p1+jtoj8v75vhRut7fGY5jL7k4BNMFvMBcQSDKbF3Aw="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "frostplexx.cachix.org-1:kjkhnGNSkUvf5Mx8OEfhzaR830CUkDRglaKduAcr3UQ="
          "nvf.cachix.org-1:GMQWiUhZ6ux9D5CvFFMwnc2nFrUHTeGaXRlVBXo+naI="
        ];
      };
    };

    # Time and locale
    time.timeZone = "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "de_DE.UTF-8";
      LC_IDENTIFICATION = "de_DE.UTF-8";
      LC_MEASUREMENT = "de_DE.UTF-8";
      LC_MONETARY = "de_DE.UTF-8";
      LC_NAME = "de_DE.UTF-8";
      LC_NUMERIC = "de_DE.UTF-8";
      LC_PAPER = "de_DE.UTF-8";
      LC_TELEPHONE = "de_DE.UTF-8";
      LC_TIME = "de_DE.UTF-8";
    };

    environment.pathsToLink = [
      "/libexec"
    ];

    # Services
    services = {
      cron = {
        enable = true;
        systemCronJobs = [
          "0 0 * * *       root    podman auto-update"
        ];
      };
      openssh.enable = true;
      pipewire = {
        enable = true;
        alsa = {
          enable = true;
        };
        pulse.enable = true;
      };
    };

    # User configuration
    programs.fish.enable = true;
    users = {
      defaultUserShell = pkgs.fish;
      users = {
        root = {
          openssh.authorizedKeys.keys = [
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCo089vTmBwFAMv6d7ix3D6gPx0X0DEwOELB0i9AyDpct4kj3II8IjtwovZDalE53CZAlczhae+/9EV+3cn1YwvKMEU9MkY3nY6/HIPqvQaWVNrhLAP7W1JWNMwNl+ndkm+Xa1ZlaYbOJrKED8E63j2j5WNnNN6WUld7d4Nf5oog0YaYYoD22fiMvnTMdFg2pE2lLFZ4mX2NBHU8r/1hcy6XTXdryoZB4KuzvnMOZPb5j48rsH6AZG5i9CMq7iSi3+DeSGzdrxVvJ1HWKTpTlKlvz/7LKhrCwtXrvFwzxh4xxFig/As05LfmxShThUb1QqS874USBwM5lacrZ4lJbIEwbtQ9zJad8p0pVzlby+BwLaQmmljrR9H0AZMagmD0Gv5K/DC035XCI9acSazL84qJ0IfGugfXdFQbT+ViFRrV7+9J5IbulOV40lwHrgnIeFc2Msbe2PelphKIlrx9JqW6ArtT7zbtbG8q+oZSb8TqCdFx5pZuQCA8gtj4Y5wxo0pFhym5qqN6Eh0CbliqYsDwIcUfmkj0omsFXFLN5U9D25jUxPmFZUFU/PJnbWxjfu6835PZtchHozV/vqYqc8WKBis+HWjBM1OH26fbo7FmT60hod8K6fsKV6HN/tpuY9gCQBD/CuVO+nlSBr/kVmO9KGi9jEaPTF2JylnujN1ow=="
          ];
        };

        ${user} = {
          isNormalUser = true;
          description = user;
          openssh.authorizedKeys.keys = [
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCo089vTmBwFAMv6d7ix3D6gPx0X0DEwOELB0i9AyDpct4kj3II8IjtwovZDalE53CZAlczhae+/9EV+3cn1YwvKMEU9MkY3nY6/HIPqvQaWVNrhLAP7W1JWNMwNl+ndkm+Xa1ZlaYbOJrKED8E63j2j5WNnNN6WUld7d4Nf5oog0YaYYoD22fiMvnTMdFg2pE2lLFZ4mX2NBHU8r/1hcy6XTXdryoZB4KuzvnMOZPb5j48rsH6AZG5i9CMq7iSi3+DeSGzdrxVvJ1HWKTpTlKlvz/7LKhrCwtXrvFwzxh4xxFig/As05LfmxShThUb1QqS874USBwM5lacrZ4lJbIEwbtQ9zJad8p0pVzlby+BwLaQmmljrR9H0AZMagmD0Gv5K/DC035XCI9acSazL84qJ0IfGugfXdFQbT+ViFRrV7+9J5IbulOV40lwHrgnIeFc2Msbe2PelphKIlrx9JqW6ArtT7zbtbG8q+oZSb8TqCdFx5pZuQCA8gtj4Y5wxo0pFhym5qqN6Eh0CbliqYsDwIcUfmkj0omsFXFLN5U9D25jUxPmFZUFU/PJnbWxjfu6835PZtchHozV/vqYqc8WKBis+HWjBM1OH26fbo7FmT60hod8K6fsKV6HN/tpuY9gCQBD/CuVO+nlSBr/kVmO9KGi9jEaPTF2JylnujN1ow=="
          ];
          initialPassword = "nixos";
          extraGroups = [
            "networkmanager"
            "root"
            "wheel"
            "incus-admin"
          ];
        };
      };
    };

    # Home Manager
    home-manager.users.${user} = _: {
      home = {
        stateVersion = "23.11";
        username = user;
        homeDirectory = "/home/${user}";
        sessionVariables = {
          EDITOR = "nvim";
        };
      };
      programs.home-manager.enable = true;
    };
  };
}
