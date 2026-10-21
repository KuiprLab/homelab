{
  self,
  inputs,
  ...
}: {
  flake.deploy.nodes = let
    user = "root";
  in {
    sorbet = {
      hostname = "192.168.0.85";
      profiles.system = {
        inherit user;
        sshUser = user;
        remoteBuild = true;
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.sorbet;
      };
    };

    eclair = {
      # Deploy straight to the public IP. Port 2222 is the break-glass
      # non-standard SSH port (see eclair configuration.nix); until the
      # provider panel rule for 2222 is added we deploy on the default port,
      # after which flip sshOpts to ["-p" "2222"] and close public :22.
      hostname = "46.38.236.192";
      profiles.system = {
        inherit user;
        sshUser = user;
        # Built on the Mac, delegated to sorbet via the Mac's nix builders.
        remoteBuild = false;
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.eclair;
      };
    };
  };
}
