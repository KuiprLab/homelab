#!/usr/bin/env bash
# Vendored from TonyTromp/tidal-connect-docker (check-tidal-status.sh,
# rev 690b76ff8c6596f2e66b347b875544e5607ca645). Adapted for NixOS:
#   - podman instead of docker CLI
#   - oci-containers systemd unit name via TIDAL_UNIT
#   - watchdog logs in the journal, not /var/log
# Diagnostic script to check why Tidal Connect isn't being recognized.

CONTAINER_NAME="${CONTAINER_NAME:-tidal-connect}"
TIDAL_UNIT="${TIDAL_UNIT:-tidal-connect}"

echo "=========================================="
echo "Tidal Connect Status Check"
echo "=========================================="
echo ""

# Check if container is running
echo "1. Container Status:"
if podman ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "   OK: Container is running"
  podman ps | grep "$CONTAINER_NAME"
else
  echo "   FAIL: Container is NOT running"
  echo "   Stopped containers:"
  podman ps -a | grep "$CONTAINER_NAME" || echo "   (none)"
fi
echo ""

# Check service status
echo "2. Unit Status:"
systemctl status "$TIDAL_UNIT" --no-pager -l | head -10
echo ""

# Check Avahi status
echo "3. Avahi Daemon Status:"
if systemctl is-active --quiet avahi-daemon; then
  echo "   OK: Avahi is running"
else
  echo "   FAIL: Avahi is NOT running"
fi
echo ""

# Check for Avahi collisions in logs
echo "4. Avahi/mDNS Status:"
COLLISION_CHECK=$(podman logs "$CONTAINER_NAME" 2>&1 | grep -i "AVAHI_CLIENT_S_COLLISION\|AVAHI_CLIENT_FAILURE" | tail -5)
if [ -n "$COLLISION_CHECK" ]; then
  echo "   WARNING: MDNS COLLISION DETECTED!"
  echo "   Most likely: service restarted too fast (mDNS announcements have"
  echo "   ~120s TTL, so rapid restarts collide with their own registration)."
  echo "   Fix: wait ~2 minutes, then 'systemctl restart $TIDAL_UNIT'."
  echo "   Recent collision errors:"
  echo "$COLLISION_CHECK" | sed 's/^/   /'
else
  echo "   OK: No Avahi/mDNS collision errors"
fi
echo ""

# Check container logs for errors
echo "5. Recent Container Errors (last 20 lines):"
podman logs "$CONTAINER_NAME" --tail 20 2>&1 | grep -iE "(error|warning|failed|crash)" || echo "   No errors found"
echo ""

# Check if mDNS is advertising
echo "6. mDNS Advertisement Check:"
if command -v avahi-browse >/dev/null 2>&1; then
  echo "   Checking for Tidal services (empty output is normal when idle)..."
  timeout 5 avahi-browse -t _tidalconnect._tcp 2>/dev/null || echo "   No Tidal services found"
else
  echo "   avahi-browse not available"
fi
echo ""

# Check watchdog
echo "7. Watchdog Status:"
systemctl status tidal-watchdog --no-pager -l | head -5
echo ""

echo "=========================================="
echo "Done."
