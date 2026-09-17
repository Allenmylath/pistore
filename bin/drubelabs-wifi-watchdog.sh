#!/bin/bash
set -uo pipefail

CONNECTION_NAME="drubelabs"
SSID="drubelabs"
INTERFACE="wlan0"
CHECK_INTERVAL=15
LOG_DIR="/var/log/drubelabs-wifi-watchdog"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "drubelabs-wifi-watchdog starting (check interval=${CHECK_INTERVAL}s)"

while true; do
    current_conn=$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | cut -d: -f2-)

    if [ "$current_conn" != "$CONNECTION_NAME" ]; then
        # Only drop the current link when drubelabs is actually in range, or wlan0 flaps for nothing.
        if nmcli -t -f SSID device wifi list ifname "$INTERFACE" --rescan yes 2>/dev/null | grep -qx "$SSID"; then
            log "not on drubelabs (current: '${current_conn:-none}') - connecting"
            if nmcli connection up "$CONNECTION_NAME" >>"$LOG_FILE" 2>&1; then
                log "connected to drubelabs"
            else
                log "failed to connect to drubelabs, retrying in ${CHECK_INTERVAL}s"
            fi
        else
            log "drubelabs not in range (current: '${current_conn:-none}'), retrying in ${CHECK_INTERVAL}s"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
