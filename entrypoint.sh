#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$XDG_RUNTIME_DIR" /workspace
chown zed:zed "$XDG_RUNTIME_DIR" /workspace
chmod 700 "$XDG_RUNTIME_DIR"

if [ -n "${VNC_PASSWORD:-}" ]; then
  export NOVNC_AUTH_ARGS="--web-auth --auth-plugin=websockify.auth_plugins.BasicHTTPAuth --auth-source=${VNC_USERNAME:-zed}:${VNC_PASSWORD}"
else
  echo "WARNING: VNC_PASSWORD is not set. The browser endpoint has NO authentication." >&2
  echo "         Set -e VNC_PASSWORD=... or put this behind a trusted network/reverse proxy." >&2
  export NOVNC_AUTH_ARGS=""
fi

if [ -e /dev/dri ]; then
  echo "Found /dev/dri - hardware GPU rendering available."
else
  echo "WARNING: /dev/dri not found in container. Pass through the Intel GPU node with" >&2
  echo "         --device /dev/dri/cardN --device /dev/dri/renderDNNN or Zed/sway will fail." >&2
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
