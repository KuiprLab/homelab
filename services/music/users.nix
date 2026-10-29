# Users and groups for music services
#
# uid/gid are pinned: they were auto-allocated before the container move and the
# navidrome state dir (0700) plus /media/data/music (0775 daniel:music) are owned
# by these exact numbers. The container runs as this uid:gid and joins the music
# group, so the on-disk tree needs no chown.
#
# The group is 989 and not 986: 986 is what the old auto-allocation happened to
# pick for it, and services/music/subtidal.nix hardcodes 986 for its own files.
# Nothing depends on navidrome's group id — /var/lib/navidrome is 0700 owned by
# the user — so moving it off the collision is free, while leaving subtidal's
# 986 alone avoids a chown of /var/lib/subtidal.
_: {
  flake.nixosModules.musicUsers = _: {
    users = {
      groups = {
        music.gid = 985;
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
