#!/bin/bash
set -uo pipefail

# Ribbon-camera (OV5647 / Camera Module v1.3) version of whip-stream.sh, in use until 2026-09-17.
# To use it: install it as /usr/local/bin/whip-stream.sh instead of the USB-camera script.

CAMERA_INDEX=0
# 1080p30 is the Pi 4 hardware H.264 encoder maximum (OV5647's full 2592x1944 only runs ~15 fps).
WIDTH=1920
HEIGHT=1080
FRAMERATE=30
LEVEL=4.2
# Stress test 2026-09-15: loss comes and goes from ~10 Mbps, heavy at 12+, and 8 Mbps still had
# steady NACKs over a 2 min soak. 6 Mbps then killed ffmpeg twice on 2026-09-16 with EAGAIN (send
# buffer full during WiFi hiccups), so 4 Mbps for more headroom. ffmpeg's WHIP muxer cannot back off.
BITRATE=4000000
INTRA=60
# WHIP_URL and WHIP_TOKEN come from /etc/whip-stream.env (the unit's EnvironmentFile=).
: "${WHIP_URL:?not set - see /etc/whip-stream.env}"
: "${WHIP_TOKEN:?not set - see /etc/whip-stream.env}"
FFMPEG_BIN="/usr/local/bin/ffmpeg"
LOG_DIR="/var/log/whip-stream"
DEVICE="/dev/video0"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Waiting for camera device $DEVICE..."
for i in $(seq 1 30); do
    if [ -e "$DEVICE" ]; then
        break
    fi
    sleep 1
done

if [ ! -e "$DEVICE" ]; then
    log "Camera device $DEVICE not found after 30s, aborting"
    exit 1
fi

log "Device present. Checking camera readiness via libcamera..."
READY=0
for i in $(seq 1 15); do
    if rpicam-hello --list-cameras 2>&1 | grep -q "Available cameras"; then
        READY=1
        break
    fi
    log "Camera not ready yet, retrying..."
    sleep 2
done

if [ "$READY" -ne 1 ]; then
    log "Camera never reported ready, aborting"
    exit 1
fi

log "Camera ready. Starting capture ${WIDTH}x${HEIGHT}@${FRAMERATE} ${BITRATE}bps -> hardware h264 (video only) -> WHIP push to $WHIP_URL"

# Raw H.264 has no timestamps; number frames at the capture rate (wallclock stamps per pipe read are wrong).
exec bash -c "
rpicam-vid --camera $CAMERA_INDEX --width $WIDTH --height $HEIGHT --framerate $FRAMERATE \
  --codec h264 --profile baseline --level $LEVEL --bitrate $BITRATE --intra $INTRA --inline \
  --timeout 0 --nopreview --output - 2>>'$LOG_DIR/rpicam.log' \
| '$FFMPEG_BIN' -f h264 -framerate $FRAMERATE -i - \
  -map 0:v -c:v copy -bsf:v setts=ts=N/$FRAMERATE/TB -an \
  -f whip -timeout 30 -ts_buffer_size 8388608 -authorization '$WHIP_TOKEN' '$WHIP_URL' \
  2>>'$LOG_DIR/ffmpeg.log'
"
