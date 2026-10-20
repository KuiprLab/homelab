# Keyless GeoIP database for pangolin's country/ASN rules.
#
# pangolin reads a MaxMind-format MMDB via `server.maxmind_db_path`. Instead of
# a MaxMind account + geoipupdate licence key, this fetches DB-IP lite (also
# MMDB, CC BY-SA 4.0, monthly, no account). The file name is stable so
# pangolin's config.yml never changes between refreshes.
#
# Ordering matters: pangolin's blueprint schema does `existsSync()` on the path
# at import time, so a missing database fails every country rule (and crashes
# the app). geoip-db.service therefore runs before pangolin.service.
_: {
  flake.eclairNixosModules.geoip-db = {pkgs, ...}: {
    systemd.services.geoip-db = {
      description = "Fetch DB-IP lite country database (MaxMind MMDB)";
      wantedBy = ["multi-user.target"];
      before = ["pangolin.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [coreutils curl gzip];
      script = ''
        set -euo pipefail
        install -d -m 0755 /var/lib/geoip
        tmp="$(mktemp /var/lib/geoip/.dbip-XXXXXX)"
        trap 'rm -f "$tmp"' EXIT

        # DB-IP publishes the new month a few days late; fall back to the
        # previous month so a refresh never leaves the host without a database.
        for month in "$(date -u +%Y-%m)" "$(date -u -d '1 month ago' +%Y-%m)"; do
          if curl -fsSL --retry 3 --max-time 120 \
            "https://download.db-ip.com/free/dbip-country-lite-$month.mmdb.gz" \
            | gzip -dc > "$tmp"; then
            echo "fetched dbip-country-lite $month"
            break
          fi
        done

        test -s "$tmp"
        # mktemp creates 0600 root; pangolin (user pangolin) must read it.
        chmod 0644 "$tmp"
        mv "$tmp" /var/lib/geoip/dbip-country-lite.mmdb
      '';
    };

    systemd.timers.geoip-db = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "monthly";
        Persistent = true;
      };
    };
  };
}
