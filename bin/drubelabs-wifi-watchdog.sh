#!/bin/bash
set -uo pipefail

SSID="drubelabs"
INTERFACE="wlan0"
CHECK_INTERVAL=15
LOG_DIR="/var/log/drubelabs-wifi-watchdog"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# The NetworkManager profile for $SSID, found by SSID rather than by name: Raspberry Pi Imager calls it
# `preconfigured` on bookworm and `netplan-wlan0-<ssid>` on trixie, and renaming a netplan-generated profile
# over the WiFi it describes can drop the SSH session doing the renaming.
find_connection() {
    local name type
    while IFS=: read -r name type; do
        [ "$type" = "802-11-wireless" ] || continue
        if [ "$(nmcli -g 802-11-wireless.ssid connection show "$name" 2>/dev/null)" = "$SSID" ]; then
            echo "$name"
            return 0
        fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
    return 1
}

log "drubelabs-wifi-watchdog starting (check interval=${CHECK_INTERVAL}s)"
if CONNECTION_NAME=$(find_connection); then
    log "using NetworkManager profile '$CONNECTION_NAME' for SSID $SSID"
else
    log "no NetworkManager profile for SSID $SSID yet; will look again each check"
    CONNECTION_NAME=""
fi

while true; do
    current_conn=$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | cut -d: -f2-)

    if [ -z "$CONNECTION_NAME" ] || [ "$current_conn" != "$CONNECTION_NAME" ]; then
        # The profile may have been added or recreated since the last check.
        CONNECTION_NAME=$(find_connection) || CONNECTION_NAME=""
    fi

    if [ -z "$CONNECTION_NAME" ]; then
        log "no NetworkManager profile for SSID $SSID (current: '${current_conn:-none}'), retrying in ${CHECK_INTERVAL}s"
    elif [ "$current_conn" != "$CONNECTION_NAME" ]; then
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
