# Keyless GeoIP/ASN databases for pangolin's country and ASN rules.
#
# pangolin reads MaxMind-format MMDBs via `server.maxmind_db_path` (country)
# and `server.maxmind_asn_path` (ASN). Instead of a MaxMind account +
# geoipupdate licence key, this fetches DB-IP lite (also MMDB, CC BY-SA 4.0,
# monthly, no account). The file names are stable so pangolin's config.yml
# never changes between refreshes.
#
# Ordering matters: pangolin opens both databases at import time, so a missing
# file fails every country/ASN rule (and crashes the app). geoip-db.service
# therefore runs before podman-pangolin.service.
_: {
  flake.eclairNixosModules.geoip-db = {pkgs, ...}: {
    systemd.services.geoip-db = {
      description = "Fetch DB-IP lite country and ASN databases (MaxMind MMDB)";
      wantedBy = ["multi-user.target"];
      before = ["podman-pangolin.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [coreutils curl gzip];
      script = ''
        set -euo pipefail
        install -d -m 0755 /var/lib/geoip
        tmp=""
        trap 'rm -f "$tmp"' EXIT

        for db in country asn; do
          tmp="$(mktemp /var/lib/geoip/.dbip-XXXXXX)"

          # DB-IP publishes the new month a few days late; fall back to the
          # previous month so a refresh never leaves the host without a
          # database.
          for month in "$(date -u +%Y-%m)" "$(date -u -d '1 month ago' +%Y-%m)"; do
            if curl -fsSL --retry 3 --max-time 300 \
              "https://download.db-ip.com/free/dbip-$db-lite-$month.mmdb.gz" \
              | gzip -dc > "$tmp"; then
              echo "fetched dbip-$db-lite $month"
              break
            fi
          done

          test -s "$tmp"
          # mktemp creates 0600 root; pangolin (user pangolin) must read it.
          chmod 0644 "$tmp"
          mv "$tmp" "/var/lib/geoip/dbip-$db-lite.mmdb"
          tmp=""
        done
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
