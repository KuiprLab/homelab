_: {
  flake.nixosModules.musicUsers = _: {
    users = {
      groups = {
        music.gid = 985;
        # 986 is hardcoded in subtidal.nix; the state dirs are owned by these ids
        navidrome.gid = 989;
        music-tagger = {};
      };
      users = {
        daniel = {
          extraGroups = ["music"];
          homeMode = "0711";
        };
        navidrome = {
          extraGroups = ["music"];
          isSystemUser = true;
          group = "navidrome";
          uid = 990;
        };
      };
    };
  };
}
