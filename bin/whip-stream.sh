#!/bin/bash
set -uo pipefail

# USB camera (Logitech Brio 100) since 2026-09-17: the OV5647 ribbon camera stopped answering on I2C.
# The ribbon-camera version of this script is kept as whip-stream.sh.bak-*-rpicam.
# The by-id path, not /dev/video0, so a returning ribbon camera or another USB device cannot swap in.
DEVICE="/dev/v4l/by-id/usb-046d_Brio_100_2530APJ7R848-video-index0"
# The Brio only reaches 30 fps as MJPEG. The Pi 4 decodes that in software (~1 core at 1080p30,
# measured 2026-09-17) and re-encodes on the hardware H.264 encoder.
WIDTH=1920
HEIGHT=1080
FRAMERATE=30
# Stress test 2026-09-15: loss comes and goes from ~10 Mbps, heavy at 12+, and 8 Mbps still had
# steady NACKs over a 2 min soak. 6 Mbps then killed ffmpeg twice on 2026-09-16 with EAGAIN (send
# buffer full during WiFi hiccups), so 4 Mbps for more headroom. ffmpeg's WHIP muxer cannot back off.
BITRATE=4000000
INTRA=60
# WHIP_URL and WHIP_TOKEN come from /etc/whip-stream.env (the unit's EnvironmentFile=), so the bearer
# token lives in one root-only file instead of in this script.
: "${WHIP_URL:?not set - see /etc/whip-stream.env}"
: "${WHIP_TOKEN:?not set - see /etc/whip-stream.env}"
FFMPEG_BIN="/usr/local/bin/ffmpeg"
LOG_DIR="/var/log/whip-stream"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Waiting for USB camera $DEVICE..."
for i in $(seq 1 30); do
    if [ -e "$DEVICE" ]; then
        break
    fi
    sleep 1
done

if [ ! -e "$DEVICE" ]; then
    log "USB camera $DEVICE not found after 30s, aborting"
    exit 1
fi

log "Camera present. Starting capture ${WIDTH}x${HEIGHT}@${FRAMERATE} MJPEG -> hardware h264 ${BITRATE}bps (video only) -> WHIP push to $WHIP_URL"

# Two ffmpegs, so whip-stop.sh can end the capture and let the WHIP side reach end-of-input and send
# its DELETE (signalling the WHIP ffmpeg directly aborts that request). NUT between them keeps the
# camera's own frame timestamps: frame-numbering at a fixed rate would drift whenever the Brio drops
# its frame rate in low light. WebRTC needs Baseline (profile 66), no B-frames, and SPS/PPS on every
# keyframe for viewers who join mid-stream. The 90 kHz encoder time base (RTP's clock) matters: by
# default it is 1/framerate, which rounds the camera's jittery USB timestamps onto a 33 ms grid, so
# about every third frame collided with the previous one ("Non-monotonic DTS", 10 log lines/s).
exec bash -c "
'$FFMPEG_BIN' -hide_banner -nostats \
  -f v4l2 -input_format mjpeg -video_size ${WIDTH}x${HEIGHT} -framerate $FRAMERATE -thread_queue_size 64 -i '$DEVICE' \
  -vf format=yuv420p -fps_mode passthrough -enc_time_base:v 1:90000 \
  -c:v h264_v4l2m2m -b:v $BITRATE -g $INTRA -bf 0 -profile:v 66 -level:v 40 \
  -bsf:v dump_extra=freq=keyframe -an \
  -f nut -flush_packets 1 - 2>>'$LOG_DIR/capture.log' \
| '$FFMPEG_BIN' -hide_banner -nostats -fflags nobuffer -f nut -i - \
  -map 0:v -c:v copy -an \
  -f whip -timeout 30 -ts_buffer_size 8388608 -authorization '$WHIP_TOKEN' '$WHIP_URL' \
  2>>'$LOG_DIR/ffmpeg.log'
"
