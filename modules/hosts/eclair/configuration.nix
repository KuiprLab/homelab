# eclair base configuration
# Minimal VPS: SSH, tailscale, sops age key, system packages.
_: {
  flake.eclairNixosModules.eclairConfiguration = {pkgs, ...}: {
    system.stateVersion = "25.05";

    environment.systemPackages = with pkgs; [
      neovim
      git
      curl
    ];

    sops = {
      # Populate /var/lib/sops/age-key.txt on the VPS before first deploy.
      age.keyFile = "/var/lib/sops/age-key.txt";
      age.generateKey = false;
    };

    networking = {
      firewall = {
        enable = true;
        # haproxy: HTTP redirect + HTTPS passthrough
        allowedTCPPorts = [80 443];
      };
      hostName = "eclair";
    };

    # Time and locale
    time.timeZone = "Europe/Berlin";
    i18n.defaultLocale = "en_US.UTF-8";

    programs.fish.enable = true;
    users.defaultUserShell = pkgs.fish;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root = {
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDCpYD5c/fhtozkcqkmTkBpLU+MV+abkfJTNurMLX0PcgWN8jJV/+5ITjkWo2hXQPloTTywZRgATRL0vXkZ5PsMSmOlvd6s/09hInCdb9WDkYtQvOiB6EBr9SvhldLtoM+BapMQx87QI1VT5EAnWIxgyYFEE8IB2VWPUqX7RjOj8+1dO8CYNhxya36SpXFFu9HLLdw+RtNQM8N/j52gzKzgI8JYejP7su9dFARtRSzYvyV4IZmVdyFr9XS8dVao9MDuiOx6PY5OZchnqYGxz9qnTdappvpIJAc0BZ90GehUU5X6ah/mFU9N8NWOXyXav0+LY0bMmdDU50PT/PUh+eQ2/HABn2N2aRoxxEhsSdNTB+VgZS0nXu3+CANiBIw8ntlq68IxjaPk9bAm8wDgRvQTN4BphAearFKFqD+xFpNR2uoYl9jL/pLTLbJxCSyGLItkPVPn2E046Xt4qf9lAJ/8ft8QphqaaS1/9LmUOW2infQdxZWeVTzhYEv7QmQiP4E0gOwGKI/damvbFsHuHr3hGWEvtZMHh0D1b4kn+v6oQVN3DNI+eSIxM4QNvZ0nw8mOSGVsIunPymgKn6/Zph04YKpfzrslwCSp7lrXytHYOz/XrcFhlq6nuAGEbeff9deNLQCsVsgTP5XD6K7EF5RogMORRvecgTAcVYqLhoj98w=="
      ];
    };

    # Nix settings
    nix = {
      channel.enable = false;
      # Automatic garbage collection: weekly, keep the last 30 days.
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
      extraOptions = ''
        experimental-features = nix-command flakes
        warn-dirty = false
      '';
      settings = {
        # Safety net — eclair must never build heavy closures itself.
        max-jobs = 1;
        cores = 1;
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
  };
}
