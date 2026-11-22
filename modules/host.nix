_: let
  mkHostModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.homelab;
  in {
    options.homelab = {
      timeZone = lib.mkOption {
        type = lib.types.str;
        default = "Europe/Berlin";
        description = "System time zone.";
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Packages added to the base set every host carries.";
      };

      nix = {
        maxJobs = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Maximum parallel build jobs. Null leaves the Nix default.";
        };
        cores = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Cores per build job. Null leaves the Nix default.";
        };
      };

      pangolinSite = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Run a newt container that joins this host to the pangolin tunnel
            network as a site. Requires an entry in flake.constants.sites and
            the newt credentials in newtSopsFile.
          '';
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = config.networking.hostName;
          description = "Pangolin site id: the newt --id and a key of flake.constants.sites.";
        };
        newtSopsFile = lib.mkOption {
          type = lib.types.path;
          default = ../secrets/${config.networking.hostName}/newt.env;
          description = "Dotenv file holding NEWT_ID and NEWT_SECRET.";
        };
        enforceHealthcheckTls = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Make newt verify the certificate of every health-check target. Only
            a site that serves the probed domains itself can do this.
          '';
        };
      };

      rex = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the rex terminal agent.";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Account rex starts shell sessions as.";
        };
        hostname = lib.mkOption {
          type = lib.types.str;
          default = "${config.networking.hostName}-rex";
          description = "tsnet hostname inside the tailnet.";
        };
        sopsFile = lib.mkOption {
          type = lib.types.path;
          default = ../secrets/${config.networking.hostName}/tailscale.yaml;
          description = "YAML file holding TS_AUTHKEY.";
        };
      };

      heartbeat = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Ping the healthchecks.io dead-man's switch.";
        };
        sopsFile = lib.mkOption {
          type = lib.types.path;
          default = ../secrets/${config.networking.hostName}/healthchecks;
          description = "Binary file holding the healthchecks.io ping URL.";
        };
      };
    };

    config = {
      environment.systemPackages =
        [
          pkgs.neovim
          pkgs.git
          pkgs.curl
        ]
        ++ cfg.extraPackages;

      sops.age = {
        # Create /var/lib/sops/age-key.txt on the host before the first deploy.
        keyFile = "/var/lib/sops/age-key.txt";
        generateKey = false;
      };

      networking.firewall.enable = true;

      time.timeZone = cfg.timeZone;
      i18n.defaultLocale = "en_US.UTF-8";

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "prohibit-password";
        };
      };

      programs.fish.enable = true;
      users.defaultUserShell = pkgs.fish;

      nix.settings =
        lib.optionalAttrs (cfg.nix.maxJobs != null) {max-jobs = cfg.nix.maxJobs;}
        // lib.optionalAttrs (cfg.nix.cores != null) {cores = cfg.nix.cores;};
    };
  };
in {
  flake.hostModules.host = mkHostModule;
}
