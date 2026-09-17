# Rebuilding shis-drone from a blank SD card

This rebuilds the drone's companion Pi: camera → WHIP → vanicall, and Pixhawk MAVLink → signed UDP → streamscope hub.
It reproduces the Pi as it ran on 2026-09-17. Plan on 1–2 hours, most of it compiling ffmpeg.

**Secrets are not in this repo.** Before you start, have these ready:

| Secret | Where it comes from |
|---|---|
| WHIP publish URL + bearer token | The drone's ingest in vanicall. Not recoverable from the Pi image or this repo, so keep a copy in a password manager. |
| MAVLink signing key (64 hex chars) | Must equal the Fly secret `MAV_SIGNING_KEY` on app `streamscope-mavlink`. Fly can't show it again; if lost, rotate it (step 7). |
| WiFi passwords | `drubelabs` and the `shis` hotspot |

## 1. Flash the OS

Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)**, Debian 13 "trixie". In the Imager's OS customisation:

- Hostname: `shis-drone`
- Username: `shis`
- WiFi: `drubelabs`, country `IN`
- Locale: timezone `Asia/Kolkata`
- Services: enable SSH with password authentication

Boot it, then connect: `ssh shis@shis-drone.local`. If mDNS doesn't resolve, find the IP on the router. A given board keeps the same DHCP address; the Pi 4 was `192.168.0.157`.

## 2. Base packages and interfaces

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git curl tcpdump v4l-utils
sudo raspi-config nonint do_i2c 0
sudo raspi-config nonint do_spi 0
sudo raspi-config nonint do_serial_hw 0     # enable_uart=1
sudo raspi-config nonint do_serial_cons 0   # serial login console, as on the original
```

`camera_auto_detect=1` is already the default in `/boot/firmware/config.txt`. It is what loads the ribbon camera's overlay at boot.

## 3. WiFi profiles

`drubelabs-wifi-watchdog` brings up a NetworkManager connection named exactly `drubelabs`. The Imager's profile is usually called `preconfigured`, so rename it (or add one):

```bash
nmcli -t -f NAME connection show
sudo nmcli connection modify preconfigured connection.id drubelabs     # if the Imager created it
sudo nmcli connection add type wifi ifname wlan0 con-name shis-hotspot ssid shis \
     wifi-sec.key-mgmt wpa-psk wifi-sec.psk '<hotspot password>'
```

The password lands in shell history; clear it afterwards with `history -d <n>` or `history -c`.

## 4. Build ffmpeg 9.0.1 (WHIP muxer)

Debian's ffmpeg has no WHIP muxer, so it is built from source into `/usr/local` as shared libraries. This is the exact configuration of the original build:

```bash
sudo apt install -y build-essential pkg-config nasm yasm libssl-dev \
     libx264-dev libx265-dev libvpx-dev libopus-dev libmp3lame-dev libfreetype-dev libv4l-dev libdrm-dev
cd ~ && wget https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz && tar xf ffmpeg-9.0.1.tar.xz && cd ffmpeg-9.0.1
./configure --prefix=/usr/local --enable-gpl --enable-version3 --enable-openssl \
     --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libmp3lame \
     --enable-libfreetype --enable-libv4l2 --enable-libdrm --enable-neon --enable-shared --disable-doc
make -j4
sudo make install && sudo ldconfig
```

Check it:

```bash
/usr/local/bin/ffmpeg -hide_banner -muxers | grep whip            # E whip
/usr/local/bin/ffmpeg -hide_banner -encoders | grep h264_v4l2m2m  # Pi hardware H.264 encoder
```

## 5. mavlink-router

Built from git (`v4-16-g2362c62`) into `/usr/bin`, where `mavlink-forward.sh` expects it:

```bash
sudo apt install -y meson ninja-build
cd ~ && git clone https://github.com/mavlink-router/mavlink-router.git && cd mavlink-router
git checkout 2362c62 && git submodule update --init --recursive
meson setup build . --prefix=/usr --buildtype=release
ninja -C build && sudo ninja -C build install
sudo systemctl disable --now mavlink-router 2>/dev/null   # its own unit, if installed, stays off
```

`mavlink-forward.sh` launches `mavlink-routerd` itself, with no config file.

## 6. pymavlink, for the signer

Installed per-user for `shis`, the account the signer runs as:

```bash
pip3 install --user --break-system-packages pymavlink==2.4.49
python3 -c "import pymavlink; print('ok')"
```

## 7. Secrets

**WHIP credentials**: root-only, read by systemd through `EnvironmentFile=`:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/whip-stream.env
sudo nano /etc/whip-stream.env        # format: whip-stream.env.example
```

**MAVLink signing key**: owned by `shis`, because the signer reads the file itself:

