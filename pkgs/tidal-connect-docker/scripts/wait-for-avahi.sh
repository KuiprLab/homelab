#!/bin/bash
# Vendored verbatim from TonyTromp/tidal-connect-docker (wait-for-avahi.sh,
# rev 690b76ff8c6596f2e66b347b875544e5607ca645).
# Wait for Avahi to become ready before starting Tidal Connect

TIMEOUT=30
ELAPSED=0

until systemctl is-active --quiet avahi-daemon; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Avahi did not become ready within ${TIMEOUT}s"
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

echo "Avahi is ready after ${ELAPSED} seconds"
