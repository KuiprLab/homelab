_: let
  caches = import ./_caches.nix;

  common = {
    nix = {
      channel.enable = false;
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 5d";
      };
      # Hardlinks duplicate files in the store; nothing else deduplicates them.
      optimise = {
        automatic = true;
        dates = ["weekly"];
      };
      extraOptions = ''
        experimental-features = nix-command flakes
        warn-dirty = false
      '';
      settings = {
        inherit (caches) substituters;
        trusted-public-keys = caches.trustedPublicKeys;
      };
    };
  };
in {
  flake.nixosModules.nixSettings = common;
  flake.eclairNixosModules.nixSettings = common;
}