```bash
sudo install -m 600 -o shis -g shis /dev/null /etc/mavlink-sign.env
sudo nano /etc/mavlink-sign.env       # format: mavlink-sign.env.example
```

Lost the key? Rotate it on both ends (from a machine with `flyctl`), then paste the same value on the Pi:

```bash
KEY=$(openssl rand -hex 32); echo "$KEY"
fly secrets set MAV_SIGNING_KEY="$KEY" -a streamscope-mavlink
```

## 8. Install this repo

```bash
cd ~ && git clone https://github.com/Allenmylath/pistore.git && cd pistore

sudo install -m 755 bin/whip-stream.sh bin/whip-stop.sh bin/whip-watchdog.sh \
     bin/mavlink-forward.sh bin/mavlink-sign-forward.py bin/drubelabs-wifi-watchdog.sh /usr/local/bin/
sudo install -m 644 systemd/*.service /etc/systemd/system/
sudo install -D -m 644 systemd/whip-camera-stream.service.d/stop.conf \
     /etc/systemd/system/whip-camera-stream.service.d/stop.conf
sudo install -m 644 sysctl/90-whip-udp-buffers.conf /etc/sysctl.d/ && sudo sysctl --system

# Services running as shis can't create their own log directories under /var/log
sudo install -d -o shis -g shis /var/log/whip-stream /var/log/mavlink-forward

sudo systemctl daemon-reload
sudo systemctl enable --now drubelabs-wifi-watchdog mavlink-forward mavlink-sign-forward \
     whip-camera-stream whip-watchdog
```

**Pick the camera script.** `bin/whip-stream.sh` captures the Logitech Brio 100 USB camera by its serial-numbered path. For a different USB camera, set `DEVICE=` to its entry in `ls /dev/v4l/by-id/` (the `-video-index0` one). For the ribbon camera (Camera Module v1.3), install the other script in its place:

```bash
sudo install -m 755 bin/whip-stream-rpicam.sh /usr/local/bin/whip-stream.sh
sudo systemctl restart whip-camera-stream
```

## 9. Verify

```bash
systemctl is-active drubelabs-wifi-watchdog mavlink-forward mavlink-sign-forward whip-camera-stream whip-watchdog
vcgencmd get_throttled                                  # must be throttled=0x0
sysctl net.core.wmem_max                                # 4194304
```

**Camera**
- Ribbon: `rpicam-hello --list-cameras` lists `ov5647`.
- USB: `v4l2-ctl --list-devices` shows the camera.

**WHIP publishing.** The server's view is the one that counts:

```bash
sudo sh -c '. /etc/whip-stream.env; curl -s -H "Authorization: Bearer $WHIP_TOKEN" "$WHIP_URL"'   # {"publishing":true,...}
tail -f /var/log/whip-stream/ffmpeg.log
```

**Telemetry**, with the Pixhawk on USB:

```bash
journalctl -u mavlink-sign-forward -f                   # "~84 msg/s signed and forwarded" each minute
curl -s https://streamscope-mavlink.fly.dev/health       # framesAccepted rising, dropped.badsig 0
```

`dropped.badsig` climbing means the Pi and Fly keys differ. `dropped.unsigned` climbing means something is sending unsigned MAVLink straight to the hub.

## Hardware notes

- **Power first.** Use a solid **5.1 V / 3 A** supply or BEC, with a short, thick cable. On 2026-09-17 the Pi rebooted without warning, logged "Undervoltage detected!" (`throttled=0x50000`), and its filesystem needed orphan cleanup after sudden power loss. Check `vcgencmd get_throttled` after any flight.
- **Unplug power before touching the camera ribbon.** A ribbon camera connected to a running Pi isn't detected until the next boot, and hot-plugging can damage the camera or the port.
- **Before blaming software for a missing ribbon camera,** check the kernel log. `ov5647 10-0036: ... i2c read error ... -5` means the sensor isn't answering on I2C: ribbon, connector or module, not drivers. Reinstalling or reflashing won't fix that.

## Migrating an existing Pi to the env-file layout

Pis set up before this repo hardcode `WHIP_URL`/`WHIP_TOKEN` in `/usr/local/bin/whip-stream.sh`. Extract them **before** installing the repo's scripts over it:

```bash
sudo sh -c 'umask 077; sed -n "s/^\(WHIP_URL\|WHIP_TOKEN\)=\"\(.*\)\"$/\1=\2/p" /usr/local/bin/whip-stream.sh > /etc/whip-stream.env'
sudo sed 's/=.*/=<set>/' /etc/whip-stream.env            # expect WHIP_URL=<set> and WHIP_TOKEN=<set>
```

Then run step 8.
