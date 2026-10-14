#!/bin/bash
# Vendored verbatim from TonyTromp/tidal-connect-docker (Docker/entrypoint.sh,
# rev 690b76ff8c6596f2e66b347b875544e5607ca645). Runs inside the container;
# all knobs come in as environment variables set by the NixOS module.

echo "Starting Speaker Application in Background (TMUX)"
/usr/bin/tmux new-session -d -s speaker_controller_application '/app/ifi-tidal-release/bin/speaker_controller_application'

echo "Starting TIDAL Connect.."
echo "Configuration:"
echo "  FRIENDLY_NAME: ${FRIENDLY_NAME}"
echo "  MODEL_NAME: ${MODEL_NAME}"
echo "  PLAYBACK_DEVICE: ${PLAYBACK_DEVICE}"
echo "  MQA_PASSTHROUGH: ${MQA_PASSTHROUGH}"
echo "  MQA_CODEC: ${MQA_CODEC}"
echo ""

/app/ifi-tidal-release/bin/tidal_connect_application \
  --tc-certificate-path "/app/ifi-tidal-release/id_certificate/IfiAudio_ZenStream.dat" \
  -f "${FRIENDLY_NAME:-HiFiBerry}" \
  --codec-mpegh true \
  --codec-mqa ${MQA_CODEC:-false} \
  --model-name "${MODEL_NAME:-HiFiBerry}" \
  --disable-app-security false \
  --disable-web-security false \
  --enable-mqa-passthrough ${MQA_PASSTHROUGH:-false} \
  --playback-device "${PLAYBACK_DEVICE:-default}" \
  --log-level 3 \
  --enable-websocket-log "0"

echo "TIDAL Connect Container Stopped.."
