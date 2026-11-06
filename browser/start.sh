#!/usr/bin/env bash
# Server browser: Chromium with a persistent profile on a virtual screen.
#   6080: noVNC view (password protected) so a human can log in and watch
#   9223: Chrome DevTools Protocol for the workspace's chrome-devtools-mcp
set -euo pipefail

: "${VNC_PASSWORD:?VNC_PASSWORD is empty; run install.sh to generate one}"
export DISPLAY=:99
WIDTH="${SCREEN_WIDTH:-1440}"
HEIGHT="${SCREEN_HEIGHT:-900}"

mkdir -p /data/profile /fraim/downloads
rm -f /data/profile/Singleton*

Xvfb :99 -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp &
for _ in $(seq 50); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done

x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpass >/dev/null 2>&1
x11vnc -display :99 -rfbauth /tmp/vncpass -localhost -rfbport 5900 -forever -shared -quiet -noxdamage &
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
socat TCP-LISTEN:9223,fork,reuseaddr TCP:127.0.0.1:9222 &

(
  while true; do
    rm -f /data/profile/Singleton*
    chromium \
      --user-data-dir=/data/profile \
      --remote-debugging-port=9222 \
      --no-first-run \
      --no-default-browser-check \
      --disable-dev-shm-usage \
      --no-sandbox \
      --window-position=0,0 \
      --window-size="${WIDTH},${HEIGHT}" \
      --start-maximized \
      about:blank || true
    sleep 2
  done
) &

wait -n
echo "browser: a process exited, restarting the container" >&2
exit 1
