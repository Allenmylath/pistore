# pistore

systemd services from the `shis-drone` Raspberry Pi that stream its camera into a vanicall room over WHIP.

| Service | Script | What it does |
|---|---|---|
| `whip-camera-stream.service` | `bin/whip-stream.sh` | Captures the camera, encodes H.264 on the Pi's hardware encoder, and publishes it with ffmpeg's WHIP muxer. Video only. |
| ↳ drop-in `stop.conf` | `bin/whip-stop.sh` | Stops the capture first, so ffmpeg sends its WHIP `DELETE` and the next start doesn't get `409 Conflict`. |
| `whip-watchdog.service` | `bin/whip-watchdog.sh` | Restarts the stream if Cloudflare goes silent, or if vanicall reports the publish is no longer live (`GET` on the WHIP URL). |

The current `whip-stream.sh` captures a Logitech Brio 100 USB camera (MJPEG 1080p30 → `h264_v4l2m2m`, 4 Mbps).

## Layout on the Pi

```
systemd/whip-camera-stream.service           -> /etc/systemd/system/
systemd/whip-camera-stream.service.d/stop.conf -> /etc/systemd/system/whip-camera-stream.service.d/
systemd/whip-watchdog.service                -> /etc/systemd/system/
bin/*.sh                                     -> /usr/local/bin/
whip-stream.env.example                      -> /etc/whip-stream.env (fill in, mode 600)
```

## Install

```bash
sudo install -m 755 bin/whip-stream.sh bin/whip-stop.sh bin/whip-watchdog.sh /usr/local/bin/
sudo install -D -m 644 systemd/whip-camera-stream.service.d/stop.conf /etc/systemd/system/whip-camera-stream.service.d/stop.conf
sudo install -m 644 systemd/whip-camera-stream.service systemd/whip-watchdog.service /etc/systemd/system/
sudo install -m 600 whip-stream.env.example /etc/whip-stream.env   # then edit in the real URL and token
sudo systemctl daemon-reload
sudo systemctl enable --now whip-camera-stream whip-watchdog
```

Requires ffmpeg with the WHIP muxer at `/usr/local/bin/ffmpeg`, plus `tcpdump` and `curl` for the watchdog.

The WHIP token is a publish credential: keep it only in `/etc/whip-stream.env`, never in this repo.
