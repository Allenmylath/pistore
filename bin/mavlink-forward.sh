#!/bin/bash
# Forward Pixhawk MAVLink telemetry to a remote UDP endpoint.
# Polls for the Pixhawk on USB every POLL_SECS: starts mavlink-routerd when it
# appears and stops it when it goes away, so plugging in after boot works.
set -uo pipefail

# No UDP endpoint here any more. The hub enforces MAVLink v2 signing and mavlink-routerd cannot
# sign, so everything this sent was counted as `dropped.unsigned` and never reached the map.
# mavlink-sign-forward.service now owns the internet leg: it reads this router's TCP server on
# 127.0.0.1:5760, signs each message, and sends it to the hub.
USB_BAUD=115200    # Ignored by USB CDC, but mavlink-routerd expects one
POLL_SECS=15
MAVLINK_ROUTERD="/usr/bin/mavlink-routerd"
LOG_DIR="/var/log/mavlink-forward"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Print the by-id path of a flight controller running firmware (not its bootloader).
find_pixhawk() {
    local dev
    for dev in /dev/serial/by-id/usb-*-if00; do
        [ -e "$dev" ] || continue
        case "$dev" in
            *_BL_*|*-BL_*) continue ;;   # Bootloader, only present for a few seconds after power-up
            *ArduPilot*|*PX4*|*Pixhawk*|*3D_Robotics*|*Holybro*|*CubePilot*|*ProfiCNC*)
                echo "$dev"
                return 0
                ;;
        esac
    done
    return 1
}

ROUTER_PID=""
DEVICE=""
WAITING_LOGGED=0

stop_router() {
    if [ -n "$ROUTER_PID" ]; then
        kill "$ROUTER_PID" 2>/dev/null
        wait "$ROUTER_PID" 2>/dev/null
        ROUTER_PID=""
    fi
}
trap 'stop_router; exit 0' TERM INT

log "Checking for Pixhawk on USB every ${POLL_SECS}s"
while true; do
    if [ -n "$ROUTER_PID" ] && ! kill -0 "$ROUTER_PID" 2>/dev/null; then
        wait "$ROUTER_PID"
        log "mavlink-routerd exited (status $?)"
        ROUTER_PID=""
    fi

    if [ -n "$ROUTER_PID" ] && [ ! -e "$DEVICE" ]; then
        log "Pixhawk disconnected ($DEVICE), stopping mavlink-routerd"
        stop_router
    fi

    if [ -z "$ROUTER_PID" ]; then
        if DEVICE=$(find_pixhawk); then
            log "Found Pixhawk: $DEVICE ($(readlink -f "$DEVICE")); routing to TCP 127.0.0.1:5760 for the signer"
            "$MAVLINK_ROUTERD" "$DEVICE:$USB_BAUD" >>"$LOG_DIR/mavlink-router.log" 2>&1 &
            ROUTER_PID=$!
            WAITING_LOGGED=0
        elif [ "$WAITING_LOGGED" -eq 0 ]; then
            log "No Pixhawk found, checking again every ${POLL_SECS}s"
            WAITING_LOGGED=1
        fi
    fi

    # Background sleep so a stop signal is handled immediately
    sleep "$POLL_SECS" &
    wait $!
done
