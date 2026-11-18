_: {
  flake.eclairNixosModules.eclairConfiguration = {pkgs, ...}: {
    system.stateVersion = "25.05";

    environment.systemPackages = with pkgs; [
      neovim
      git
      curl
    ];

    sops = {
      # Create /var/lib/sops/age-key.txt on the VPS before first deploy.
      age.keyFile = "/var/lib/sops/age-key.txt";
      age.generateKey = false;
    };

    networking = {
      firewall = {
        enable = true;
        allowedTCPPorts = [80 443];
        allowedUDPPorts = [21820];
      };
      hostName = "eclair";
    };

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

    nix.settings = {
      max-jobs = 1;
      cores = 1;
    };

    # One vCPU: builds, GC and hub updates yield to the edge and to sshd.
    systemd.services = {
      comin.serviceConfig = {
        CPUWeight = 20;
        IOWeight = 20;
        Nice = 10;
      };
      nix-gc.serviceConfig = {
        CPUWeight = 20;
        IOWeight = 20;
      };
      nix-optimise.serviceConfig = {
        CPUWeight = 20;
        IOWeight = 20;
      };
      crowdsec-update-hub.serviceConfig = {
        CPUWeight = 20;
        IOWeight = 20;
      };
    };

    # lz4 compresses several times faster than zstd; on one vCPU the fault
    # latency matters more than the ratio.
    zramSwap = {
      enable = true;
      algorithm = "lz4";
    };
  };
}
