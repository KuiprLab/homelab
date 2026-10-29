_: {
  flake.eclairNixosModules.geoip-db = {pkgs, ...}: {
    systemd.services.geoip-db = {
      description = "Fetch DB-IP lite country and ASN databases (MaxMind MMDB)";
      wantedBy = ["multi-user.target"];
      # Pangolin opens both databases at import time and crashes without them.
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

          # DB-IP publishes the new month late; fall back to the previous one.
          for month in "$(date -u +%Y-%m)" "$(date -u -d '1 month ago' +%Y-%m)"; do
            if curl -fsSL --retry 3 --max-time 300 \
              "https://download.db-ip.com/free/dbip-$db-lite-$month.mmdb.gz" \
              | gzip -dc > "$tmp"; then
              echo "fetched dbip-$db-lite $month"
              break
            fi
          done

          test -s "$tmp"
          # mktemp creates 0600 root; pangolin runs as user pangolin.
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
