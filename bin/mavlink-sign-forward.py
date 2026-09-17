#!/usr/bin/env python3
"""Sign the Pixhawk's MAVLink and forward it to the mavlink-hub.

The hub exposes a public UDP port and therefore enforces MAVLink v2 signing: unsigned frames are
counted and dropped, which is what this drone's telemetry was hitting (86 frames/s in,
`dropped.unsigned` climbing by exactly the same amount, `framesAccepted` flat).

mavlink-routerd cannot sign. The other way to fix it — `SETUP_SIGNING` on the autopilot — would also
make the Pixhawk reject unsigned *incoming* commands on every link, so a telemetry radio or a GCS
without the key would silently lose the ability to command the aircraft. So sign only the leg that
actually crosses the internet, and leave the autopilot alone:

    Pixhawk --USB--> mavlink-routerd --TCP 5760--> this --signed UDP--> hub

Key handling mirrors the hub's `deriveKey()` exactly: 64 hex chars or 44-char base64 is the raw
32-byte key, anything else is SHA-256 of the text (what MAVProxy's `signing setup <passphrase>`
does). If the two derivations disagree every frame drops as `badsig` with no clue why.
"""

import base64
import hashlib
import os
import re
import time

# Signing exists only in MAVLink 2, and pymavlink picks the dialect version at import time.
os.environ.setdefault("MAVLINK20", "1")

from pymavlink import mavutil  # noqa: E402  (must follow the MAVLINK20 default above)

SOURCE = os.environ.get("MAV_SIGN_SOURCE", "tcp:127.0.0.1:5760")
TARGET = os.environ.get("MAV_SIGN_TARGET", "udpout:37.16.12.67:14550")
KEY_FILE = os.environ.get("MAV_SIGN_KEY_FILE", "/etc/mavlink-sign.env")
LINK_ID = int(os.environ.get("MAV_SIGN_LINK_ID", "0"))
KEY_POLL_SECS = 15
REPORT_SECS = 60
SILENCE_SECS = 10
# MAVLink signing timestamps are 10-microsecond ticks since 2015-01-01 UTC.
EPOCH_2015 = 1420070400

# ArduPilot only streams data on USB once a GCS asks for it, and forgets on every reboot, so without
# this the hub sees nothing but a 1 Hz HEARTBEAT. Ask per message with SET_MESSAGE_INTERVAL: it lives
# in the autopilot's RAM only (unlike SRx_* params) and covers exactly what the map/HUD parses.
# Rates are Hz; 84 msg/s here plus HEARTBEAT/STATUSTEXT/TIMESYNC is ~86 msg/s, the rate the link
# carried when it was last known good (2026-09-16).
STREAM_RATES = {
    "ATTITUDE": 20,
    "VFR_HUD": 10,
    "GLOBAL_POSITION_INT": 10,
    "GPS_RAW_INT": 5,
    "SYS_STATUS": 5,
    "EKF_STATUS_REPORT": 5,
    "VIBRATION": 5,
    "RC_CHANNELS": 5,
    "SCALED_PRESSURE": 5,
    "NAV_CONTROLLER_OUTPUT": 5,
    "BATTERY_STATUS": 5,
    "MISSION_CURRENT": 2,
    "SYSTEM_TIME": 2,
}
# Re-ask when the autopilot is heartbeating but ATTITUDE has stopped (e.g. the Pixhawk rebooted while
# mavlink-routerd kept the TCP link up), at most this often.
STREAM_RECHECK_SECS = 5


