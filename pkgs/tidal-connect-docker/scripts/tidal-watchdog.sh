#!/usr/bin/env bash
# Vendored from TonyTromp/tidal-connect-docker (tidal-watchdog.sh,
# rev 690b76ff8c6596f2e66b347b875544e5607ca645). Adapted for NixOS:
#   - podman instead of docker CLI
#   - restarts via the oci-containers systemd unit (TIDAL_UNIT)
#   - logs to the journal instead of /var/log
#   - no volume-bridge to bounce alongside
#
# Monitors for token expiration / connection loss / container death and
# restarts the service. Note: an intentional stop must stop this unit too,
# otherwise it brings the container straight back up.

CHECK_INTERVAL=30   # Check every 30 seconds
RESTART_COOLDOWN=60 # Don't restart more than once per minute
LAST_RESTART=0

CONTAINER_NAME="${CONTAINER_NAME:-tidal-connect}"
TIDAL_UNIT="${TIDAL_UNIT:-tidal-connect}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

get_container_status() {
  podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null
}

check_for_errors() {
  # Get logs from the last CHECK_INTERVAL seconds
  RECENT_LOGS=$(podman logs --since "${CHECK_INTERVAL}s" "$CONTAINER_NAME" 2>&1)

  # Token expiration - these are clear errors that require restart
  if echo "$RECENT_LOGS" | grep -qiE "(invalid_grant|token has expired|authentication.*failed)"; then
    echo "token_expired"
    return
  fi

  # Connection loss - only trigger on actual errors, not normal EOF.
  # "End of file" (EOF) is normal during connection teardown, so ignore it.
  if echo "$RECENT_LOGS" | grep -qiE "handle_read_frame error|connection.*refused|connection.*reset|socket.*disconnected" &&
    ! echo "$RECENT_LOGS" | grep -qiE "asio\.misc:2.*End of file|normal.*shutdown"; then
    echo "connection_lost"
    return
  fi

  # Check if container is running but not responsive
  if [ "$(get_container_status)" != "true" ]; then
    echo "container_down"
    return
  fi

  echo "ok"
}

restart_service() {
  local reason="$1" current_time waited
  current_time=$(date +%s)

  if [ $((current_time - LAST_RESTART)) -lt $RESTART_COOLDOWN ]; then
    log "Restart ($reason) skipped: cooldown active"
    return 0
  fi

  log "Restarting Tidal Connect ($reason)"

  if systemctl is-failed --quiet "$TIDAL_UNIT"; then
    log "   Unit failed, resetting..."
    systemctl reset-failed "$TIDAL_UNIT" 2>/dev/null || true
  fi

  # oci-containers re-creates the container on unit start; no manual
  # podman rm needed (upstream did this because docker-compose kept state)
  log "   Restarting unit $TIDAL_UNIT..."
  systemctl restart "$TIDAL_UNIT"

  # Wait for the binary inside the container to come up
  waited=0
  while [ $waited -lt 30 ]; do
    if [ "$(get_container_status)" = "true" ] &&
      podman exec "$CONTAINER_NAME" pgrep -f "tidal_connect_application" >/dev/null 2>&1; then
      log "Restart OK"
      LAST_RESTART=$current_time

      # Check for immediate collision errors
      sleep 3
      if podman logs --since 3s "$CONTAINER_NAME" 2>&1 | grep -q "AVAHI_CLIENT_S_COLLISION"; then
        log "WARNING: mDNS collision detected after restart"
      fi
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  log "ERROR: Service restart failed - container not healthy"
  systemctl status "$TIDAL_UNIT" --no-pager -l 2>/dev/null | head -15 | while read -r line; do
    log "   $line"
  done
  return 1
}

log "=========================================="
log "Tidal Connect Watchdog started"
log "Container: $CONTAINER_NAME, unit: $TIDAL_UNIT"
log "Check interval: ${CHECK_INTERVAL}s"
log "Restart cooldown: ${RESTART_COOLDOWN}s"
log "=========================================="

while true; do
  # Check if container exists
  if [ -z "$(podman ps -a --filter "name=^$CONTAINER_NAME$" -q 2>/dev/null)" ]; then
    log "Tidal Connect container not found, waiting..."
    sleep "$CHECK_INTERVAL"
    continue
  fi

  STATUS=$(check_for_errors)

  case "$STATUS" in
  token_expired)
    log "Detected: Token expired"
    restart_service "token_expired"
    ;;
  connection_lost)
    log "Detected: Connection lost"
    restart_service "connection_lost"
    ;;
  container_down)
    log "Detected: Container down"
    restart_service "container_down"
    ;;
  ok)
    # Silently continue
    ;;
  esac

  sleep "$CHECK_INTERVAL"
done
