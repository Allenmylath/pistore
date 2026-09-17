#!/bin/bash
# Stop the capture first, so ffmpeg reaches end-of-input and disposes its WHIP session cleanly.
#
# A SIGTERM straight at ffmpeg (which is what a plain `systemctl stop` does) aborts the DELETE it
# would otherwise send — the log shows "Immediate exit requested" and "Failed to DELETE url". The
# server then keeps the publish slot until Cloudflare times the old track out, and the next start
# spends ~35s being answered 409 Conflict.
#
# systemd runs ExecStop to completion before signalling anything, so waiting for ffmpeg here is
# what buys it the time to send that DELETE. TimeoutStopSec bounds the wait.
set -u

# Ribbon camera pipeline (rpicam-vid | ffmpeg) or USB camera pipeline (capture ffmpeg | WHIP ffmpeg).
pkill -INT -x rpicam-vid
# Anchored on the binary path: the `bash -c` wrapper's own command line contains the same text.
pkill -INT -f -- "^/usr/local/bin/ffmpeg .*-f v4l2 "

for _ in $(seq 1 60); do
    pgrep -x ffmpeg >/dev/null || exit 0
    sleep 0.25
done

exit 0
