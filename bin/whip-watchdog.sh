#!/bin/bash
set -uo pipefail

SILENCE_THRESHOLD=30   # seconds of no inbound packets (after establishment) before restarting
CAPTURE_WINDOW=5        # max seconds to wait per check for one inbound packet
POLL_GAP=1               # pause between checks
POST_RESTART_GRACE=10   # pause after triggering a restart before resuming checks
SERVICE=whip-camera-stream.service
LOG_DIR="/var/log/whip-watchdog"

# Silence alone misses the worst case. When vanicall ends a publish (Cloudflare reported the session
# gone, or the 12 h lifetime cap), Cloudflare keeps trickling packets back to the encoder, so this
# never sees silence and the Pi streams into a session nobody can watch. So also ask the server.
SERVER_CHECK_INTERVAL=15   # seconds between asking vanicall whether the publish is live
SERVER_GONE_CHECKS=2        # consecutive "not publishing" answers before republishing
STARTUP_GRACE=45            # seconds after the stream (re)starts before trusting that answer

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# The stream's own endpoint and credential: a GET on the publish URL is the status check. Both come
# from /etc/whip-stream.env, the same EnvironmentFile= the stream service uses.
WHIP_URL=${WHIP_URL:-}
WHIP_TOKEN=${WHIP_TOKEN:-}

log "whip-watchdog starting (silence threshold=${SILENCE_THRESHOLD}s, server check every ${SERVER_CHECK_INTERVAL}s)"
if [ -z "$WHIP_URL" ] || [ -z "$WHIP_TOKEN" ]; then
    log "WHIP_URL/WHIP_TOKEN not set (see /etc/whip-stream.env); server check disabled"
fi

established=false
last_seen=$(date +%s)
last_server_check=0
server_gone=0

restart_stream() {
    log "$1, restarting publisher"
    systemctl restart "$SERVICE"
    established=false
    server_gone=0
    last_seen=$(date +%s)
    sleep "$POST_RESTART_GRACE"
}

# Seconds the stream service has been active; prints nothing if it is not running. Monotonic clocks
# rather than the human-readable timestamp, which `date -d` cannot parse reliably ("IST" is
# ambiguous).
stream_up_for() {
    local mono
    [ "$(systemctl is-active "$SERVICE")" = "active" ] || return 0
    mono=$(systemctl show "$SERVICE" -p ActiveEnterTimestampMonotonic --value)
    [ -n "$mono" ] && [ "$mono" != "0" ] || return 0
    echo $(( $(awk '{print int($1)}' /proc/uptime) - mono / 1000000 ))
}

while true; do
    socket_line=$(ss -u -p -n 2>/dev/null | grep ffmpeg | head -n1)

    if [ -n "$socket_line" ]; then
        local_addr=$(echo "$socket_line" | awk '{print $3}')
        peer_addr=$(echo "$socket_line" | awk '{print $4}')
        local_port=${local_addr##*:}
        peer_ip=${peer_addr%:*}

        if [ -n "$peer_ip" ] && [ -n "$local_port" ]; then
            if timeout "$CAPTURE_WINDOW" tcpdump -i any -nn -c 1 \
                "udp and src host $peer_ip and dst port $local_port" 2>/dev/null | grep -q .; then
                last_seen=$(date +%s)
                if [ "$established" = false ]; then
                    log "Inbound feedback detected from Cloudflare ($peer_ip) - session established"
                    established=true
                fi
            fi
        fi
    fi

    if [ "$established" = true ]; then
        now=$(date +%s)
        silent_for=$((now - last_seen))
        if [ "$silent_for" -ge "$SILENCE_THRESHOLD" ]; then
            restart_stream "No inbound packets from Cloudflare for ${silent_for}s - session appears dead"
            continue
        fi
    fi

    now=$(date +%s)
    if [ -n "$WHIP_URL" ] && [ -n "$WHIP_TOKEN" ] && [ $((now - last_server_check)) -ge "$SERVER_CHECK_INTERVAL" ]; then
        last_server_check=$now
        up_for=$(stream_up_for)
        if [ -n "$up_for" ] && [ "$up_for" -ge "$STARTUP_GRACE" ]; then
            # Only a definite answer counts. A network error, a 5xx, or a server too old to have
            # this endpoint (405) says nothing about the publish, and restarting on one would turn
            # a server blip into a stream outage.
            response=$(curl -s -m 10 -w $'\n%{http_code}' -H "Authorization: Bearer $WHIP_TOKEN" "$WHIP_URL" 2>/dev/null)
            code=${response##*$'\n'}
            body=${response%$'\n'*}
            if [ "$code" = "200" ] && [[ "$body" == *'"publishing":false'* ]]; then
                server_gone=$((server_gone + 1))
                log "vanicall reports the publish is not live ($server_gone/$SERVER_GONE_CHECKS)"
                if [ "$server_gone" -ge "$SERVER_GONE_CHECKS" ]; then
                    restart_stream "vanicall ended the publish while the encoder kept sending"
                    continue
                fi
            elif [ "$code" = "200" ]; then
                server_gone=0
            fi
        fi
    fi

    sleep "$POLL_GAP"
done