def log(message):
    print("[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), message), flush=True)


def derive_key(text):
    """Same derivation as the hub's signing.mjs, or the keys silently never match."""
    text = text.strip()
    if re.fullmatch(r"[0-9a-fA-F]{64}", text):
        return bytes.fromhex(text)
    if re.fullmatch(r"[A-Za-z0-9+/]{43}=", text):
        raw = base64.b64decode(text)
        if len(raw) == 32:
            return raw
    return hashlib.sha256(text.encode("utf-8")).digest()


def read_key():
    """The key lives outside this script so it never lands in a repo or a process listing."""
    try:
        with open(KEY_FILE, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() != "MAV_SIGNING_KEY":
                    continue
                value = value.strip().strip('"').strip("'")
                return derive_key(value) if value else None
    except OSError:
        return None
    return None


def request_streams(source, sysid, compid):
    for name, hz in STREAM_RATES.items():
        msg_id = getattr(mavutil.mavlink, "MAVLINK_MSG_ID_" + name)
        source.mav.command_long_send(
            sysid, compid, mavutil.mavlink.MAV_CMD_SET_MESSAGE_INTERVAL, 0,
            msg_id, int(1e6 / hz), 0, 0, 0, 0, 0)
    log("requested %d message streams from autopilot %d/%d" % (len(STREAM_RATES), sysid, compid))


def forward(key):
    """One session: read from the router, re-emit every message signed. Raises on link loss."""
    log("connecting to %s" % SOURCE)
    source = mavutil.mavlink_connection(SOURCE)
    try:
        forward_from(source, key)
    finally:
        # Otherwise every reconnect leaks a socket that mavlink-routerd keeps filling.
        source.close()


def forward_from(source, key):
    target = mavutil.mavlink_connection(TARGET)

    target.mav.signing.secret_key = key
    target.mav.signing.link_id = LINK_ID
    # Start from the wall clock so a restart never reuses timestamps the hub has already seen; it
    # rejects a timestamp that is not greater than the last one for this (sysid, compid, link).
    target.mav.signing.timestamp = int((time.time() - EPOCH_2015) * 1e5)
    target.mav.signing.sign_outgoing = True
    log("forwarding signed MAVLink to %s (link_id=%d)" % (TARGET, LINK_ID))

    sent = 0
    skipped = 0
    # Monotonic, not time.time(): the Pi has no RTC, and the NTP step shortly after boot used to look
    # like 10 s of silence and force a pointless reconnect.
    last_report = time.monotonic()
    last_message = time.monotonic()
    last_attitude = None
    last_request = None

    while True:
        msg = source.recv_match(blocking=True, timeout=1)
        now = time.monotonic()
        if msg is None:
            if now - last_message >= SILENCE_SECS:
                raise IOError("no MAVLink from %s for %ds" % (SOURCE, SILENCE_SECS))
            continue
        last_message = now

        kind = msg.get_type()
        if kind == "BAD_DATA" or kind.startswith("UNKNOWN"):
            skipped += 1
            continue

        if kind == "ATTITUDE":
            last_attitude = now
        elif (kind == "HEARTBEAT"
              and msg.autopilot != mavutil.mavlink.MAV_AUTOPILOT_INVALID
              and (last_request is None
                   or (now - last_request >= STREAM_RECHECK_SECS
                       and (last_attitude is None or now - last_attitude >= STREAM_RECHECK_SECS)))):
            request_streams(source, msg.get_srcSystem(), msg.get_srcComponent())
            last_request = now

        # Keep the originating vehicle and component: the hub keys its replay state on them, and a
        # rewritten sysid would also put this Pi on the map instead of the aircraft.
        target.mav.srcSystem = msg.get_srcSystem()
        target.mav.srcComponent = msg.get_srcComponent()
        target.mav.send(msg)
        sent += 1

        if now - last_report >= REPORT_SECS:
            log("%.1f msg/s signed and forwarded (%d skipped)" % (sent / (now - last_report), skipped))
            sent = 0
            skipped = 0
            last_report = now


def main():
    key = read_key()
    while key is None:
        log("no MAV_SIGNING_KEY in %s yet; checking again every %ds" % (KEY_FILE, KEY_POLL_SECS))
        time.sleep(KEY_POLL_SECS)
        key = read_key()
    log("signing key loaded from %s" % KEY_FILE)

    while True:
        try:
            forward(key)
        except Exception as error:  # noqa: BLE001 - any failure here is "retry the link"
            log("link lost: %s; retrying in 5s" % error)
            time.sleep(5)


if __name__ == "__main__":
    main()

