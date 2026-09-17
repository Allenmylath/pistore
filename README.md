# pistore

Services and scripts from the `shis-drone` Raspberry Pi, the drone's companion computer. It streams the camera into a vanicall room over WHIP and forwards signed Pixhawk telemetry to the streamscope MAVLink hub.

**Rebuilding the Pi from scratch: see [REBUILD.md](REBUILD.md).**

| Service | Script | What it does |
|---|---|---|
| `whip-camera-stream.service` | `bin/whip-stream.sh` | Captures the camera, encodes H.264 on the Pi's hardware encoder, and publishes with ffmpeg's WHIP muxer. Video only. |
| ↳ drop-in `stop.conf` | `bin/whip-stop.sh` | Stops the capture first, so ffmpeg sends its WHIP `DELETE` and the next start doesn't get `409 Conflict`. |
| `whip-watchdog.service` | `bin/whip-watchdog.sh` | Restarts the stream if Cloudflare goes silent, or if vanicall reports the publish is no longer live. |
| `mavlink-forward.service` | `bin/mavlink-forward.sh` | Runs `mavlink-routerd` on the Pixhawk's USB port while it's plugged in, serving MAVLink on TCP `127.0.0.1:5760`. |
| `mavlink-sign-forward.service` | `bin/mavlink-sign-forward.py` | Asks the autopilot for telemetry streams (~86 msg/s), signs each message (MAVLink v2), and sends it to the hub at `37.16.12.67:14550`. |
| `drubelabs-wifi-watchdog.service` | `bin/drubelabs-wifi-watchdog.sh` | Switches `wlan0` back to the `drubelabs` network whenever it's in range. |

**Camera scripts**
- `bin/whip-stream.sh` captures a Logitech Brio 100 USB camera: MJPEG 1080p30 → `h264_v4l2m2m`, 4 Mbps.
- `bin/whip-stream-rpicam.sh` is the ribbon-camera version (Camera Module v1.3).

## Secrets

Nothing secret is committed. Both credential files live only on the Pi:

| File | Holds | Owner / mode |
|---|---|---|
| `/etc/whip-stream.env` | `WHIP_URL`, `WHIP_TOKEN`: vanicall publish credential | `root:root 600`, loaded via `EnvironmentFile=` |
| `/etc/mavlink-sign.env` | `MAV_SIGNING_KEY`: must match the Fly secret on `streamscope-mavlink` | `shis:shis 600`, read by the signer |

See `whip-stream.env.example` and `mavlink-sign.env.example` for the formats.
